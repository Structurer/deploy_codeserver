#!/bin/bash

# 部署脚本：在服务器上安装和配置 code Server + Cloudflare Tunnel
# 作者：Trae Assistant
# 日期：2026-02-10

set -e

echo "=== 开始部署 code Server + Cloudflare Tunnel ==="

# 步骤0：选择是否跳过系统更新
echo "\n0. 系统更新选项..."
echo "系统更新可能需要较长时间，是否跳过？"
echo "1. 执行系统更新（推荐，确保系统包最新）"
echo "2. 跳过系统更新（快速部署，使用现有包）"
read -p "请输入选择 (1/2): " update_choice

# 步骤1：系统更新
if [ "$update_choice" = "1" ]; then
    echo "\n1. 更新系统包..."
    apt update && apt upgrade -y
else
    echo "\n1. 跳过系统更新..."
fi

# 步骤2：安装必要依赖
echo "\n2. 安装必要依赖..."
apt install -y curl wget unzip git openssl

# 步骤3：安装 code Server
echo "\n3. 安装 code Server..."
curl -fsSL https://code-server.dev/install.sh | sh

# 步骤4：配置 code Server
echo "\n4. 配置 code Server..."
# 交互式输入密码
echo "请输入 code Server 的登录密码："
read -s CODESERVER_PASSWORD
echo "\n确认密码："
read -s CODESERVER_PASSWORD_CONFIRM

if [ "$CODESERVER_PASSWORD" != "$CODESERVER_PASSWORD_CONFIRM" ]; then
    echo "\n错误：两次输入的密码不一致，请重新执行脚本"
    exit 1
fi

# 确保配置目录存在
mkdir -p /root/.config/code-server

# 如果配置文件不存在，创建一个基本的配置文件
if [ ! -f "/root/.config/code-server/config.yaml" ]; then
    cat > /root/.config/code-server/config.yaml << EOF
bind-addr: 127.0.0.1:8080
auth: password
password: $CODESERVER_PASSWORD
cert: false
EOF
    echo "配置文件已创建"
else
    # 修改默认密码
    sed -i "s/password: .*/password: $CODESERVER_PASSWORD/" /root/.config/code-server/config.yaml
    echo "密码已更新"
fi

# 步骤5：启动并启用 code Server 服务
echo "\n5. 启动并启用 code Server 服务..."
systemctl enable --now code-server@root

echo "\n=== code Server 部署完成 ==="

# 步骤6：安装 Cloudflare Tunnel 客户端
echo "\n6. 安装 Cloudflare Tunnel 客户端..."
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
dpkg -i cloudflared.deb
rm -f cloudflared.deb

# 步骤7：Cloudflare 账户授权
echo "\n7. Cloudflare 账户授权..."
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

# 步骤8：验证授权是否成功
echo "\n8. 验证 Cloudflare 授权..."
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "错误：Cloudflare 授权失败，请重新执行授权步骤"
    exit 1
fi
echo "Cloudflare 授权成功！"

# 步骤9：输入完整域名
echo "\n9. 配置完整域名..."
echo "请输入您要使用的完整域名（如 code.example.com）："
read -p "完整域名: " FULL_DOMAIN

# 验证域名输入
if [ -z "$FULL_DOMAIN" ]; then
    echo "错误：域名不能为空"
    exit 1
fi

echo "使用的域名: $FULL_DOMAIN"

# 步骤11：创建 Cloudflare Tunnel
echo "\n11. 创建 Cloudflare Tunnel..."
TUNNEL_NAME="codeserver-tunnel"
TUNNEL_ID=""

# 尝试创建Tunnel
echo "正在尝试创建 tunnel '$TUNNEL_NAME'..."
TUNNEL_CREATION_OUTPUT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1 || echo "命令执行失败: $?")
echo "创建命令输出: $TUNNEL_CREATION_OUTPUT"

