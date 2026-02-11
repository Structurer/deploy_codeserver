#!/bin/bash

# 部署脚本：在服务器上安装和配置 code Server + Cloudflare Tunnel
# 作者：Trae Assistant
# 日期：2026-02-10

set -e

echo ""
echo "=== 开始部署 code Server + Cloudflare Tunnel ==="

echo ""
echo "0. 系统更新选项..."
echo "系统更新可能需要较长时间，是否跳过？"
echo "1. 执行系统更新（推荐，确保系统包最新）"
echo "2. 跳过系统更新（快速部署，使用现有包）"
read -p "请输入选择 (1/2): " update_choice

if [ "$update_choice" = "1" ]; then
    echo ""
echo "1. 更新系统包..."
    apt update && apt upgrade -y
else
    echo ""
echo "1. 跳过系统更新..."
fi

echo ""
echo "2. 安装必要依赖..."
apt install -y curl

echo ""
echo "3. 安装 code Server..."
curl -fsSL https://code-server.dev/install.sh | sh

echo ""
echo "4. 配置 code Server..."
echo "请输入 code Server 的登录密码："
read -s CODESERVER_PASSWORD
echo ""
echo "确认密码："
read -s CODESERVER_PASSWORD_CONFIRM

if [ "$CODESERVER_PASSWORD" != "$CODESERVER_PASSWORD_CONFIRM" ]; then
    echo ""
echo "错误：两次输入的密码不一致，请重新执行脚本"
    exit 1
fi

mkdir -p /root/.config/code-server

if [ ! -f "/root/.config/code-server/config.yaml" ]; then
    cat > /root/.config/code-server/config.yaml << EOF
bind-addr: 127.0.0.1:8080
auth: password
password: $CODESERVER_PASSWORD
cert: false
EOF
    echo "配置文件已创建"
else
    sed -i "s/password: .*/password: $CODESERVER_PASSWORD/" /root/.config/code-server/config.yaml
    echo "密码已更新"
fi

echo ""
echo "5. 启动并启用 code Server 服务..."
systemctl enable --now code-server@root

echo ""
echo "=== code Server 部署完成 ==="

echo ""
echo "6. 安装 Cloudflare Tunnel 客户端..."
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
dpkg -i cloudflared.deb
rm -f cloudflared.deb

echo ""
echo "7. Cloudflare 账户授权..."
if [ -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "检测到已存在的 Cloudflare 证书"
    echo "请选择操作："
    echo "1. 使用现有证书"
    echo "2. 重新授权（覆盖现有证书）"
    read -p "请输入选择 (1/2): " cert_choice
    
    if [ "$cert_choice" = "2" ]; then
        echo "正在删除现有证书..."
        rm -f "$HOME/.cloudflared/cert.pem"
        echo "请在浏览器中打开以下URL并登录Cloudflare账户授权："
        echo "授权完成后，按回车键继续..."
        cloudflared tunnel login
    else
        echo "使用现有证书"
    fi
else
    echo "请在浏览器中打开以下URL并登录Cloudflare账户授权："
    echo "授权完成后，按回车键继续..."
    cloudflared tunnel login
fi

echo ""
echo "8. 验证 Cloudflare 授权..."
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "错误：Cloudflare 授权失败，请重新执行授权步骤"
    exit 1
fi
echo "Cloudflare 授权成功！"

echo ""
echo "9. 配置完整域名..."
echo "请输入您要使用的完整域名（如 code.example.com）："
read -p "完整域名: " FULL_DOMAIN

if [ -z "$FULL_DOMAIN" ]; then
    echo "错误：域名不能为空"
    exit 1
fi

echo "使用的域名: $FULL_DOMAIN"

echo ""
echo "11. 创建 Cloudflare Tunnel..."
TUNNEL_NAME="codeserver-tunnel"
TUNNEL_ID=""

echo "正在尝试创建 tunnel '$TUNNEL_NAME'..."
TUNNEL_CREATION_OUTPUT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1 || echo "命令执行失败: $?")
echo "创建命令输出: $TUNNEL_CREATION_OUTPUT"

