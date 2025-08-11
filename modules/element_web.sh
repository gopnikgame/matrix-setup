#!/bin/bash

CONFIG_DIR="/opt/matrix-install"
MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain" 2>/dev/null)

if [ -z "$MATRIX_DOMAIN" ]; then
    echo "Matrix domain not configured. Please run core installation first."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    apt install -y jq
fi

install_element() {
    ELEMENT_DIR="/var/www/element"
    mkdir -p "$ELEMENT_DIR/archive"
    
    # Get latest Element release
    LATEST=$(curl -s https://api.github.com/repos/vector-im/element-web/releases/latest | jq -r .tag_name)
    
    echo "Installing Element Web $LATEST..."
    
    # Download and extract
    wget "https://github.com/vector-im/element-web/releases/download/${LATEST}/element-${LATEST}.tar.gz" \
         -O "$ELEMENT_DIR/archive/element-${LATEST}.tar.gz"
    tar xf "$ELEMENT_DIR/archive/element-${LATEST}.tar.gz" -C "$ELEMENT_DIR/archive"
    
    # Create symlink
    ln -sfn "$ELEMENT_DIR/archive/element-${LATEST}" "$ELEMENT_DIR/current"
    
    # Create config
    cp "$ELEMENT_DIR/current/config.sample.json" "$ELEMENT_DIR/config.json"
    
    # Configure Element
    jq --arg domain "$MATRIX_DOMAIN" \
       '.default_server_config."m.homeserver".base_url = "https://\($domain)" | 
        .default_server_config."m.homeserver".server_name = $domain |
        .brand = "Element (\($domain))"' \
       "$ELEMENT_DIR/current/config.sample.json" > "$ELEMENT_DIR/config.json"
    
    ln -sf "$ELEMENT_DIR/config.json" "$ELEMENT_DIR/current/config.json"
    
    echo "Element Web installed successfully"
}

configure_caddy() {
    read -p "Enter Element domain (e.g., chat.example.com): " ELEMENT_DOMAIN
    echo "$ELEMENT_DOMAIN" > "$CONFIG_DIR/element_domain"
    
    # Add to Caddyfile
    if ! grep -q "$ELEMENT_DOMAIN" /etc/caddy/Caddyfile; then
        cat >> /etc/caddy/Caddyfile <<EOL

$ELEMENT_DOMAIN {
    root * /var/www/element/current
    file_server
    encode gzip
}
EOL
        systemctl reload caddy
    fi
    
    # Get TLS certificate
    certbot --nginx -d "$ELEMENT_DOMAIN" --non-interactive --agree-tos --redirect
    systemctl reload caddy
    
    echo "Element configured at https://$ELEMENT_DOMAIN"
}

show_menu() {
    echo "
Element Web Configuration
------------------------
1) Install/Update Element Web
2) Configure Domain and Reverse Proxy
3) Back to Main Menu
"
    read -p "Select option: " choice

    case $choice in
        1) install_element ;;
        2) configure_caddy ;;
        3) return ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

show_menu