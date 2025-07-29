#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться от root" >&2
  exit 1
fi

# Функция для определения типа сервера
detect_server_type() {
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
}

# Функция для проверки статуса Matrix Synapse
check_matrix_binding() {
  if [ -f "/etc/matrix-synapse/homeserver.yaml" ]; then
    CURRENT_BINDING=$(grep -A5 "listeners:" /etc/matrix-synapse/homeserver.yaml | grep "bind_addresses" | grep -o "127.0.0.1\|0.0.0.0" | head -1)
    echo "Matrix Synapse текущий bind: $CURRENT_BINDING"
    return 0
  else
    echo "Matrix Synapse не установлен"
    return 1
  fi
}

# Функция для проверки статуса Coturn
check_coturn_binding() {
  if [ -f "/etc/turnserver.conf" ]; then
    CURRENT_LISTENING=$(grep "listening-ip=" /etc/turnserver.conf | cut -d'=' -f2)
    echo "Coturn текущий listening-ip: $CURRENT_LISTENING"
    return 0
  else
    echo "Coturn не установлен"
    return 1
  fi
}

# Функция для проверки статуса Docker контейнеров
check_docker_binding() {
  ELEMENT_BINDING=""
  ADMIN_BINDING=""
  
  if docker ps | grep -q "element-web"; then
    ELEMENT_BINDING=$(docker port element-web 80 | cut -d':' -f1)
    echo "Element Web текущий bind: $ELEMENT_BINDING"
  else
    echo "Element Web не запущен"
  fi
  
  if docker ps | grep -q "synapse-admin"; then
    ADMIN_BINDING=$(docker port synapse-admin 80 | cut -d':' -f1)
    echo "Synapse Admin текущий bind: $ADMIN_BINDING"
  else
    echo "Synapse Admin не запущен"
  fi
}

# Функция для исправления Matrix Synapse binding
fix_matrix_binding() {
  local target_binding=$1
  echo "Исправляем Matrix Synapse binding на $target_binding..."
  
  sed -i "s/bind_addresses: \['127.0.0.1'\]/bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  sed -i "s/bind_addresses: \['0.0.0.0'\]/bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  
  systemctl restart matrix-synapse
  echo "Matrix Synapse перезапущен с binding $target_binding"
}

# Функция для исправления Coturn binding
fix_coturn_binding() {
  local target_ip=$1
  echo "Исправляем Coturn binding на $target_ip..."
  
  sed -i "s/listening-ip=.*/listening-ip=$target_ip/" /etc/turnserver.conf
  
  systemctl restart coturn
  echo "Coturn перезапущен с listening-ip $target_ip"
}

# Функция для исправления Docker контейнеров binding
fix_docker_binding() {
  local target_binding=$1
  echo "Исправляем Docker контейнеры binding на $target_binding..."
  
  # Останавливаем и удаляем существующие контейнеры
  docker stop element-web synapse-admin 2>/dev/null || true
  docker rm element-web synapse-admin 2>/dev/null || true
  
  # Перезапускаем Element Web с новым binding
  if [ -f "/opt/element-web/config.json" ]; then
    docker run -d --name element-web --restart always -p $target_binding:8080:80 -v /opt/element-web/config.json:/app/config.json vectorim/element-web:latest
    echo "Element Web перезапущен с binding $target_binding:8080"
  fi
  
  # Перезапускаем Synapse Admin с новым binding
  if [ -f "/opt/synapse-admin/docker-compose.yml" ]; then
    cd /opt/synapse-admin
    sed -i "s/127.0.0.1:8081:80/$target_binding:8081:80/" docker-compose.yml
    sed -i "s/0.0.0.0:8081:80/$target_binding:8081:80/" docker-compose.yml
    docker-compose up -d
    echo "Synapse Admin перезапущен с binding $target_binding:8081"
  fi
}

