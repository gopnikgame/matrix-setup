#!/bin/bash

CONFIG_DIR="/opt/matrix-install"
MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain" 2>/dev/null)

if [ -z "$MATRIX_DOMAIN" ]; then
    echo "Matrix domain not configured. Please run core installation first."
    exit 1
fi

# Ensure UFW is installed
apt install -y ufw

show_menu() {
    echo "
Firewall (UFW) Configuration
---------------------------
1) Configure Basic Firewall (HTTP/HTTPS only)
2) Configure Full Matrix Firewall (with federation)
3) Open Additional Port
4) Show Firewall Status
5) Back to Main Menu
"
    read -p "Select option: " choice

    case $choice in
        1)
            ufw --force reset
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow ssh
            ufw allow http
            ufw allow https
            ufw --force enable
            echo "Basic firewall configured (HTTP/HTTPS only)"
            ;;
        2)
            ufw --force reset
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow ssh
            ufw allow http
            ufw allow https
            ufw allow 8448/tcp  # Federation
            ufw allow 3478/tcp  # TURN
            ufw allow 3478/udp  # TURN
            ufw allow 5349/tcp  # TURN
            ufw allow 49152:65535/udp  # TURN UDP range
            ufw --force enable
            echo "Full Matrix firewall configured with federation ports"
            ;;
        3)
            read -p "Enter port number to open (e.g., 8008): " PORT_NUM
            read -p "Enter protocol (tcp/udp, default tcp): " PORT_PROTO
            PORT_PROTO=${PORT_PROTO:-tcp}
            ufw allow $PORT_NUM/$PORT_PROTO
            echo "Port $PORT_NUM/$PORT_PROTO opened"
            ;;
        4)
            ufw status numbered
            ;;
        5) return ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

show_menu