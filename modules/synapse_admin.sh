#!/bin/bash

CONFIG_DIR="/opt/matrix-install"
MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain" 2>/dev/null)

if [ -z "$MATRIX_DOMAIN" ]; then
    echo "Matrix domain not configured. Please run core installation first."
    exit 1
fi

install_synapse_admin() {
    SYNAPSE_ADMIN_DIR="/var/www/synapse-admin"
    mkdir -p "$SYNAPSE_ADMIN_DIR"
    
    echo "Installing Synapse Admin..."
    
    # Get latest release
    LATEST=$(curl -s https://api.github.com/repos/Awesome-Technologies/synapse-admin/releases/latest | grep browser_download_url | grep '.tar.gz"' | cut -d '"' -f 4)
    
    # Download and extract
    wget "$LATEST" -O "$SYNAPSE_ADMIN_DIR/synapse-admin.tar.gz"
    tar xf "$SYNAPSE_ADMIN_DIR/synapse-admin.tar.gz" -C "$SYNAPSE_ADMIN_DIR" --strip-components=1
    rm "$SYNAPSE_ADMIN_DIR/synapse-admin.tar.gz"
    
    echo "Synapse Admin installed successfully"
}

configure_caddy() {
    read -p "Enter Synapse Admin domain (e.g., admin.example.com): " ADMIN_DOMAIN
    echo "$ADMIN_DOMAIN" > "$CONFIG_DIR/admin_domain"
    
    # Add to Caddyfile
    if ! grep -q "$ADMIN_DOMAIN" /etc/caddy/Caddyfile; then
        cat >> /etc/caddy/Caddyfile <<EOL

$ADMIN_DOMAIN {
    root * /var/www/synapse-admin
    file_server
    encode gzip
}
EOL
        systemctl reload caddy
    fi
    
    # Get TLS certificate
    certbot --nginx -d "$ADMIN_DOMAIN" --non-interactive --agree-tos --redirect
    systemctl reload caddy
    
    echo "Synapse Admin configured at https://$ADMIN_DOMAIN"
}

show_menu() {
    echo "
Synapse Admin Configuration
--------------------------
1) Install/Update Synapse Admin
2) Configure Domain and Reverse Proxy
3) Back to Main Menu
"
    read -p "Select option: " choice

    case $choice in
        1) install_synapse_admin ;;
        2) configure_caddy ;;
        3) return ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

show_menu