#!/bin/bash

# Deployment script: Install and configure code Server + Cloudflare Tunnel
# Author: Trae Assistant
# Date: 2026-02-10

set -e

# Function to handle dpkg lock files
check_and_handle_dpkg_lock() {
    echo "Checking dpkg lock status..."
    if [ -f "/var/lib/dpkg/lock" ] || [ -f "/var/lib/dpkg/lock-frontend" ]; then
        echo "Detected dpkg lock files, attempting to release..."
        # Try to terminate processes holding the lock
        sudo fuser -vki -TERM /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
        # Complete pending configurations
        sudo dpkg --configure --pending 2>/dev/null || true
        # Wait a few seconds for the system to stabilize
        sleep 3
    fi
}

# Function to check and restart code-server service
restart_code_server() {
    echo "Checking code-server service status..."
    # Check if service exists
    if systemctl list-unit-files | grep -q code-server@.service; then
        echo "Restarting code-server service to apply new configuration..."
        systemctl restart code-server@root 2>/dev/null || systemctl start code-server@root
        sleep 2
        # Check service status
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
echo "1. Execute system update (recommended, ensure system packages are up to date)"
echo "2. Skip system update (quick deployment, use existing packages)"
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
apt install -y curl qrencode

echo ""
echo "3. Installing code Server..."
curl -fsSL https://code-server.dev/install.sh | sh

echo ""
echo "4. Configuring code Server..."

# Password input loop until two inputs match
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
        echo "Error: The two entered passwords do not match, please re-enter"
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
# Restart service to ensure password takes effect
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
        # Check if qrencode is installed
        if ! command -v qrencode &> /dev/null; then
            echo "Installing qrencode for generating QR codes..."
            apt update && apt install -y qrencode
        fi
        
        echo "=== Cloudflare Account Authorization ==="
        echo "You can use any of the following methods to authorize:"
        echo "- Authorize via link: Copy the link below and open it in a browser"
        echo "- Authorize via QR code: Use your phone camera to scan the QR code below"
        echo ""
        
        echo "=== Authorization Instructions ==="
        echo "1. Select any of the above authorization methods"
        echo "2. Log in to your Cloudflare account in the browser"
        echo "3. Click the 'Authorize' button to complete authorization"
        echo "4. After successful authorization, press Enter to continue"
        echo ""
        
        # Run authorization command in background, capture output
        cloudflared tunnel login > /tmp/auth_output.txt 2>&1 &
        
        # Save background process PID
        AUTH_PID=$!
        
        # Wait a few seconds to ensure the command has generated the authorization URL
        echo "Generating authorization URL..."
        sleep 3
        
        # Extract authorization URL from output file
        AUTH_URL=$(grep -o "https://dash.cloudflare.com/argotunnel.*" /tmp/auth_output.txt)
        
        if [ -n "$AUTH_URL" ]; then
            echo ""
            echo "=== Method 1: Authorize via link ==="
            echo "Authorization URL:"
            echo "$AUTH_URL"
            echo ""
            echo "=== Method 2: Authorize via QR code ==="
            echo "Please use your phone camera to scan the QR code below:"
            echo ""
            
            # Generate QR code (using compact ASCII mode)
            qrencode -t ASCII -s 1 "$AUTH_URL"
            echo ""
            
            # Wait for user input
            read -p "After authorization is complete, press Enter to continue: "
            
            # Wait for background authorization process to complete
            wait $AUTH_PID 2>/dev/null
        else
            echo "Failed to obtain authorization URL, executing authorization command directly..."
            # Execute authorization command directly
            cloudflared tunnel login
        fi
    else
        echo "Using existing certificate"
    fi
else
    # Check if qrencode is installed
    if ! command -v qrencode &> /dev/null; then
        echo "Installing qrencode for generating QR codes..."
        apt update && apt install -y qrencode
    fi
    
    echo "=== Cloudflare Account Authorization ==="
    echo "You can use any of the following methods to authorize:"
    echo "- Authorize via link: Copy the link below and open it in a browser"
    echo "- Authorize via QR code: Use your phone camera to scan the QR code below"
    echo ""
    
    echo "=== Authorization Instructions ==="
    echo "1. Select any of the above authorization methods"
    echo "2. Log in to your Cloudflare account in the browser"
    echo "3. Click the 'Authorize' button to complete authorization"
    echo "4. After successful authorization, press Enter to continue"
    echo ""
    
    # Run authorization command in background, capture output
    cloudflared tunnel login > /tmp/auth_output.txt 2>&1 &
    
    # Save background process PID
    AUTH_PID=$!
    
    # Wait a few seconds to ensure the command has generated the authorization URL
    echo "Generating authorization URL..."
    sleep 3
    
    # Extract authorization URL from output file
    AUTH_URL=$(grep -o "https://dash.cloudflare.com/argotunnel.*" /tmp/auth_output.txt)
    
    if [ -n "$AUTH_URL" ]; then
        echo ""
        echo "=== Method 1: Authorize via link ==="
        echo "Authorization URL:"
        echo "$AUTH_URL"
        echo ""
        echo "=== Method 2: Authorize via QR code ==="
        echo "Please use your phone camera to scan the QR code below:"
        echo ""
        
        # Generate QR code (using compact ASCII mode)
        qrencode -t ASCII -s 1 "$AUTH_URL"
        echo ""
        
        # Wait for user input
        read -p "After authorization is complete, press Enter to continue: "
        
        # Wait for background authorization process to complete
        wait $AUTH_PID 2>/dev/null
    else
        echo "Failed to obtain authorization URL, executing authorization command directly..."
        # Execute authorization command directly
        cloudflared tunnel login
    fi
fi

echo ""
echo "8. Verifying Cloudflare authorization..."
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "Error: Cloudflare authorization failed, please re-execute the authorization step"
    exit 1
fi
echo "Cloudflare authorization successful!"

echo ""
echo "9. Configuring full domain..."
echo "Please enter the full domain you want to use (e.g., code.example.com):"
read -p "Full domain: " FULL_DOMAIN

if [ -z "$FULL_DOMAIN" ]; then
    echo "Error: Domain cannot be empty"
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
        echo "Retrieving existing tunnel list..."
        
        # Loop to try getting tunnel list, maximum 3 attempts
        MAX_RETRIES=3
        RETRY_COUNT=0
        TUNNEL_LIST=""
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            TUNNEL_LIST=$(cloudflared tunnel list 2>&1)
            
            # Check if command executed successfully
            if [ $? -eq 0 ]; then
                # Check if it contains valid tunnel information
                if echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
                    break
                else
                    echo "Warning: Obtained tunnel list has abnormal format, attempting to re-authorize..."
                fi
            else
                echo "Error: Failed to obtain tunnel list, error message: $TUNNEL_LIST"
                echo "Attempting to re-authorize..."
            fi
            
            # Re-authorize
            cloudflared tunnel login
            RETRY_COUNT=$((RETRY_COUNT + 1))
            
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo "Retrying to obtain tunnel list..."
            fi
        done
        
        # Check if tunnel list was successfully obtained
        if [ -z "$TUNNEL_LIST" ] || ! echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            echo "Error: Failed to obtain valid tunnel list, please try again later"
            exit 1
        fi
        
        echo "Debug info: Obtained tunnel list content:"
        echo "$TUNNEL_LIST"
        echo "---------------------------------------------------------------"
        
        # Parse tunnel list and display numbered options
        echo "\nExisting tunnel list:"
        echo "No.  ID                                   NAME              CREATED"
        echo "---------------------------------------------------------------"
        
        # Parse tunnel information into array
        TUNNEL_ITEMS=()
        while IFS= read -r line; do
            if echo "$line" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
                TUNNEL_ITEMS+=("$line")
            fi
        done <<< "$TUNNEL_LIST"
        
        # Display tunnel list
        for i in "${!TUNNEL_ITEMS[@]}"; do
            index=$((i+1))
            tunnel_line=${TUNNEL_ITEMS[$i]}
            # Extract tunnel information, handle possible space issues
            tunnel_id=$(echo "$tunnel_line" | awk '{print $1}')
            tunnel_name=$(echo "$tunnel_line" | awk '{print $2}')
            tunnel_created=$(echo "$tunnel_line" | awk '{print $3 " " $4 " " $5 " " $6 " " $7}')
            printf "%2d   %s   %-16s   %s\n" "$index" "$tunnel_id" "$tunnel_name" "$tunnel_created"
        done
        
        # Check if there are any tunnels available
        if [ ${#TUNNEL_ITEMS[@]} -eq 0 ]; then
            echo "Error: No existing tunnels found, please select to create a new tunnel"
            exit 1
        fi
        
        # Let user select tunnel
        read -p "\nPlease enter the tunnel number you want to use: " tunnel_index
        
        # Validate input
        if [[ "$tunnel_index" =~ ^[0-9]+$ ]] && [ "$tunnel_index" -ge 1 ] && [ "$tunnel_index" -le "${#TUNNEL_ITEMS[@]}" ]; then
            # Get selected tunnel information
            selected_index=$((tunnel_index-1))
            selected_tunnel=${TUNNEL_ITEMS[$selected_index]}
            TUNNEL_ID=$(echo "$selected_tunnel" | awk '{print $1}')
            TUNNEL_NAME=$(echo "$selected_tunnel" | awk '{print $2}')
            
            echo "\nYour selected tunnel:"
            echo "ID: $TUNNEL_ID"
            echo "Name: $TUNNEL_NAME"
            
            # Check if credentials file exists locally
            CREDENTIALS_FILE="/root/.cloudflared/$TUNNEL_ID.json"
            echo "Debug info: Checking credentials file path: $CREDENTIALS_FILE"
            
            if [ ! -f "$CREDENTIALS_FILE" ]; then
                echo "\nDetected missing credentials file for this tunnel locally"
                echo "Execution plan: Delete existing tunnel and recreate to obtain new credentials file..."
                
                # Delete existing tunnel
                echo "Deleting existing tunnel '$TUNNEL_NAME'..."
                DELETE_RESULT=$(cloudflared tunnel delete $TUNNEL_ID 2>&1)
                echo "Tunnel deletion result: $DELETE_RESULT"
                
                # Recreate tunnel with the same name
                echo "Recreating tunnel '$TUNNEL_NAME'..."
                CREATE_RESULT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
                echo "Tunnel creation result: $CREATE_RESULT"
                
                # Extract new tunnel ID
                NEW_TUNNEL_ID=$(echo "$CREATE_RESULT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
                
                if [[ "$NEW_TUNNEL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
                    echo "Successfully recreated tunnel, new ID: $NEW_TUNNEL_ID"
                    # Update TUNNEL_ID variable
                    TUNNEL_ID="$NEW_TUNNEL_ID"
                    # Update credentials file path
                    CREDENTIALS_FILE="/root/.cloudflared/$TUNNEL_ID.json"
                    echo "Debug info: New credentials file path: $CREDENTIALS_FILE"
                    
                    # Check if new credentials file was generated
                    if [ -f "$CREDENTIALS_FILE" ]; then
                        echo "Successfully obtained new tunnel credentials file"
                    else
                        echo "Error: Credentials file still not generated after recreating tunnel"
                        exit 1
                    fi
                else
                    echo "Error: Failed to recreate tunnel"
                    echo "Creation output: $CREATE_RESULT"
                    exit 1
                fi
            else
                echo "Credentials file for this tunnel already exists locally"
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
# Check if service is already installed
if [ -f "/etc/systemd/system/cloudflared.service" ]; then
    echo "Detected Cloudflare Tunnel service already exists, uninstalling old service first..."
    cloudflared service uninstall
fi
# Install new service
cloudflared service install
systemctl enable --now cloudflared

sleep 5

echo ""
echo "14. Binding custom domain to Cloudflare Tunnel..."
echo "Binding $FULL_DOMAIN to tunnel..."
BIND_RESULT=$(cloudflared tunnel route dns $TUNNEL_NAME $FULL_DOMAIN 2>&1)

if echo "$BIND_RESULT" | grep -q "Failed to add route"; then
    echo "Warning: Failed to bind domain, possibly because DNS record already exists"
    echo "Error message: $BIND_RESULT"
    echo "Please manually delete existing records in Cloudflare dashboard and re-run the binding command"
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
echo "=== Access Information ==="
echo ""
echo "code Server access addresses:"
echo "- Custom domain: https://$FULL_DOMAIN"
echo "- Cloudflare Tunnel default address: https://$TUNNEL_ID.cfargotunnel.com"
echo ""
echo "code Server login password: $CODESERVER_PASSWORD"
echo ""
echo "=== Deployment completed ==="
