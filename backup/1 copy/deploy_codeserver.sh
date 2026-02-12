#!/bin/bash

# 部署脚本：在服务器上安装和配置 code Server + Cloudflare Tunnel
# 作者：Trae Assistant
# 日期：2026-02-10

set -e

# 处理 dpkg 锁文件的函数
check_and_handle_dpkg_lock() {
    echo "检查 dpkg 锁状态..."
    if [ -f "/var/lib/dpkg/lock" ] || [ -f "/var/lib/dpkg/lock-frontend" ]; then
        echo "检测到 dpkg 锁文件，尝试释放..."
        # 尝试终止占用锁的进程
        sudo fuser -vki -TERM /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
        # 完成未完成的配置
        sudo dpkg --configure --pending 2>/dev/null || true
        # 等待几秒钟让系统稳定
        sleep 3
    fi
}

# 检查并重启 code-server 服务的函数
restart_code_server() {
    echo "检查 code-server 服务状态..."
    # 检查服务是否存在
    if systemctl list-unit-files | grep -q code-server@.service; then
        echo "重启 code-server 服务以应用新配置..."
        systemctl restart code-server@root 2>/dev/null || systemctl start code-server@root
        sleep 2
        # 检查服务状态
        systemctl status code-server@root --no-pager
    else
        echo "code-server 服务尚未安装，跳过重启操作..."
    fi
}

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
    check_and_handle_dpkg_lock
    apt update && apt upgrade -y
else
    echo ""
echo "1. 跳过系统更新..."
fi

echo ""
echo "2. 安装必要依赖..."
check_and_handle_dpkg_lock
apt install -y curl

echo ""
echo "3. 安装 code Server..."
curl -fsSL https://code-server.dev/install.sh | sh

echo "" 
echo "4. 配置 code Server..."

# 密码输入循环，直到两次输入一致
while true; do
    echo "请输入 code Server 的登录密码："
    read -s CODESERVER_PASSWORD
    echo ""
    echo "确认密码："
    read -s CODESERVER_PASSWORD_CONFIRM
    echo ""
    
    if [ "$CODESERVER_PASSWORD" = "$CODESERVER_PASSWORD_CONFIRM" ]; then
        echo "密码确认成功！"
        break
    else
        echo "错误：两次输入的密码不一致，请重新输入"
        echo ""
    fi
done

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
# 重启服务以确保密码生效
restart_code_server

echo ""
echo "=== code Server 部署完成 ==="

echo ""
echo "6. 安装 Cloudflare Tunnel 客户端..."
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
check_and_handle_dpkg_lock
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
        
        # 循环尝试获取 tunnel 列表，最多尝试3次
        MAX_RETRIES=3
        RETRY_COUNT=0
        TUNNEL_LIST=""
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            TUNNEL_LIST=$(cloudflared tunnel list 2>&1)
            
            # 检查命令是否成功执行
            if [ $? -eq 0 ]; then
                # 检查是否包含有效的 tunnel 信息
                if echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
                    break
                else
                    echo "警告：获取到的 tunnel 列表格式异常，尝试重新授权..."
                fi
            else
                echo "错误：无法获取 tunnel 列表，错误信息：$TUNNEL_LIST"
                echo "尝试重新授权..."
            fi
            
            # 重新授权
            cloudflared tunnel login
            RETRY_COUNT=$((RETRY_COUNT + 1))
            
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo "重新尝试获取 tunnel 列表..."
            fi
        done
        
        # 检查是否成功获取到 tunnel 列表
        if [ -z "$TUNNEL_LIST" ] || ! echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            echo "错误：无法获取有效的 tunnel 列表，请稍后重试"
            exit 1
        fi
        
        echo "调试信息：获取到的 tunnel 列表内容："
        echo "$TUNNEL_LIST"
        echo "---------------------------------------------------------------"
        
        # 解析 tunnel 列表并显示带序号的选项
        echo "\n现有 tunnel 列表："
        echo "序号  ID                                   NAME              CREATED"
        echo "---------------------------------------------------------------"
        
        # 将 tunnel 信息解析为数组
        TUNNEL_ITEMS=()
        while IFS= read -r line; do
            if echo "$line" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
                TUNNEL_ITEMS+=("$line")
            fi
        done <<< "$TUNNEL_LIST"
        
        # 显示 tunnel 列表
        for i in "${!TUNNEL_ITEMS[@]}"; do
            index=$((i+1))
            tunnel_line=${TUNNEL_ITEMS[$i]}
            # 提取 tunnel 信息，处理可能的空格问题
            tunnel_id=$(echo "$tunnel_line" | awk '{print $1}')
            tunnel_name=$(echo "$tunnel_line" | awk '{print $2}')
            tunnel_created=$(echo "$tunnel_line" | awk '{print $3 " " $4 " " $5 " " $6 " " $7}')
            printf "%2d   %s   %-16s   %s\n" "$index" "$tunnel_id" "$tunnel_name" "$tunnel_created"
        done
        
        # 检查是否有 tunnel 可用
        if [ ${#TUNNEL_ITEMS[@]} -eq 0 ]; then
            echo "错误：未找到任何现有 tunnel，请选择创建新 tunnel"
            exit 1
        fi
        
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
            echo "调试信息：检查凭据文件路径：$CREDENTIALS_FILE"
            
            if [ ! -f "$CREDENTIALS_FILE" ]; then
                echo "\n检测到本地缺少该 tunnel 的凭据文件"
                echo "执行方案：删除现有 tunnel 并重新创建，以获取新的凭据文件..."
                
                # 删除现有 tunnel
                echo "正在删除现有 tunnel '$TUNNEL_NAME'..."
                DELETE_RESULT=$(cloudflared tunnel delete $TUNNEL_ID 2>&1)
                echo "删除 tunnel 结果：$DELETE_RESULT"
                
                # 重新创建相同名称的 tunnel
                echo "正在重新创建 tunnel '$TUNNEL_NAME'..."
                CREATE_RESULT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
                echo "创建 tunnel 结果：$CREATE_RESULT"
                
                # 提取新的 tunnel ID
                NEW_TUNNEL_ID=$(echo "$CREATE_RESULT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
                
                if [[ "$NEW_TUNNEL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
                    echo "成功重新创建 tunnel，新 ID: $NEW_TUNNEL_ID"
                    # 更新 TUNNEL_ID 变量
                    TUNNEL_ID="$NEW_TUNNEL_ID"
                    # 更新凭据文件路径
                    CREDENTIALS_FILE="/root/.cloudflared/$TUNNEL_ID.json"
                    echo "调试信息：新的凭据文件路径：$CREDENTIALS_FILE"
                    
                    # 检查新的凭据文件是否生成
                    if [ -f "$CREDENTIALS_FILE" ]; then
                        echo "成功获取新的 tunnel 凭据文件"
                    else
                        echo "错误：重新创建 tunnel 后仍未生成凭据文件"
                        exit 1
                    fi
                else
                    echo "错误：重新创建 tunnel 失败"
                    echo "创建输出：$CREATE_RESULT"
                    exit 1
                fi
            else
                echo "本地已存在该 tunnel 的凭据文件"
                echo "调试信息：凭据文件大小：$(ls -l $CREDENTIALS_FILE | awk '{print $5}') 字节"
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
# 检查服务是否已安装
if [ -f "/etc/systemd/system/cloudflared.service" ]; then
    echo "检测到 Cloudflare Tunnel 服务已存在，先卸载旧服务..."
    cloudflared service uninstall
fi
# 安装新服务
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