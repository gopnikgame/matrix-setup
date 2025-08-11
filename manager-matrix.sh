#!/bin/bash

CONFIG_DIR="/opt/matrix-install"
MODULES_DIR="/opt/matrix-setup/modules"

# Load or initialize configuration
load_config() {
    if [ ! -d "$CONFIG_DIR" ]; then
        sudo mkdir -p "$CONFIG_DIR"
        sudo chown $SUDO_USER:$SUDO_USER "$CONFIG_DIR"
    fi
    
    if [ -f "$CONFIG_DIR/config" ]; then
        source "$CONFIG_DIR/config"
    else
        touch "$CONFIG_DIR/config"
    fi
}

# Update scripts
update_scripts() {
    echo "Updating matrix setup scripts..."
    cd /opt/matrix-setup
    sudo git pull origin main
    sudo chmod -R +x modules/*.sh
    echo "Scripts updated successfully"
}

# Main menu
show_menu() {
    echo "
Matrix Server Management
-----------------------
1) Install Matrix Core (Synapse + PostgreSQL)
2) Configure Caddy Reverse Proxy
3) User Registration Control
4) Federation Control
5) Configure Firewall (UFW)
6) Install Element Web
7) Install Synapse Admin
8) Update Scripts
9) Exit
"
    read -p "Select option: " choice

    case $choice in
        1) sudo $MODULES_DIR/core_install.sh ;;
        2) sudo $MODULES_DIR/caddy_config.sh ;;
        3) sudo $MODULES_DIR/registration_control.sh ;;
        4) sudo $MODULES_DIR/federation_control.sh ;;
        5) sudo $MODULES_DIR/ufw_config.sh ;;
        6) sudo $MODULES_DIR/element_web.sh ;;
        7) sudo $MODULES_DIR/synapse_admin.sh ;;
        8) update_scripts ;;
        9) exit 0 ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

load_config
show_menu