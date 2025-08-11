#!/bin/bash

CONFIG_DIR="/opt/matrix-install"

show_menu() {
    echo "
User Registration Control
------------------------
1) Enable open registration
2) Enable registration with email verification
3) Disable registration
4) Back to main menu
"
    read -p "Select option: " choice

    case $choice in
        1)
            echo "enable_registration: true" > /etc/matrix-synapse/conf.d/registration.yaml
            echo "enable_registration_without_verification: true" >> /etc/matrix-synapse/conf.d/registration.yaml
            systemctl restart matrix-synapse.service
            echo "Open registration enabled"
            ;;
        2)
            read -p "Enter SMTP host: " SMTP_HOST
            read -p "Enter SMTP port: " SMTP_PORT
            read -p "Enter SMTP username: " SMTP_USER
            read -p "Enter SMTP password: " SMTP_PASS
            read -p "Enter from address (e.g., noreply@example.com): " FROM_ADDR
            
            cat > /etc/matrix-synapse/conf.d/registration.yaml <<EOL
enable_registration: true
registrations_require_3pid:
  - email

email:
  smtp_host: '$SMTP_HOST'
  smtp_port: $SMTP_PORT
  smtp_user: '$SMTP_USER'
  smtp_pass: '$SMTP_PASS'
  require_transport_security: true
  notif_from: '$FROM_ADDR'
EOL
            systemctl restart matrix-synapse.service
            echo "Registration with email verification enabled"
            ;;
        3)
            echo "enable_registration: false" > /etc/matrix-synapse/conf.d/registration.yaml
            systemctl restart matrix-synapse.service
            echo "Registration disabled"
            ;;
        4) return ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

show_menu