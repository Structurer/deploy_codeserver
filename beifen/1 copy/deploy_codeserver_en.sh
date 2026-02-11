#!/bin/bash

# 部署脚本：在服务器上安装和配置 code Server + Cloudflare Tunnel
# 作者：Trae Assistant
# 日期：2026-02-10

set -e

# 处理 dpkg 锁文件的函数
check_and_handle_dpkg_lock() {
    echo "Checking dpkg lock status..."
    if [ -f "/var/lib/dpkg/lock" ] || [ -f "/var/lib/dpkg/lock-frontend" ]; then
        echo "Detected dpkg lock files, attempting to release..."
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
    echo "Checking code-server service status..."
    # 检查服务是否存在
    if systemctl list-unit-files | grep -q code-server@.service; then
        echo "Restarting code-server service to apply new configuration..."
        systemctl restart code-server@root 2>/dev/null || systemctl start code-server@root
        sleep 2
        # 检查服务状态
        systemctl status code-server@root --no-pager
    else
        echo "code-server service not yet installed, skipping restart operation..."
    fi
}

echo ""
echo "=== Starting code Server + Cloudflare Tunnel Deployment ==="

echo ""
echo "0. System update option..."
echo "System update may take a long time, skip?"
echo "1. Execute system update (recommended, ensure latest packages)"
echo "2. Skip system update (fast deployment, use existing packages)"
read -p "Please enter your choice (1/2): " update_choice

if [ "$update_choice" = "1" ]; then
    echo ""
echo "1. Updating system packages..."
    check_and_handle_dpkg_lock
    apt update && apt upgrade -y
else
    echo ""
echo "1. Skipping system update..."
fi

echo ""
echo "2. Installing necessary dependencies..."
check_and_handle_dpkg_lock
apt install -y curl

echo ""
echo "3. Installing code Server..."
curl -fsSL https://code-server.dev/install.sh | sh

echo ""
echo "4. Configuring code Server..."

# 密码输入循环，直到两次输入一致
while true; do
    echo "Please enter code Server login password:"
    read -s CODESERVER_PASSWORD
    echo ""
    echo "Confirm password:"
    read -s CODESERVER_PASSWORD_CONFIRM
    echo ""
    
    if [ "$CODESERVER_PASSWORD" = "$CODESERVER_PASSWORD_CONFIRM" ]; then
        echo "Password confirmed successfully!"
        break
    else
        echo "Error: Passwords do not match, please re-enter"
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
    echo "Configuration file created"
else
    sed -i "s/password: .*/password: $CODESERVER_PASSWORD/" /root/.config/code-server/config.yaml
    echo "Password updated"
fi

echo ""
echo "5. Starting and enabling code Server service..."
systemctl enable --now code-server@root
# 重启服务以确保密码生效
restart_code_server

echo ""
echo "=== code Server deployment completed ==="

echo ""
echo "6. Installing Cloudflare Tunnel client..."
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
check_and_handle_dpkg_lock
dpkg -i cloudflared.deb
rm -f cloudflared.deb

echo ""
echo "7. Cloudflare account authorization..."
if [ -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "Detected existing Cloudflare certificate"
    echo "Please select operation:"
    echo "1. Use existing certificate"
    echo "2. Re-authorize (overwrite existing certificate)"
    read -p "Please enter your choice (1/2): " cert_choice
    
    if [ "$cert_choice" = "2" ]; then
        echo "Deleting existing certificate..."
        rm -f "$HOME/.cloudflared/cert.pem"
        echo "Please open the following URL in your browser and login to Cloudflare account to authorize:"
        echo "After authorization is complete, press Enter to continue..."
        cloudflared tunnel login
    else
        echo "Using existing certificate"
    fi
else
    echo "Please open the following URL in your browser and login to Cloudflare account to authorize:"
    echo "After authorization is complete, press Enter to continue..."
    cloudflared tunnel login
fi

echo ""
echo "8. Verifying Cloudflare authorization..."
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "Error: Cloudflare authorization failed, please re-execute the authorization step"
    exit 1
fi
echo "Cloudflare authorization successful!"

echo ""
echo "9. Configuring full domain name..."
echo "Please enter the full domain name you want to use (e.g., code.example.com):"
read -p "Full domain name: " FULL_DOMAIN

if [ -z "$FULL_DOMAIN" ]; then
    echo "Error: Domain name cannot be empty"
    exit 1
fi

echo "Using domain: $FULL_DOMAIN"

echo ""
echo "11. Creating Cloudflare Tunnel..."
TUNNEL_NAME="codeserver-tunnel"
TUNNEL_ID=""

echo "Attempting to create tunnel '$TUNNEL_NAME'..."
TUNNEL_CREATION_OUTPUT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1 || echo "Command execution failed: $?")
echo "Creation command output: $TUNNEL_CREATION_OUTPUT"