# 更健壮的Tunnel ID提取逻辑
TUNNEL_ID=$(echo "$TUNNEL_CREATION_OUTPUT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
echo "提取到的 Tunnel ID: '$TUNNEL_ID'"

# 如果创建失败且是因为名称已存在
if [ -z "$TUNNEL_ID" ] && echo "$TUNNEL_CREATION_OUTPUT" | grep -q "tunnel with name already exists"; then
    echo "检测到 tunnel '$TUNNEL_NAME' 已存在"
    echo "请选择操作："
    echo "1. 使用现有 tunnel"
    echo "2. 创建新名称的 tunnel"
    read -p "请输入选择 (1/2): " tunnel_choice
    
    if [ "$tunnel_choice" = "1" ]; then
        # 使用现有Tunnel，获取其ID
        echo "正在获取现有 tunnel 的 ID..."
        TUNNEL_LIST=$(cloudflared tunnel list 2>&1 || echo "命令执行失败: $?")
        echo "Tunnel 列表输出: $TUNNEL_LIST"
        TUNNEL_ID=$(echo "$TUNNEL_LIST" | grep "$TUNNEL_NAME" | awk '{print $1}')
        if [ -z "$TUNNEL_ID" ]; then
            echo "错误：无法获取现有 tunnel 的 ID"
            exit 1
        fi
        echo "使用现有 Cloudflare Tunnel，ID: $TUNNEL_ID"
    else
        # 创建新名称的Tunnel
        echo "请输入新的 tunnel 名称："
        read -p "Tunnel 名称: " NEW_TUNNEL_NAME
        if [ -z "$NEW_TUNNEL_NAME" ]; then
            NEW_TUNNEL_NAME="codeserver-tunnel-$(date +%s)"
        fi
        echo "创建名为 $NEW_TUNNEL_NAME 的 tunnel..."
        TUNNEL_CREATION_OUTPUT=$(cloudflared tunnel create $NEW_TUNNEL_NAME 2>&1 || echo "命令执行失败: $?")
        echo "创建命令输出: $TUNNEL_CREATION_OUTPUT"
        
        # 更健壮的Tunnel ID提取逻辑
        # 从包含"Created tunnel"和"with id"的行中提取ID
        TUNNEL_ID=$(echo "$TUNNEL_CREATION_OUTPUT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
        echo "提取到的 Tunnel ID: '$TUNNEL_ID'"
        
        # 验证ID格式（简单验证：是否为36位的UUID格式）
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
    # 其他创建失败的情况
    echo "错误：创建 Cloudflare Tunnel 失败"
    echo "输出信息：$TUNNEL_CREATION_OUTPUT"
    exit 1
else
    # 创建成功
    echo "成功创建 Cloudflare Tunnel，ID: $TUNNEL_ID"
fi

# 步骤12：配置 Cloudflare Tunnel
echo "\n12. 配置 Cloudflare Tunnel..."
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
url: http://localhost:8080
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json
EOF

# 步骤13：启动并启用 Cloudflare Tunnel 服务
echo "\n13. 启动并启用 Cloudflare Tunnel 服务..."
cloudflared service install
systemctl enable --now cloudflared

# 等待隧道服务启动
sleep 5

# 步骤14：绑定自定义域名到 Cloudflare Tunnel
echo "\n14. 绑定自定义域名到 Cloudflare Tunnel..."
echo "将 $FULL_DOMAIN 绑定到 tunnel..."
BIND_RESULT=$(cloudflared tunnel route dns $TUNNEL_NAME $FULL_DOMAIN 2>&1)

if echo "$BIND_RESULT" | grep -q "Failed to add route"; then
    echo "警告：绑定域名失败，可能是因为DNS记录已存在"
    echo "错误信息：$BIND_RESULT"
    echo "请在 Cloudflare 仪表盘中手动删除现有记录后重新运行绑定命令"
else
    echo "成功绑定 $FULL_DOMAIN 到 Cloudflare Tunnel"
fi

# 步骤15：验证部署状态
echo "\n=== 部署完成，验证服务状态 ==="
echo "\n1. code Server 状态:"
systemctl is-active code-server@root
echo "\n2. Cloudflare Tunnel 状态:"
systemctl is-active cloudflared

# 步骤16：显示访问信息
echo "\n=== 访问信息 ==="
echo "\ncode Server 访问地址:"
echo "- 自定义域名: https://$FULL_DOMAIN"
echo "- Cloudflare Tunnel 默认地址: https://$TUNNEL_ID.cfargotunnel.com"
echo "\ncode Server 登录密码: $CODESERVER_PASSWORD"
echo "\n=== 部署完成 ==="
