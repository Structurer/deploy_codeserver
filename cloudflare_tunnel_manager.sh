#!/bin/bash

# Cloudflare Tunnel Management Script
# Author: Trae Assistant
# Date: 2026-02-12

set -e

# Function to check Cloudflare authorization status
check_authorization() {
    echo "=== Checking Cloudflare Authorization Status ==="
    if [ -f "$HOME/.cloudflared/cert.pem" ]; then
        echo "✓ Cloudflare authorization found"
        echo "Certificate file: $HOME/.cloudflared/cert.pem"
        echo "Certificate size: $(ls -l $HOME/.cloudflared/cert.pem | awk '{print $5}') bytes"
        return 0
    else
        echo "✗ Cloudflare authorization not found"
        echo "Please run 'cloudflared tunnel login' to authorize"
        return 1
    fi
}

# Function to list existing Cloudflare Tunnels
list_tunnels() {
    echo "=== Listing Existing Cloudflare Tunnels ==="
    
    # Check authorization first
    check_authorization || return 1
    
    # Get tunnel list
    TUNNEL_LIST=$(cloudflared tunnel list 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get tunnel list"
        echo "Error message: $TUNNEL_LIST"
        return 1
    fi
    
    # Check if there are any tunnels
    if ! echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
        echo "No existing tunnels found"
        return 0
    fi
    
    # Display tunnel list in formatted way
    echo ""
    echo "No.  ID                                   Name"
    echo "---------------------------------------------------------------"
    
    # Parse tunnels into array
    TUNNELS=()
    while IFS= read -r line; do
        if echo "$line" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            # Store the entire line as a single array element
            TUNNELS+=("$line")
        fi
    done <<< "$TUNNEL_LIST"
    
    # Display numbered list
    for i in "${!TUNNELS[@]}"; do
        index=$((i+1))
        # Extract tunnel ID (first field)
        tunnel_id=$(echo "${TUNNELS[$i]}" | awk '{print $1}')
        # Extract tunnel name (all fields after the first)
        tunnel_name=$(echo "${TUNNELS[$i]}" | awk '{$1=""; print substr($0,2)}' | sed 's/[[:space:]]*$//')
        printf "%2d   %-36s %s\n" "$index" "$tunnel_id" "$tunnel_name"
    done
    
    echo ""
}

# Function to create a new Cloudflare Tunnel
create_tunnel() {
    echo "=== Creating New Cloudflare Tunnel ==="
    
    # Check authorization first
    check_authorization || return 1
    
    # Ask for tunnel name
    read -p "Enter tunnel name: " TUNNEL_NAME
    
    if [ -z "$TUNNEL_NAME" ]; then
        echo "Error: Tunnel name cannot be empty"
        return 1
    fi
    
    # Create tunnel
    echo "Creating tunnel '$TUNNEL_NAME'..."
    CREATE_RESULT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
    
    if echo "$CREATE_RESULT" | grep -q "Created tunnel"; then
        # Extract tunnel ID
        TUNNEL_ID=$(echo "$CREATE_RESULT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
        echo "Successfully created tunnel"
        echo "Tunnel ID: $TUNNEL_ID"
        echo "Tunnel Name: $TUNNEL_NAME"
        
        # Check if credentials file was generated
        CREDENTIALS_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"
        if [ -f "$CREDENTIALS_FILE" ]; then
            echo "Credentials file generated: $CREDENTIALS_FILE"
        else
            echo "Warning: Credentials file not found"
        fi
    else
        echo "Error: Failed to create tunnel"
        echo "Error message: $CREATE_RESULT"
        return 1
    fi
}

# Function to delete a Cloudflare Tunnel
.delete_tunnel() {
    echo "=== Deleting Cloudflare Tunnel ==="
    
    # Check authorization first
    check_authorization || return 1
    
    # Get tunnel list
    TUNNEL_LIST=$(cloudflared tunnel list 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get tunnel list"
        echo "Error message: $TUNNEL_LIST"
        return 1
    fi
    
    # Check if there are any tunnels
    if ! echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
        echo "No existing tunnels found"
        return 0
    fi
    
    # Display tunnels with numbers
    echo ""
    echo "Existing tunnels:"
    echo "-----------------"
    
    # Parse tunnels into array
    TUNNELS=()
    while IFS= read -r line; do
        if echo "$line" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            # Store the entire line as a single array element
            TUNNELS+=("$line")
        fi
    done <<< "$TUNNEL_LIST"
    
    # Show numbered list
    echo "No.  ID                                   Name"
    echo "---------------------------------------------------------------"
    for i in "${!TUNNELS[@]}"; do
        index=$((i+1))
        # Extract tunnel ID (first field)
        tunnel_id=$(echo "${TUNNELS[$i]}" | awk '{print $1}')
        # Extract tunnel name (all fields after the first)
        tunnel_name=$(echo "${TUNNELS[$i]}" | awk '{$1=""; print substr($0,2)}' | sed 's/[[:space:]]*$//')
        printf "%2d   %-36s %s\n" "$index" "$tunnel_id" "$tunnel_name"
    done
    
    # Ask for selection
    read -p "Enter the number of the tunnel to delete: " SELECTION
    
    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#TUNNELS[@]}" ]; then
        echo "Error: Invalid selection"
        return 1
    fi
    
    # Get selected tunnel
    selected_index=$((SELECTION-1))
    selected_tunnel=${TUNNELS[$selected_index]}
    tunnel_id=$(echo "$selected_tunnel" | awk '{print $1}')
    
    # Delete tunnel
    echo "Deleting tunnel '$tunnel_id'..."
    DELETE_RESULT=$(cloudflared tunnel delete $tunnel_id 2>&1)
    
    if echo "$DELETE_RESULT" | grep -q "deleted tunnel"; then
        echo "Successfully deleted tunnel"
    else
        echo "Error: Failed to delete tunnel"
        echo "Error message: $DELETE_RESULT"
        return 1
    fi
}

# Function to modify a Cloudflare Tunnel (delete and recreate)
modify_tunnel() {
    echo "=== Modifying Cloudflare Tunnel ==="
    echo "Note: This will delete the existing tunnel and recreate it with the same name"
    
    # Check authorization first
    check_authorization || return 1
    
    # Get tunnel list
    TUNNEL_LIST=$(cloudflared tunnel list 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get tunnel list"
        echo "Error message: $TUNNEL_LIST"
        return 1
    fi
    
    # Check if there are any tunnels
    if ! echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
        echo "No existing tunnels found"
        return 0
    fi
    
    # Display tunnels with numbers
    echo ""
    echo "Existing tunnels:"
    echo "-----------------"
    
    # Parse tunnels into array
    TUNNELS=()
    while IFS= read -r line; do
        if echo "$line" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            # Store the entire line as a single array element
            TUNNELS+=("$line")
        fi
    done <<< "$TUNNEL_LIST"
    
    # Show numbered list
    echo "No.  ID                                   Name"
    echo "---------------------------------------------------------------"
    for i in "${!TUNNELS[@]}"; do
        index=$((i+1))
        # Extract tunnel ID (first field)
        tunnel_id=$(echo "${TUNNELS[$i]}" | awk '{print $1}')
        # Extract tunnel name (all fields after the first)
        tunnel_name=$(echo "${TUNNELS[$i]}" | awk '{$1=""; print substr($0,2)}' | sed 's/[[:space:]]*$//')
        printf "%2d   %-36s %s\n" "$index" "$tunnel_id" "$tunnel_name"
    done
    
    # Ask for selection
    read -p "Enter the number of the tunnel to modify: " SELECTION
    
    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#TUNNELS[@]}" ]; then
        echo "Error: Invalid selection"
        return 1
    fi
    
    # Get selected tunnel
    selected_index=$((SELECTION-1))
    selected_tunnel=${TUNNELS[$selected_index]}
    tunnel_id=$(echo "$selected_tunnel" | awk '{print $1}')
    tunnel_name=$(echo "$selected_tunnel" | awk '{print $2}')
    
    # Delete existing tunnel
    echo "Deleting existing tunnel '$tunnel_id'..."
    DELETE_RESULT=$(cloudflared tunnel delete $tunnel_id 2>&1)
    
    if ! echo "$DELETE_RESULT" | grep -q "deleted tunnel"; then
        echo "Error: Failed to delete existing tunnel"
        echo "Error message: $DELETE_RESULT"
        return 1
    fi
    
    # Use the same name for the new tunnel
    TUNNEL_NAME="$tunnel_name"
    
    # Recreate tunnel with the same name
    echo "Recreating tunnel '$TUNNEL_NAME'..."
    CREATE_RESULT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
    
    if echo "$CREATE_RESULT" | grep -q "Created tunnel"; then
        # Extract tunnel ID
        NEW_TUNNEL_ID=$(echo "$CREATE_RESULT" | grep "Created tunnel" | grep "with id" | awk -F 'id ' '{print $2}' | tr -d '\n')
        echo "Successfully modified tunnel"
        echo "New Tunnel ID: $NEW_TUNNEL_ID"
        echo "Tunnel Name: $TUNNEL_NAME"
        
        # Check if credentials file was generated
        CREDENTIALS_FILE="$HOME/.cloudflared/$NEW_TUNNEL_ID.json"
        if [ -f "$CREDENTIALS_FILE" ]; then
            echo "New credentials file generated: $CREDENTIALS_FILE"
        else
            echo "Warning: Credentials file not found"
        fi
    else
        echo "Error: Failed to recreate tunnel"
        echo "Error message: $CREATE_RESULT"
        return 1
    fi
}

# Function to manage DNS records for a tunnel
manage_dns() {
    echo "=== Managing DNS Records ==="
    
    # Check authorization first
    check_authorization || return 1
    
    # Get tunnel list
    TUNNEL_LIST=$(cloudflared tunnel list 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get tunnel list"
        echo "Error message: $TUNNEL_LIST"
        return 1
    fi
    
    # Check if there are any tunnels
    if ! echo "$TUNNEL_LIST" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
        echo "No existing tunnels found"
        return 0
    fi
    
    # Display tunnels with numbers
    echo ""
    echo "Existing tunnels:"
    echo "-----------------"
    
    # Parse tunnels into array
    TUNNELS=()
    while IFS= read -r line; do
        if echo "$line" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            # Store the entire line as a single array element
            TUNNELS+=("$line")
        fi
    done <<< "$TUNNEL_LIST"
    
    # Show numbered list
    echo "No.  ID                                   Name"
    echo "---------------------------------------------------------------"
    for i in "${!TUNNELS[@]}"; do
        index=$((i+1))
        # Extract tunnel ID (first field)
        tunnel_id=$(echo "${TUNNELS[$i]}" | awk '{print $1}')
        # Extract tunnel name (all fields after the first)
        tunnel_name=$(echo "${TUNNELS[$i]}" | awk '{$1=""; print substr($0,2)}' | sed 's/[[:space:]]*$//')
        printf "%2d   %-36s %s\n" "$index" "$tunnel_id" "$tunnel_name"
    done
    
    # Ask for selection
    read -p "Enter the number of the tunnel to manage DNS records: " SELECTION
    
    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#TUNNELS[@]}" ]; then
        echo "Error: Invalid selection"
        return 1
    fi
    
    # Get selected tunnel
    selected_index=$((SELECTION-1))
    selected_tunnel=${TUNNELS[$selected_index]}
    tunnel_id=$(echo "$selected_tunnel" | awk '{print $1}')
    
    # Ask for domain
    read -p "Enter domain to associate with tunnel (e.g., code.example.com): " DOMAIN
    
    if [ -z "$DOMAIN" ]; then
        echo "Error: Domain cannot be empty"
        return 1
    fi
    
    # Associate domain with tunnel
    echo "Associating domain '$DOMAIN' with tunnel '$tunnel_id'..."
    BIND_RESULT=$(cloudflared tunnel route dns $tunnel_id $DOMAIN 2>&1)
    
    if echo "$BIND_RESULT" | grep -q "Successfully added DNS record"; then
        echo "Successfully associated domain with tunnel"
    elif echo "$BIND_RESULT" | grep -q "Failed to add route"; then
        echo "Warning: Failed to add DNS record, possibly because it already exists"
        echo "Error message: $BIND_RESULT"
    else
        echo "Error: Failed to associate domain with tunnel"
        echo "Error message: $BIND_RESULT"
        return 1
    fi
}

# Main menu function
main_menu() {
    clear
    echo "===================================="
    echo "Cloudflare Tunnel Management Script"
    echo "===================================="
    echo ""
    
    while true; do
        echo "Main Menu:"
        echo "1. Check Cloudflare Authorization Status"
        echo "2. List Existing Tunnels"
        echo "3. Create New Tunnel"
        echo "4. Delete Tunnel"
        echo "5. Modify Tunnel (Delete and Recreate)"
        echo "6. Manage DNS Records"
        echo "7. Exit"
        echo ""
        read -p "Enter your choice (1-7): " choice
        echo ""
        
        case $choice in
            1)
                check_authorization
                ;;
            2)
                list_tunnels
                ;;
            3)
                create_tunnel
                ;;
            4)
                delete_tunnel
                ;;
            5)
                modify_tunnel
                ;;
            6)
                manage_dns
                ;;
            7)
                echo "Exiting..."
                return 0
                ;;
            *)
                echo "Error: Invalid choice"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..." dummy
        clear
        echo "===================================="
        echo "Cloudflare Tunnel Management Script"
        echo "===================================="
        echo ""
    done
}

# Fix the function name (remove the dot)
delete_tunnel() {
    .delete_tunnel "$@"
}

# Start the script
main_menu