TUNNEL_ID=$(echo "$TUNNEL_CREATION_OUTPUT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
echo "Extracted Tunnel ID: '$TUNNEL_ID'"

if [ -z "$TUNNEL_ID" ] && echo "$TUNNEL_CREATION_OUTPUT" | grep -q "tunnel with name already exists"; then
    echo "Detected tunnel '$TUNNEL_NAME' already exists"
    echo "Please select operation:"
    echo "1. Use existing tunnel"
    echo "2. Create tunnel with new name"
    read -p "Please enter your choice (1/2): " tunnel_choice
    
    if [ "$tunnel_choice" = "1" ]; then
        echo "Fetching existing tunnel list..."
        
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
                    echo "Warning: Obtained tunnel list format is abnormal, attempting to re-authorize..."
                fi
            else
                echo "Error: Failed to fetch tunnel list, error message: $TUNNEL_LIST"
                echo "Attempting to re-authorize..."
            fi
            
            # 重新授权
            cloudflared tunnel login
            RETRY_COUNT=$((RETRY_COUNT + 1))
            
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo "Retrying to fetch tunnel list..."
            fi
        done
        
        # 检查是否成功获取到 tunnel 列表
        if [ -z "$TUNNEL_LIST" ] || ! echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            echo "Error: Failed to fetch valid tunnel list, please try again later"
            exit 1
        fi
        
        echo "Debug info: Obtained tunnel list content:"
        echo "$TUNNEL_LIST"
        echo "---------------------------------------------------------------"
        
        # 解析 tunnel 列表并显示带序号的选项
        echo "\nExisting tunnel list:"
        echo "No.  ID                                   NAME              CREATED"
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
            echo "Error: No existing tunnels found, please choose to create a new tunnel"
            exit 1
        fi
        
        # 让用户选择 tunnel
        read -p "\nPlease enter the tunnel number to use: " tunnel_index
        
        # 验证输入
        if [[ "$tunnel_index" =~ ^[0-9]+$ ]] && [ "$tunnel_index" -ge 1 ] && [ "$tunnel_index" -le "${#TUNNEL_ITEMS[@]}" ]; then
            # 获取选中的 tunnel 信息
            selected_index=$((tunnel_index-1))
            selected_tunnel=${TUNNEL_ITEMS[$selected_index]}
            TUNNEL_ID=$(echo "$selected_tunnel" | awk '{print $1}')
            TUNNEL_NAME=$(echo "$selected_tunnel" | awk '{print $2}')
            
            echo "\nYour selected tunnel:"
            echo "ID: $TUNNEL_ID"
            echo "Name: $TUNNEL_NAME"
            
            # 检查本地是否存在凭据文件
            CREDENTIALS_FILE="/root/.cloudflared/$TUNNEL_ID.json"
            echo "Debug info: Checking credentials file path: $CREDENTIALS_FILE"
            
            if [ ! -f "$CREDENTIALS_FILE" ]; then
                echo "\nDetected missing credentials file for this tunnel"
                echo "Executing solution: Delete existing tunnel and recreate to obtain new credentials..."
                
                # 删除现有 tunnel
                echo "Deleting existing tunnel '$TUNNEL_NAME'..."
                DELETE_RESULT=$(cloudflared tunnel delete $TUNNEL_ID 2>&1)
                echo "Tunnel deletion result: $DELETE_RESULT"
                
                # 重新创建相同名称的 tunnel
                echo "Recreating tunnel '$TUNNEL_NAME'..."
                CREATE_RESULT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
                echo "Tunnel creation result: $CREATE_RESULT"
                
                # 提取新的 tunnel ID
                NEW_TUNNEL_ID=$(echo "$CREATE_RESULT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
                
                if [[ "$NEW_TUNNEL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
                    echo "Successfully recreated tunnel, new ID: $NEW_TUNNEL_ID"
                    # 更新 TUNNEL_ID 变量
                    TUNNEL_ID="$NEW_TUNNEL_ID"
                    # 更新凭据文件路径
                    CREDENTIALS_FILE="/root/.cloudflared/$TUNNEL_ID.json"
                    echo "Debug info: New credentials file path: $CREDENTIALS_FILE"
                    
                    # 检查新的凭据文件是否生成
                    if [ -f "$CREDENTIALS_FILE" ]; then
                        echo "Successfully obtained new tunnel credentials"
                    else
                        echo "Error: Credentials file not generated after recreating tunnel"
                        exit 1
                    fi
                else
                    echo "Error: Failed to recreate tunnel"
                    echo "Creation output: $CREATE_RESULT"
                    exit 1
                fi
            else
                echo "Local credentials file already exists for this tunnel"
                echo "Debug info: Credentials file size: $(ls -l $CREDENTIALS_FILE | awk '{print $5}') bytes"
            fi
            
            echo "Using existing Cloudflare Tunnel, ID: $TUNNEL_ID"
        else
            echo "Error: Invalid input, please re-execute the script"
            exit 1
        fi
    else
        echo "Please enter new tunnel name:"
        read -p "Tunnel name: " NEW_TUNNEL_NAME
        if [ -z "$NEW_TUNNEL_NAME" ]; then
            NEW_TUNNEL_NAME="codeserver-tunnel-$(date +%s)"
        fi
        echo "Creating tunnel named $NEW_TUNNEL_NAME..."
        TUNNEL_CREATION_OUTPUT=$(cloudflared tunnel create $NEW_TUNNEL_NAME 2>&1 || echo "Command execution failed: $?")
        echo "Creation command output: $TUNNEL_CREATION_OUTPUT"
        
        TUNNEL_ID=$(echo "$TUNNEL_CREATION_OUTPUT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
        echo "Extracted Tunnel ID: '$TUNNEL_ID'"
        
        if [[ "$TUNNEL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            TUNNEL_NAME="$NEW_TUNNEL_NAME"
            echo "Successfully created Cloudflare Tunnel, ID: $TUNNEL_ID"
        else
            echo "Error: Failed to create Cloudflare Tunnel"
            echo "Output information: $TUNNEL_CREATION_OUTPUT"
            exit 1
        fi
    fi
elif [ -z "$TUNNEL_ID" ]; then
    echo "Error: Failed to create Cloudflare Tunnel"
    echo "Output information: $TUNNEL_CREATION_OUTPUT"
    exit 1
else
    echo "Successfully created Cloudflare Tunnel, ID: $TUNNEL_ID"
fi

echo ""
echo "12. Configuring Cloudflare Tunnel..."
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
url: http://localhost:8080
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json
EOF

echo ""
echo "13. Starting and enabling Cloudflare Tunnel service..."
# 检查服务是否已安装
if [ -f "/etc/systemd/system/cloudflared.service" ]; then
    echo "Detected Cloudflare Tunnel service already exists, uninstalling old service..."
    cloudflared service uninstall
fi
# 安装新服务
cloudflared service install
systemctl enable --now cloudflared

sleep 5

echo ""
echo "14. Binding custom domain to Cloudflare Tunnel..."
echo "Binding $FULL_DOMAIN to tunnel..."
BIND_RESULT=$(cloudflared tunnel route dns $TUNNEL_NAME $FULL_DOMAIN 2>&1)

if echo "$BIND_RESULT" | grep -q "Failed to add route"; then
    echo "Warning: Failed to bind domain, may be due to existing DNS record"
    echo "Error message: $BIND_RESULT"
    echo "Please manually delete existing record in Cloudflare dashboard and re-run the binding command"
else
    echo "Successfully bound $FULL_DOMAIN to Cloudflare Tunnel"
fi

echo ""
echo "=== Deployment completed, verifying service status ==="
echo ""
echo "1. code Server status:"
systemctl is-active code-server@root
echo ""
echo "2. Cloudflare Tunnel status:"
systemctl is-active cloudflared

echo ""
echo "=== Access information ==="
echo ""
echo "code Server access addresses:"
echo "- Custom domain: https://$FULL_DOMAIN"
echo "- Cloudflare Tunnel default address: https://$TUNNEL_ID.cfargotunnel.com"
echo ""
echo "code Server login password: $CODESERVER_PASSWORD"
echo ""
echo "=== Deployment completed ==="
