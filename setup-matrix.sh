#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться от root" >&2
  exit 1
fi

# Определение типа сервера (Proxmox VPS или хостинг)
PUBLIC_IP=$(curl -s ifconfig.me)
LOCAL_IP=$(hostname -I | awk '{print $1}')
if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
  SERVER_TYPE="proxmox"
  echo "Обнаружена установка на Proxmox VPS"
  echo "Публичный IP: $PUBLIC_IP"
  echo "Локальный IP: $LOCAL_IP"
else
  SERVER_TYPE="hosting"
  echo "Обнаружена установка на хостинг VPS"
  echo "IP адрес: $PUBLIC_IP"
fi

# Запрос параметров
read -p "Введите домен для Matrix Synapse (например: matrix.example.com): " MATRIX_DOMAIN
read -p "Введите домен для Element Web (например: element.example.com): " ELEMENT_DOMAIN
read -p "Введите домен для Synapse Admin (например: admin.example.com): " ADMIN_DOMAIN
read -s -p "Введите пароль для пользователя PostgreSQL (matrix): " DB_PASSWORD
echo
read -p "Введите Registration Shared Secret (сгенерировать случайный? y/n): " GEN_REG_SECRET
if [ "$GEN_REG_SECRET" = "y" ]; then
  REGISTRATION_SHARED_SECRET=$(openssl rand -hex 32)
  echo "Сгенерирован Registration Shared Secret: $REGISTRATION_SHARED_SECRET"
else
  read -p "Введите Registration Shared Secret: " REGISTRATION_SHARED_SECRET
fi
read -p "Введите Turn Shared Secret (сгенерировать случайный? y/n): " GEN_TURN_SECRET
if [ "$GEN_TURN_SECRET" = "y" ]; then
  TURN_SHARED_SECRET=$(openssl rand -hex 32)
  echo "Сгенерирован Turn Shared Secret: $TURN_SHARED_SECRET"
else
  read -p "Введите Turn Shared Secret: " TURN_SHARED_SECRET
fi
read -p "Введите имя первого администратора (например: admin): " ADMIN_USER

# Обновление системы
echo "Обновление системы..."
apt update
apt upgrade -y

# Установка зависимостей (убираем certbot, так как Caddy сам управляет сертификатами)
echo "Установка зависимостей..."
apt install -y net-tools python3-dev python3-pip libpq-dev mc aptitude htop apache2-utils lsb-release wget apt-transport-https postgresql docker.io docker-compose git

# Установка psycopg2 через pip
echo "Установка psycopg2..."
pip3 install psycopg2

# Установка и настройка PostgreSQL
echo "Настройка PostgreSQL..."
# Создание пользователя и базы данных
sudo -u postgres createuser matrix
sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=matrix matrix
sudo -u postgres psql -c "ALTER USER matrix WITH PASSWORD '$DB_PASSWORD';"

# Настройка PostgreSQL для работы только с localhost
PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d'.' -f1)
sed -i "s/^#listen_addresses =.*/listen_addresses = 'localhost'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
systemctl restart postgresql

# Установка Matrix Synapse
echo "Установка Matrix Synapse..."
wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list
apt update
apt install -y matrix-synapse-py3

# Настройка homeserver.yaml
echo "Настройка Matrix Synapse..."
cat > /etc/matrix-synapse/homeserver.yaml <<EOL
server_name: "$MATRIX_DOMAIN"
pid_file: "/var/run/matrix-synapse.pid"
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['127.0.0.1']
    resources:
      - names: [client]
        compress: false
database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: matrix
    password: "$DB_PASSWORD"
    database: matrix
    host: localhost
    port: 5432
    cp_min: 5
    cp_max: 10
log_config: "/etc/matrix-synapse/log.yaml"
media_store_path: /var/lib/matrix-synapse/media
signing_key_path: "/etc/matrix-synapse/homeserver.signing.key"
trusted_key_servers:
  - server_name: "$MATRIX_DOMAIN"
suppress_key_server_warning: true
max_upload_size: 100M
enable_registration: false
registration_shared_secret: "$REGISTRATION_SHARED_SECRET"
search_all_users: true
prefer_local_users: true
turn_uris: ["turn:$MATRIX_DOMAIN?transport=udp","turn:$MATRIX_DOMAIN?transport=tcp"]
turn_shared_secret: "$TURN_SHARED_SECRET"
turn_user_lifetime: 86400000
admin_users:
  - "@$ADMIN_USER:$MATRIX_DOMAIN"
EOL

# Запуск Matrix Synapse
systemctl enable matrix-synapse
systemctl start matrix-synapse

# Установка и настройка Coturn
echo "Установка Coturn..."
apt install -y coturn

# Настройка Coturn
cat > /etc/turnserver.conf <<EOL
listening-port=3478
tls-listening-port=5349
listening-ip=$LOCAL_IP
relay-ip=$LOCAL_IP
external-ip=$PUBLIC_IP
min-port=49152
max-port=65535
verbose
fingerprint
lt-cred-mech
use-auth-secret
static-auth-secret=$TURN_SHARED_SECRET
realm=$MATRIX_DOMAIN
total-quota=100
bps-capacity=0
stale-nonce
no-multicast-peers
no-cli
EOL

sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
systemctl enable coturn
systemctl start coturn

# Установка Element Web
echo "Установка Element Web..."
mkdir -p /opt/element-web
cat > /opt/element-web/config.json <<EOL
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$MATRIX_DOMAIN",
            "server_name": "$MATRIX_DOMAIN"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "disable_custom_urls": true,
    "disable_guests": true,
    "disable_login_language_selector": true,
    "disable_3pid_login": true,
    "brand": "Element",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api",
        "https://scalar-staging.riot.im/scalar/api"
    ],
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "defaultCountryCode": "RU",
    "showLabsSettings": false,
    "features": {
        "feature_pinning": "labs",
        "feature_custom_status": "labs",
        "feature_custom_tags": "labs",
        "feature_state_counters": "labs"
    },
    "default_federate": false,
    "default_theme": "dark",
    "room_directory": {
        "servers": [
            "$MATRIX_DOMAIN"
        ]
    },
    "welcomeUserId": "@$ADMIN_USER:$MATRIX_DOMAIN",
    "piwik": false,
    "enable_presence_by_hs_url": {
        "https://matrix.org": false,
        "https://matrix-client.matrix.org": false
    }
}
EOL

docker run -d --name element-web --restart always -p 127.0.0.1:8080:80 -v /opt/element-web/config.json:/app/config.json vectorim/element-web:latest

# Установка Synapse Admin
echo "Установка Synapse Admin..."
mkdir -p /opt/synapse-admin
cd /opt/synapse-admin
git clone https://github.com/Awesome-Technologies/synapse-admin.git .
cat > docker-compose.yml <<EOL
version: '3'
services:
  synapse-admin:
    image: awesometechnologies/synapse-admin:latest
    container_name: synapse-admin
    restart: always
    ports:
      - "127.0.0.1:8081:80"
    environment:
      - REACT_APP_SERVER_URL=https://$MATRIX_DOMAIN
EOL

docker-compose up -d

# Остановка других веб-серверов на время запуска Caddy
echo "Останавливаем другие веб-серверы..."
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

# Установка и настройка Caddy
echo "Установка и настройка Caddy..."
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install -y caddy

# Создание Caddyfile - Caddy автоматически получит и обновит SSL сертификаты
echo "Создание Caddyfile..."
cat > /etc/caddy/Caddyfile <<EOL
# Matrix Synapse - Caddy автоматически получит SSL сертификат
$MATRIX_DOMAIN {
    reverse_proxy 127.0.0.1:8008 {
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote_host}
    }
}

# Element Web - Caddy автоматически получит SSL сертификат
$ELEMENT_DOMAIN {
    reverse_proxy 127.0.0.1:8080
}

# Synapse Admin - Caddy автоматически получит SSL сертификат
$ADMIN_DOMAIN {
    reverse_proxy 127.0.0.1:8081
}
EOL

# Запуск и включение Caddy
systemctl enable caddy
systemctl start caddy

# Проверка статуса сервисов
echo "Проверка статуса сервисов..."
systemctl status matrix-synapse --no-pager -l
systemctl status postgresql --no-pager -l
systemctl status coturn --no-pager -l
systemctl status caddy --no-pager -l

# Создание первого пользователя
echo "Создание первого пользователя..."
echo "Запустите следующую команду для создания первого пользователя:"
echo "register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008"

# Финальная информация
echo ""
echo "==============================================="
echo "Установка завершена!"
echo "==============================================="
echo "Matrix Synapse доступен по адресу: https://$MATRIX_DOMAIN"
echo "Element Web доступен по адресу: https://$ELEMENT_DOMAIN"
echo "Synapse Admin доступен по адресу: https://$ADMIN_DOMAIN"
echo "Первый администратор: @$ADMIN_USER:$MATRIX_DOMAIN"
echo ""
echo "ВАЖНО: Caddy автоматически получит SSL сертификаты Let's Encrypt"
echo "Подождите несколько минут после запуска для получения сертификатов"
echo ""
if [ "$SERVER_TYPE" = "proxmox" ]; then
echo "Для Proxmox VPS добавьте в Caddyfile хоста следующие строки:"
echo ""
echo "# Matrix Synapse"
echo "$MATRIX_DOMAIN {"
echo "    reverse_proxy $LOCAL_IP:8008 {"
echo "        header_up X-Forwarded-For {remote_host}"
echo "        header_up X-Real-IP {remote_host}"  
echo "    }"
echo "}"
echo ""
echo "# Element Web"
echo "$ELEMENT_DOMAIN {"
echo "    reverse_proxy $LOCAL_IP:8080"
echo "}"
echo ""
echo "# Synapse Admin"
echo "$ADMIN_DOMAIN {"
echo "    reverse_proxy $LOCAL_IP:8081"
echo "}"
echo ""
echo "Затем перезапустите Caddy на хосте: systemctl reload caddy"
fi
echo ""
echo "Registration Shared Secret: $REGISTRATION_SHARED_SECRET"
echo "Turn Shared Secret: $TURN_SHARED_SECRET"
echo "==============================================="