# Функция для автоматического исправления всех сервисов
fix_all_services() {
  local target_binding=$1
  local target_ip=$2
  
  echo "Начинаем исправление всех сервисов для режима: $SERVER_TYPE"
  echo "Target binding: $target_binding, Target IP: $target_ip"
  echo ""
  
  # Проверяем и исправляем Matrix Synapse
  if check_matrix_binding; then
    if [[ "$CURRENT_BINDING" != "$target_binding" ]]; then
      fix_matrix_binding $target_binding
    else
      echo "Matrix Synapse уже настроен правильно ($target_binding)"
    fi
  fi
  echo ""
  
  # Проверяем и исправляем Coturn
  if check_coturn_binding; then
    if [[ "$CURRENT_LISTENING" != "$target_ip" ]]; then
      fix_coturn_binding $target_ip
    else
      echo "Coturn уже настроен правильно ($target_ip)"
    fi
  fi
  echo ""
  
  # Проверяем и исправляем Docker контейнеры
  check_docker_binding
  if [[ "$ELEMENT_BINDING" != "$target_binding" ]] || [[ "$ADMIN_BINDING" != "$target_binding" ]]; then
    fix_docker_binding $target_binding
  else
    echo "Docker контейнеры уже настроены правильно ($target_binding)"
  fi
  echo ""
  
  echo "Исправление завершено!"
  echo "Проверяем статус сервисов..."
  systemctl status matrix-synapse --no-pager -l | head -5
  systemctl status coturn --no-pager -l | head -5
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# Функция для полной установки
full_installation() {
  # Определение типа сервера
  detect_server_type
  
  # Установка правильных binding адресов в зависимости от типа сервера
  if [ "$SERVER_TYPE" = "proxmox" ]; then
    BIND_ADDRESS="0.0.0.0"
    LISTEN_IP=$LOCAL_IP
  else
    BIND_ADDRESS="127.0.0.1"
    LISTEN_IP="127.0.0.1"
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

  # Установка зависимостей
  echo "Установка зависимостей..."
  apt install -y net-tools python3-dev libpq-dev mc aptitude htop apache2-utils lsb-release wget apt-transport-https postgresql docker.io docker-compose git python3-psycopg2

  # Установка и настройка PostgreSQL
  echo "Настройка PostgreSQL..."
  sudo -u postgres createuser matrix 2>/dev/null || true
  sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=matrix matrix 2>/dev/null || true
  sudo -u postgres psql -c "ALTER USER matrix WITH PASSWORD '$DB_PASSWORD';"

  # Настройка PostgreSQL для работы только с localhost
  PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d'.' -f1)
  sed -i "s/^#listen_addresses =.*/listen_addresses = 'localhost'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
  systemctl restart postgresql

  # Установка Matrix Synapse
  echo "Установка Matrix Synapse..."
  wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg 2>/dev/null || true
  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list
  apt update
  apt install -y matrix-synapse-py3

  # Настройка homeserver.yaml с правильным binding
  echo "Настройка Matrix Synapse..."
  cat > /etc/matrix-synapse/homeserver.yaml <<EOL
server_name: "$MATRIX_DOMAIN"
pid_file: "/var/run/matrix-synapse.pid"
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['$BIND_ADDRESS']
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

  systemctl enable matrix-synapse
  systemctl start matrix-synapse

  # Установка и настройка Coturn с правильным IP
  echo "Установка Coturn..."
  apt install -y coturn

  cat > /etc/turnserver.conf <<EOL
listening-port=3478
tls-listening-port=5349
listening-ip=$LISTEN_IP
relay-ip=$LISTEN_IP
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

  # Установка Element Web с правильным binding
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

  docker run -d --name element-web --restart always -p $BIND_ADDRESS:8080:80 -v /opt/element-web/config.json:/app/config.json vectorim/element-web:latest

  # Установка Synapse Admin с правильным binding
  echo "Установка Synapse Admin..."
  mkdir -p /opt/synapse-admin
  cd /opt/synapse-admin

  cat > config.json <<EOL
{
  "restrictBaseUrl": "https://$MATRIX_DOMAIN"
}
EOL

  git clone https://github.com/Awesome-Technologies/synapse-admin.git . 2>/dev/null || true
  cat > docker-compose.yml <<EOL
version: '3'
services:
  synapse-admin:
    image: awesometechnologies/synapse-admin:latest
    container_name: synapse-admin
    restart: always
    ports:
      - "$BIND_ADDRESS:8081:80"
    volumes:
      - ./config.json:/app/config.json:ro
    environment:
      - REACT_APP_SERVER_URL=https://$MATRIX_DOMAIN
EOL

  docker-compose up -d

  # Установка Caddy только для хостинга
  if [ "$SERVER_TYPE" = "hosting" ]; then
    echo "Установка и настройка Caddy..."
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true

    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update
    apt install -y caddy

    cat > /etc/caddy/Caddyfile <<EOL
$MATRIX_DOMAIN {
    reverse_proxy 127.0.0.1:8008 {
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote_host}
    }
}