TUNNEL_ID=$(echo "$TUNNEL_CREATION_OUTPUT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
echo "提取到的 Tunnel ID: '$TUNNEL_ID'"

if [ -z "$TUNNEL_ID" ] && echo "$TUNNEL_CREATION_OUTPUT" | grep -q "tunnel with name already exists"; then
    echo "检测到 tunnel '$TUNNEL_NAME' 已存在"
    echo "请选择操作："
    echo "1. 使用现有 tunnel"
    echo "2. 创建新名称的 tunnel"
    read -p "请输入选择 (1/2): " tunnel_choice
    
    if [ "$tunnel_choice" = "1" ]; then
        echo "正在获取现有 tunnel 列表..."
        TUNNEL_LIST=$(cloudflared tunnel list 2>&1 || echo "命令执行失败: $?")
        
        if echo "$TUNNEL_LIST" | grep -q "命令执行失败"; then
            echo "错误：无法获取 tunnel 列表，请重新授权"
            echo "正在重新授权..."
            cloudflared tunnel login
            TUNNEL_LIST=$(cloudflared tunnel list 2>&1 || echo "命令执行失败: $?")
        fi
        
        # 解析 tunnel 列表并显示带序号的选项
        echo "\n现有 tunnel 列表："
        echo "序号  ID                                   NAME              CREATED"
        echo "---------------------------------------------------------------"
        
        # 将 tunnel 信息解析为数组
        IFS=$'\n' read -r -d '' -a TUNNEL_ITEMS <<< "$(echo "$TUNNEL_LIST" | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')"
        
        # 显示 tunnel 列表
        for i in "${!TUNNEL_ITEMS[@]}"; do
            index=$((i+1))
            tunnel_line=${TUNNEL_ITEMS[$i]}
            tunnel_id=$(echo "$tunnel_line" | awk '{print $1}')
            tunnel_name=$(echo "$tunnel_line" | awk '{print $2}')
            tunnel_created=$(echo "$tunnel_line" | awk '{print $3}')
            printf "%2d   %s   %-16s   %s\n" "$index" "$tunnel_id" "$tunnel_name" "$tunnel_created"
        done
        
        # 让用户选择 tunnel
        read -p "\n请输入要使用的 tunnel 序号：" tunnel_index
        
        # 验证输入
        if [[ "$tunnel_index" =~ ^[0-9]+$ ]] && [ "$tunnel_index" -ge 1 ] && [ "$tunnel_index" -le "${#TUNNEL_ITEMS[@]}" ]; then
            # 获取选中的 tunnel 信息
            selected_index=$((tunnel_index-1))
            selected_tunnel=${TUNNEL_ITEMS[$selected_index]}
            TUNNEL_ID=$(echo "$selected_tunnel" | awk '{print $1}')
            TUNNEL_NAME=$(echo "$selected_tunnel" | awk '{print $2}')
            
            echo "\n您选择的 tunnel："
            echo "ID: $TUNNEL_ID"
            echo "名称: $TUNNEL_NAME"
            
            # 检查本地是否存在凭据文件
            CREDENTIALS_FILE="/root/.cloudflared/$TUNNEL_ID.json"
            if [ ! -f "$CREDENTIALS_FILE" ]; then
                echo "\n检测到本地缺少该 tunnel 的凭据文件"
                echo "正在重新获取凭据..."
                
                # 重新授权
                cloudflared tunnel login
                
                # 检查凭据文件是否生成
                if [ ! -f "$CREDENTIALS_FILE" ]; then
                    echo "错误：无法获取 tunnel 凭据，请尝试创建新 tunnel"
                    exit 1
                fi
                echo "成功获取 tunnel 凭据"
            else
                echo "本地已存在该 tunnel 的凭据文件"
            fi
            
            echo "使用现有 Cloudflare Tunnel，ID: $TUNNEL_ID"
        else
            echo "错误：输入无效，请重新执行脚本"
            exit 1
        fi
    else
        echo "请输入新的 tunnel 名称："
        read -p "Tunnel 名称: " NEW_TUNNEL_NAME
        if [ -z "$NEW_TUNNEL_NAME" ]; then
            NEW_TUNNEL_NAME="codeserver-tunnel-$(date +%s)"
        fi
        echo "创建名为 $NEW_TUNNEL_NAME 的 tunnel..."
        TUNNEL_CREATION_OUTPUT=$(cloudflared tunnel create $NEW_TUNNEL_NAME 2>&1 || echo "命令执行失败: $?")
        echo "创建命令输出: $TUNNEL_CREATION_OUTPUT"
        
        TUNNEL_ID=$(echo "$TUNNEL_CREATION_OUTPUT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
        echo "提取到的 Tunnel ID: '$TUNNEL_ID'"
        
        if [[ "$TUNNEL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            TUNNEL_NAME="$NEW_TUNNEL_NAME"
            echo "成功创建 Cloudflare Tunnel，ID: $TUNNEL_ID"
        else
            echo "错误：创建 Cloudflare Tunnel 失败"
            echo "输出信息：$TUNNEL_CREATION_OUTPUT"
            exit 1
        fi
    fi
elif [ -z "$TUNNEL_ID" ]; then
    echo "错误：创建 Cloudflare Tunnel 失败"
    echo "输出信息：$TUNNEL_CREATION_OUTPUT"
    exit 1
else
    echo "成功创建 Cloudflare Tunnel，ID: $TUNNEL_ID"
fi

echo ""
echo "12. 配置 Cloudflare Tunnel..."
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
url: http://localhost:8080
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json
EOF

echo ""
echo "13. 启动并启用 Cloudflare Tunnel 服务..."
cloudflared service install
systemctl enable --now cloudflared

sleep 5

echo ""
echo "14. 绑定自定义域名到 Cloudflare Tunnel..."
echo "将 $FULL_DOMAIN 绑定到 tunnel..."
BIND_RESULT=$(cloudflared tunnel route dns $TUNNEL_NAME $FULL_DOMAIN 2>&1)

if echo "$BIND_RESULT" | grep -q "Failed to add route"; then
    echo "警告：绑定域名失败，可能是因为DNS记录已存在"
    echo "错误信息：$BIND_RESULT"
    echo "请在 Cloudflare 仪表盘中手动删除现有记录后重新运行绑定命令"
else
    echo "成功绑定 $FULL_DOMAIN 到 Cloudflare Tunnel"
fi

echo ""
echo "=== 部署完成，验证服务状态 ==="
echo ""
echo "1. code Server 状态:"
systemctl is-active code-server@root
echo ""
echo "2. Cloudflare Tunnel 状态:"
systemctl is-active cloudflared

echo ""
echo "=== 访问信息 ==="
echo ""
echo "code Server 访问地址:"
echo "- 自定义域名: https://$FULL_DOMAIN"
echo "- Cloudflare Tunnel 默认地址: https://$TUNNEL_ID.cfargotunnel.com"
echo ""
echo "code Server 登录密码: $CODESERVER_PASSWORD"
echo ""
echo "=== 部署完成 ==="