#!/bin/bash

# 部署脚本：在服务器上安装和配置 code Server + Cloudflare Tunnel
# 作者：Trae Assistant
# 日期：2026-02-10

set -e

echo "=== 开始部署 code Server + Cloudflare Tunnel ==="

# 步骤1：系统更新
echo "\n1. 更新系统包..."
apt update && apt upgrade -y

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
echo "请在浏览器中打开以下URL并登录Cloudflare账户授权："
echo "授权完成后，按回车键继续..."
cloudflared tunnel login

# 步骤8：验证授权是否成功
echo "\n8. 验证 Cloudflare 授权..."
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "错误：Cloudflare 授权失败，请重新执行授权步骤"
    exit 1
fi
echo "Cloudflare 授权成功！"

# 步骤9：提取已授权的域名
echo "\n9. 提取已授权的域名..."
# 创建临时目录
temp_dir=$(mktemp -d)
# 复制证书文件到临时目录
cp ~/.cloudflared/cert.pem $temp_dir/
cd $temp_dir

# 提取证书中的域名信息
echo "正在提取已授权的域名..."
domains=()
index=1

# 使用 openssl 解析证书，提取 subjectAlternativeName
if command -v openssl &> /dev/null; then
    # 提取 subjectAlternativeName 字段
    san=$(openssl x509 -in cert.pem -noout -ext subjectAlternativeName 2>/dev/null || echo "")
    
    if [ -n "$san" ]; then
        # 解析 DNS 名称
        while IFS= read -r line; do
            if [[ $line == *"DNS:"* ]]; then
                # 提取 DNS 名称
                dns_name=$(echo $line | sed 's/.*DNS://g' | sed 's/,.*//g' | xargs)
                if [ -n "$dns_name" ]; then
                    domains+=($dns_name)
                    echo "$index. $dns_name"
                    index=$((index+1))
                fi
            fi
        done <<< "$san"
    fi
fi

# 如果没有提取到域名，使用默认方法
if [ ${#domains[@]} -eq 0 ]; then
    echo "未检测到已授权的域名，请手动输入"
    # 保持原有的手动输入逻辑
    MANUAL_DOMAIN_INPUT=true
else
    # 让用户选择域名
    echo "\n请输入要使用的域名序号："
    read domain_index
    
    # 验证输入
    if [[ $domain_index =~ ^[0-9]+$ ]] && [ $domain_index -ge 1 ] && [ $domain_index -le ${#domains[@]} ]; then
        MAIN_DOMAIN=${domains[$((domain_index-1))]}
        echo "您选择的域名：$MAIN_DOMAIN"
    else
        echo "输入无效，将使用手动输入方式"
        MANUAL_DOMAIN_INPUT=true
    fi
fi

# 清理临时目录
cd /
rm -rf $temp_dir

# 如果需要手动输入主域名
if [ "$MANUAL_DOMAIN_INPUT" = "true" ]; then
    echo "请输入主域名（如 ceshi.autos）："
    read MAIN_DOMAIN
fi

# 步骤10：输入子域名前缀（提供默认值）
echo "\n10. 配置子域名..."
default_subdomain="code"
echo "请输入子域名前缀（默认: $default_subdomain）："
echo "直接按回车键使用默认值，或输入自定义前缀"
read -p "子域名前缀: " SUBDOMAIN_PREFIX

# 如果用户没有输入，使用默认值
if [ -z "$SUBDOMAIN_PREFIX" ]; then
    SUBDOMAIN_PREFIX=$default_subdomain
    echo "使用默认子域名前缀: $SUBDOMAIN_PREFIX"
else
    echo "使用自定义子域名前缀: $SUBDOMAIN_PREFIX"
fi

# 拼接完整域名
FULL_DOMAIN="$SUBDOMAIN_PREFIX.$MAIN_DOMAIN"
echo "完整域名: $FULL_DOMAIN"

# 步骤11：创建 Cloudflare Tunnel
echo "\n11. 创建 Cloudflare Tunnel..."
echo "创建名为 codeserver-tunnel 的 tunnel..."
TUNNEL_CREATION_OUTPUT=$(cloudflared tunnel create codeserver-tunnel)
TUNNEL_ID=$(echo "$TUNNEL_CREATION_OUTPUT" | grep "Created tunnel codeserver-tunnel with id" | awk '{print $7}')

if [ -z "$TUNNEL_ID" ]; then
    echo "错误：创建 Cloudflare Tunnel 失败"
    echo "输出信息：$TUNNEL_CREATION_OUTPUT"
    exit 1
fi
echo "成功创建 Cloudflare Tunnel，ID: $TUNNEL_ID"

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
BIND_RESULT=$(cloudflared tunnel route dns codeserver-tunnel $FULL_DOMAIN 2>&1)

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
