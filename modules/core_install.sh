#!/bin/bash

CONFIG_DIR="/opt/matrix-install"

# Get server configuration
if [ ! -f "$CONFIG_DIR/domain" ]; then
    read -p "Enter your matrix server domain (e.g., matrix.example.com): " MATRIX_DOMAIN
    echo "$MATRIX_DOMAIN" > "$CONFIG_DIR/domain"
else
    MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain")
fi

# Install dependencies
apt update && apt upgrade -y
apt install -y curl wget git

# Install Synapse
wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list

apt update
apt install -y matrix-synapse-py3

# Configure server name
echo "server_name: \"$MATRIX_DOMAIN\"" > /etc/matrix-synapse/conf.d/server_name.yaml

# Install PostgreSQL
apt install -y postgresql

# Configure database
sudo -i -u postgres createuser --pwprompt synapse_user
sudo -i -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse_user synapse_db

DB_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
echo "DB_PASSWORD=\"$DB_PASSWORD\"" >> "$CONFIG_DIR/db_config"

sudo -i -u postgres psql -c "ALTER USER synapse_user WITH PASSWORD '$DB_PASSWORD';"

# Configure Synapse database
cat > /etc/matrix-synapse/conf.d/database.yaml <<EOL
database:
  name: psycopg2
  args:
    user: synapse_user
    password: '$DB_PASSWORD'
    database: synapse_db
    host: localhost
    port: 5432
    cp_min: 5
    cp_max: 10
EOL

# Generate registration secret
REG_SECRET=$(cat /dev/urandom | tr -cd '[:alnum:]' | fold -w 256 | head -n 1)
echo "registration_shared_secret: '$REG_SECRET'" > /etc/matrix-synapse/conf.d/registration_shared_secret.yaml
echo "REGISTRATION_SHARED_SECRET=\"$REG_SECRET\"" >> "$CONFIG_DIR/secrets"

# Restart synapse
systemctl restart matrix-synapse.service

echo "Matrix Synapse and PostgreSQL installed successfully"