#!/bin/bash

CONFIG_DIR="/opt/matrix-install"
MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain" 2>/dev/null)

if [ -z "$MATRIX_DOMAIN" ]; then
    echo "Matrix domain not configured. Please run core installation first."
    exit 1
fi

show_menu() {
    echo "
Federation Control
-----------------
1) Enable Federation
2) Disable Federation
3) Check Federation Status
4) Back to Main Menu
"
    read -p "Select option: " choice

    case $choice in
        1)
            # Enable federation in Synapse
            echo "federation_domain_whitelist:" > /etc/matrix-synapse/conf.d/federation.yaml
            echo "  - '$MATRIX_DOMAIN'" >> /etc/matrix-synapse/conf.d/federation.yaml
            echo "  - 'matrix.org'" >> /etc/matrix-synapse/conf.d/federation.yaml
            echo "  - 'vector.im'" >> /etc/matrix-synapse/conf.d/federation.yaml
            
            # Update Caddy configuration for federation port
            if grep -q ":8448" /etc/caddy/Caddyfile; then
                echo "Caddy already configured for federation"
            else
                sed -i "/reverse_proxy \/_matrix/a \ \ \ \ reverse_proxy :8448 http://localhost:8008" /etc/caddy/Caddyfile
            fi
            
            systemctl restart matrix-synapse.service
            systemctl reload caddy
            echo "Federation enabled for $MATRIX_DOMAIN"
            ;;
        2)
            # Disable federation
            echo "federation_domain_whitelist: []" > /etc/matrix-synapse/conf.d/federation.yaml
            systemctl restart matrix-synapse.service
            echo "Federation disabled"
            ;;
        3)
            echo "Testing federation for $MATRIX_DOMAIN..."
            curl -s "https://$MATRIX_DOMAIN/.well-known/matrix/server" || \
            echo "Federation well-known file not found or server not reachable"
            
            echo -e "\nYou can test federation at:"
            echo "https://federationtester.matrix.org/#$MATRIX_DOMAIN"
            ;;
        4) return ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

show_menu