$ELEMENT_DOMAIN {
    reverse_proxy 127.0.0.1:8080
}

$ADMIN_DOMAIN {
    reverse_proxy 127.0.0.1:8081
}
EOL

    systemctl enable caddy
    systemctl start caddy
  fi

  # Вывод финальной информации
  echo ""
  echo "==============================================="
  echo "Установка завершена!"
  echo "==============================================="
  echo "Matrix Synapse доступен по адресу: https://$MATRIX_DOMAIN"
  echo "Element Web доступен по адресу: https://$ELEMENT_DOMAIN"
  echo "Synapse Admin доступен по адресу: https://$ADMIN_DOMAIN"
  echo "Первый администратор: @$ADMIN_USER:$MATRIX_DOMAIN"
  echo ""
  echo "Binding адреса: $BIND_ADDRESS (правильно для $SERVER_TYPE)"
  echo ""

  if [ "$SERVER_TYPE" = "hosting" ]; then
    echo "ВАЖНО: Caddy автоматически получит SSL сертификаты Let's Encrypt"
    echo "Подождите несколько минут после запуска для получения сертификатов"
  elif [ "$SERVER_TYPE" = "proxmox" ]; then
    echo "ДЛЯ PROXMOX VPS: Добавьте следующие строки в Caddyfile хоста:"
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
  echo "Создайте первого пользователя командой:"
  echo "register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008"
  echo ""
  echo "Registration Shared Secret: $REGISTRATION_SHARED_SECRET"
  echo "Turn Shared Secret: $TURN_SHARED_SECRET"
  echo "==============================================="
}

# Главное меню
show_menu() {
  echo "========================================"
  echo "    Matrix Setup & Repair Tool"
  echo "========================================"
  echo "1. Полная установка Matrix системы"
  echo "2. Исправить binding для Proxmox VPS"
  echo "3. Исправить binding для Hosting VPS"
  echo "4. Проверить текущие настройки"
  echo "5. Выход"
  echo "========================================"
}

# Основной цикл
while true; do
  show_menu
  read -p "Выберите опцию (1-5): " choice
  
  case $choice in
    1)
      echo "Запуск полной установки..."
      full_installation
      break
      ;;
    2)
      echo "Исправление для Proxmox VPS (binding: 0.0.0.0)..."
      detect_server_type
      fix_all_services "0.0.0.0" "$LOCAL_IP"
      break
      ;;
    3)
      echo "Исправление для Hosting VPS (binding: 127.0.0.1)..."
      detect_server_type
      fix_all_services "127.0.0.1" "127.0.0.1"
      break
      ;;
    4)
      echo "Проверка текущих настроек..."
      detect_server_type
      echo ""
      check_matrix_binding
      check_coturn_binding
      check_docker_binding
      echo ""
      read -p "Нажмите Enter для продолжения..."
      ;;
    5)
      echo "Выход..."
      exit 0
      ;;
    *)
      echo "Неверный выбор. Попробуйте снова."
      sleep 2
      ;;
  esac
done