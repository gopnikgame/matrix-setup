#!/bin/bash

CONFIG_DIR="/opt/matrix-install"
MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain")

# Install Caddy
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install -y caddy

# Configure Caddy
cat > /etc/caddy/Caddyfile <<EOL
$MATRIX_DOMAIN {
    reverse_proxy /_matrix/* http://localhost:8008
    reverse_proxy /_synapse/client/* http://localhost:8008

    # Enable federation
    reverse_proxy :8448 http://localhost:8008

    header {
        # Enable CORS
        Access-Control-Allow-Origin *
        Access-Control-Allow-Methods *
        Access-Control-Allow-Headers *
    }
}
EOL

# Restart Caddy
systemctl restart caddy

echo "Caddy configured for Matrix domain: $MATRIX_DOMAIN"