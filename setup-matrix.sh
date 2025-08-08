#!/bin/bash

# Matrix Setup & Repair Tool v6.0 - Enhanced Docker Edition
# Полностью переработанная версия с улучшенной конфигурацией

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться от root" >&2
  exit 1
fi

# Глобальные переменные для конфигурации
#SYNAPSE_VERSION="v1.119.0"
SYNAPSE_VERSION="latest"
ELEMENT_VERSION="v1.11.81"
SYNAPSE_ADMIN_VERSION="0.10.3"
REQUIRED_MIN_VERSION="1.93.0"
MATRIX_DOMAIN=""
ELEMENT_DOMAIN=""
ADMIN_DOMAIN=""
BIND_ADDRESS=""
DB_PASSWORD=$(openssl rand -hex 16)
REGISTRATION_SHARED_SECRET=$(openssl rand -hex 32)
TURN_SECRET=$(openssl rand -hex 32)
ADMIN_USER="admin"
SERVER_TYPE=""
PUBLIC_IP=""
LOCAL_IP=""

# Функция для проверки и исправления системного времени
fix_system_time() {
  echo "Проверка системного времени..."
  
  if ! timedatectl status | grep -q "NTP synchronized: yes"; then
    echo "Исправление системного времени..."
    apt update >/dev/null 2>&1
    apt install -y ntp ntpdate >/dev/null 2>&1
    systemctl stop ntp >/dev/null 2>&1
    ntpdate -s pool.ntp.org >/dev/null 2>&1 || ntpdate -s time.nist.gov >/dev/null 2>&1
    systemctl start ntp >/dev/null 2>&1
    systemctl enable ntp >/dev/null 2>&1
    timedatectl set-ntp true >/dev/null 2>&1
    echo "Системное время синхронизировано"
  else
    echo "Системное время уже синхронизировано"
  fi
}

# Функция для определения типа сервера
detect_server_type() {
  PUBLIC_IP=$(curl -s -4 https://ifconfig.co || curl -s -4 https://api.ipify.org || curl -s -4 https://ifconfig.me)
  LOCAL_IP=$(hostname -I | awk '{print $1}')
  if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
    SERVER_TYPE="proxmox"
    BIND_ADDRESS="0.0.0.0"
    echo "Обнаружена установка на Proxmox VPS (или за NAT)"
    echo "Публичный IP: $PUBLIC_IP"
    echo "Локальный IP: $LOCAL_IP"
    echo "Используется bind address: $BIND_ADDRESS"
  else
    SERVER_TYPE="hosting"
    BIND_ADDRESS="127.0.0.1"
    echo "Обнаружена установка на хостинг VPS"
    echo "IP адрес: $PUBLIC_IP"
    echo "Используется bind address: $BIND_ADDRESS"
  fi
}

# Функция для установки Docker
install_docker() {
  echo "Установка Docker и Docker Compose..."
  
  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    echo "Docker уже установлен и запущен: $(docker --version)"
    return 0
  fi
  
  echo "Устанавливаем Docker..."
  apt update
  apt install -y ca-certificates curl gnupg lsb-release
  
  # Официальный репозиторий Docker
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  
  # Запуск Docker
  systemctl enable docker
  systemctl start docker
  
  # Проверка установки
  if systemctl is-active --quiet docker; then
    echo "✅ Docker успешно установлен и запущен"
    echo "   Версия: $(docker --version)"
    echo "   Compose: $(docker compose version)"
    return 0
  else
    echo "❌ Ошибка: Docker не запущен"
    return 1
  fi
}

# Функция для создания улучшенной конфигурации Synapse
create_synapse_config() {
  local matrix_domain=$1
  local db_password=$2
  local registration_shared_secret=$3
  local turn_shared_secret=$4
  local admin_user=$5
  
  echo "Создание расширенной конфигурации Synapse..."
  
  # Создание основного конфига
  cat > /opt/synapse-data/homeserver.yaml <<EOL
# Matrix Synapse Configuration v6.0
# TLS завершается на Caddy reverse proxy, Synapse работает по HTTP

server_name: "$matrix_domain"
public_baseurl: "https://$matrix_domain"
pid_file: "/data/homeserver.pid"

# Настройки листенеров
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false
    # Healthcheck endpoint доступен на всех HTTP листенерах
    
  - port: 8448
    tls: false  
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [federation]
        compress: false

# Основные настройки
app_service_config_files: []
track_appservice_user_ips: true

# Секреты безопасности
macaroon_secret_key: "$(openssl rand -hex 32)"
form_secret: "$(openssl rand -hex 32)"
signing_key_path: "/data/signing.key"

# Well-known endpoints (отдаёт Caddy)
serve_server_wellknown: false

# TURN сервер для VoIP
turn_uris: 
  - "turn:$matrix_domain:3478?transport=udp"
  - "turn:$matrix_domain:3478?transport=tcp"
turn_shared_secret: "$turn_shared_secret"
turn_user_lifetime: "1h"
turn_allow_guests: true

# Медиа хранилище
media_store_path: "/data/media_store"
max_upload_size: "100M"
max_image_pixels: "32M"
dynamic_thumbnails: false
url_preview_enabled: false

# База данных PostgreSQL
database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: matrix
    password: "$db_password"
    database: matrix
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3

# Настройки безопасности паролей
password_config:
  enabled: true
  policy:
    minimum_length: 8
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# Регистрация и администрирование
enable_registration: false
registration_requires_token: true
registration_shared_secret: "$registration_shared_secret"

# Федерация отключена по умолчанию (безопасность)
federation_domain_whitelist: []
suppress_key_server_warning: true

# Администраторы
admin_users:
  - "@$admin_user:$matrix_domain"

# Настройки производительности
event_cache_size: "10K"
caches:
  global_factor: 0.5
  per_cache_factors:
    get_users_who_share_room_with_user: 2.0

# Присутствие пользователей
presence:
  enabled: true
  include_offline_users_on_sync: false

# Ограничения скорости
rc_message:
  per_second: 0.2
  burst_count: 10.0

rc_registration:
  per_second: 0.17
  burst_count: 3.0

rc_login:
  address:
    per_second: 0.003
    burst_count: 5.0
  account:
    per_second: 0.003
    burst_count: 5.0
  failed_attempts:
    per_second: 0.17
    burst_count: 3.0

# Настройки комнат
encryption_enabled_by_default_for_room_type: "invite"
enable_room_list_search: true

# Директория пользователей
user_directory:
  enabled: true
  search_all_users: false
  prefer_local_users: true

# Метрики (для мониторинга)
enable_metrics: false
report_stats: false

# Логирование
log_config: "/data/log_config.yaml"
EOL

  # Создание конфигурации логирования
  cat > /opt/synapse-data/log_config.yaml <<EOL
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    console:
        class: logging.StreamHandler
        formatter: precise
        stream: ext://sys.stdout

loggers:
    synapse.storage.SQL:
        level: INFO

root:
    level: INFO
    handlers: [console]

disable_existing_loggers: false
EOL

  echo "✅ Расширенная конфигурация Synapse создана"
}

# Функция для создания Docker Compose конфигурации
create_docker_compose() {
  local matrix_domain=$1
  local db_password=$2
  local bind_address=$3
  
  echo "Создание Docker Compose конфигурации..."
  
  mkdir -p /opt/synapse-config
  
  cat > /opt/synapse-config/docker-compose.yml <<EOL
version: '3.8'

services:
  # Matrix Synapse сервер
  synapse:
    image: matrixdotorg/synapse:$SYNAPSE_VERSION
    container_name: matrix-synapse
    restart: unless-stopped
    volumes:
      - /opt/synapse-data:/data
    environment:
      - SYNAPSE_SERVER_NAME=$matrix_domain
      - SYNAPSE_REPORT_STATS=no
      - UID=991
      - GID=991
    ports:
      - "$bind_address:8008:8008"
      - "$bind_address:8448:8448"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - matrix-network
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  # PostgreSQL база данных
  postgres:
    image: postgres:15-alpine
    container_name: matrix-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=matrix
      - POSTGRES_PASSWORD=$db_password
      - POSTGRES_DB=matrix
      - POSTGRES_INITDB_ARGS=--encoding=UTF8 --locale=C
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - matrix-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U matrix"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Element Web клиент
  element-web:
    image: vectorim/element-web:$ELEMENT_VERSION
    container_name: matrix-element-web
    restart: unless-stopped
    volumes:
      - /opt/element-web/config.json:/app/config.json:ro
    ports:
      - "$bind_address:8080:80"
    networks:
      - matrix-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Synapse Admin интерфейс
  synapse-admin:
    image: awesometechnologies/synapse-admin:$SYNAPSE_ADMIN_VERSION
    container_name: matrix-synapse-admin
    restart: unless-stopped
    volumes:
      - /opt/synapse-admin/config.json:/app/config.json:ro
    ports:
      - "$bind_address:8081:80"
    networks:
      - matrix-network
    environment:
      - REACT_APP_SERVER_URL=https://$matrix_domain
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Coturn TURN сервер
  coturn:
    image: coturn/coturn:latest
    container_name: matrix-coturn
    restart: unless-stopped
    ports:
      - "3478:3478/udp"
      - "3478:3478/tcp"
      - "49152-65535:49152-65535/udp"
    volumes:
      - /opt/coturn/turnserver.conf:/etc/turnserver.conf:ro
    networks:
      - matrix-network
    command: ["-c", "/etc/turnserver.conf"]

volumes:
  postgres-data:
    driver: local

networks:
  matrix-network:
    driver: bridge
EOL

  echo "✅ Docker Compose конфигурация создана"
}

# Функция для создания конфигурации Element Web
create_element_config() {
  local matrix_domain=$1
  local admin_user=$2
  
  echo "Создание конфигурации Element Web..."
  
  mkdir -p /opt/element-web
  
  cat > /opt/element-web/config.json <<EOL
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$matrix_domain",
            "server_name": "$matrix_domain"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "brand": "Element",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api"
    ],
    "hosting_signup_link": "https://element.io/matrix-services?utm_source=element-web&utm_medium=web",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "uisi_autorageshake_app": "element-auto-uisi",
    "showLabsSettings": true,
    "piwik": false,
    "roomDirectory": {
        "servers": ["$matrix_domain"]
    },
    "enable_presence_by_hs_url": {
        "https://matrix.org": false,
        "https://matrix-client.matrix.org": false
    },
    "terms_and_conditions_links": [
        {
            "text": "Privacy Policy",
            "url": "https://$matrix_domain/privacy"
        },
        {
            "text": "Terms of Service", 
            "url": "https://$matrix_domain/terms"
        }
    ],
    "welcomeUserId": "@$admin_user:$matrix_domain",
    "default_federate": false,
    "default_theme": "dark",
    "features": {
        "feature_new_room_decoration_ui": true,
        "feature_pinning": "labs",
        "feature_custom_status": "labs",
        "feature_custom_tags": "labs",
        "feature_state_counters": "labs",
        "feature_many_profile_picture_sizes": true,
        "feature_mjolnir": "labs",
        "feature_custom_themes": "labs",
        "feature_spaces": true,
        "feature_spaces.all_rooms": true,
        "feature_spaces.space_member_dms": true,
        "feature_voice_messages": true,
        "feature_location_share_live": true,
        "feature_polls": true,
        "feature_location_share": true,
        "feature_thread": true,
        "feature_latex_maths": true,
        "feature_element_call_video_rooms": "labs",
        "feature_group_calls": "labs",
        "feature_disable_call_per_sender_encryption": "labs",
        "feature_allow_screen_share_only_mode": "labs",
        "feature_location_share_pin_drop": "labs",
        "feature_video_rooms": "labs",
        "feature_element_call": "labs",
        "feature_new_device_manager": true,
        "feature_bulk_redaction": "labs",
        "feature_roomlist_preview_reactions_dms": true,
        "feature_roomlist_preview_reactions_all": true
    },
    "element_call": {
        "url": "https://call.element.io",
        "participant_limit": 8,
        "brand": "Element Call"
    },
    "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=fU3vlMsMn4Jb6dnEIFsx"
}
EOL

  echo "✅ Конфигурация Element Web создана"
}

# Функция для создания конфигурации Synapse Admin
create_synapse_admin_config() {
  local matrix_domain=$1
  
  echo "Создание конфигурации Synapse Admin..."
  
  mkdir -p /opt/synapse-admin
  
  cat > /opt/synapse-admin/config.json <<EOL
{
  "restrictBaseUrl": "https://$matrix_domain",
  "anotherRestrictedKey": "restricting",
  "locale": "en"
}
EOL

  echo "✅ Конфигурация Synapse Admin создана"
}

# Функция для создания конфигурации Coturn
create_coturn_config() {
  local matrix_domain=$1
  local turn_secret=$2
  local public_ip=$3
  local local_ip=$4
  
  echo "Создание конфигурации Coturn..."
  
  mkdir -p /opt/coturn
  
  cat > /opt/coturn/turnserver.conf <<EOL
# Coturn TURN Server Configuration
listening-port=3478
listening-ip=0.0.0.0
relay-ip=$local_ip
external-ip=$public_ip

# Диапазон портов для медиа релея
min-port=49152
max-port=65535

# Аутентификация
use-auth-secret
static-auth-secret=$turn_secret
realm=$matrix_domain

# Безопасность
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.0.2.0-192.0.2.255
denied-peer-ip=192.88.99.0-192.88.99.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=198.51.100.0-198.51.100.255
denied-peer-ip=203.0.113.0-203.0.113.255
denied-peer-ip=240.0.0.0-255.255.255.255

# Разрешаем локальную сеть для клиент->TURN->TURN->клиент
allowed-peer-ip=$local_ip

# Ограничения
no-multicast-peers
no-cli
no-loopback-peers
user-quota=12
total-quota=1200

# Логирование
verbose
log-file=/var/log/turnserver.log
EOL

  echo "✅ Конфигурация Coturn создана"
}

# Функция для создания расширенного Caddyfile
create_enhanced_caddyfile() {
  local matrix_domain=$1
  local element_domain=$2
  local admin_domain=$3
  local bind_address=$4
  
  echo "Создание расширенного Caddyfile..."
  
  cat > /etc/caddy/Caddyfile <<EOL
# Matrix Synapse Server
$matrix_domain {
    # Well-known endpoints для федерации и клиентов
    handle_path /.well-known/matrix/server {
        respond \`{"m.server": "$matrix_domain:8448"}\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }
    
    handle_path /.well-known/matrix/client {
        respond \`{
            "m.homeserver": {
                "base_url": "https://$matrix_domain"
            },
            "m.identity_server": {
                "base_url": "https://vector.im"
            },
            "org.matrix.msc3575.proxy": {
                "url": "https://$matrix_domain"
            }
        }\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }

    # Основные Matrix API endpoints
    reverse_proxy /_matrix/* $bind_address:8008 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    reverse_proxy /_synapse/client/* $bind_address:8008 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }

    # Безопасность заголовки
    header {
        # Security headers
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        
        # Remove server info
        -Server
    }
}

# Matrix Federation (отдельный порт)
$matrix_domain:8448 {
    reverse_proxy $bind_address:8448 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        -Server
    }
}

# Element Web Client
$element_domain {
    reverse_proxy $bind_address:8080 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    header {
        # Enhanced security для Element Web
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        
        # Content Security Policy для Element
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; media-src 'self' blob:; font-src 'self'; connect-src 'self' https: wss:; frame-src 'self' https:; worker-src 'self' blob:;"
        
        # Permissions Policy
        Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        
        # Кэширование статики
        Cache-Control "public, max-age=31536000" {
            path_regexp \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$
        }
        
        -Server
    }
}

# Synapse Admin Interface
$admin_domain {
    reverse_proxy $bind_address:8081 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        
        # Дополнительная защита для админки
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https:;"
        
        -Server
    }
}
EOL

  echo "✅ Расширенный Caddyfile создан"
}

# Функция для установки Caddy
install_caddy() {
  echo "Установка и настройка Caddy..."
  
  if [ "$SERVER_TYPE" != "hosting" ]; then
    echo "⚠️  Caddy устанавливается только для hosting VPS"
    echo "Для Proxmox настройте Caddy на хост-машине"
    return 0
  fi
  
  systemctl stop nginx >/dev/null 2>&1 || true
  systemctl stop apache2 >/dev/null 2>&1 || true

  apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt update
  apt install -y caddy

  create_enhanced_caddyfile "$MATRIX_DOMAIN" "$ELEMENT_DOMAIN" "$ADMIN_DOMAIN" "$BIND_ADDRESS"

  systemctl enable caddy
  systemctl start caddy
  
  if systemctl is-active --quiet caddy; then
    echo "✅ Caddy установлен и запущен"
  else
    echo "❌ Ошибка запуска Caddy"
  fi
}

# Функция для полной установки
full_installation() {
  echo "=== Matrix Setup & Repair Tool v6.0 - Enhanced Installation ==="
  echo ""
  
  # Исправление времени
  fix_system_time
  
  # Обновление системы
  echo "Обновление системы..."
  apt update && apt upgrade -y
  apt install -y curl wget openssl pwgen ufw fail2ban
  
  # Определение типа сервера
  detect_server_type
  
  # Установка Docker
  if ! install_docker; then
    echo "❌ Критическая ошибка: Docker не удалось установить"
    exit 1
  fi
  
  # Запрос доменов
  echo ""
  echo "=== Настройка доменов ==="
  read -p "Введите домен Matrix сервера (например, matrix.example.com): " MATRIX_DOMAIN
  read -p "Введите домен Element Web (например, element.example.com): " ELEMENT_DOMAIN  
  read -p "Введите домен Synapse Admin (например, admin.example.com): " ADMIN_DOMAIN
  read -p "Введите имя администратора (по умолчанию: admin): " input_admin
  ADMIN_USER=${input_admin:-admin}
  
  echo ""
  echo "=== Конфигурация ==="
  echo "Matrix Domain: $MATRIX_DOMAIN"
  echo "Element Domain: $ELEMENT_DOMAIN"
  echo "Admin Domain: $ADMIN_DOMAIN"
  echo "Admin User: $ADMIN_USER"
  echo "Server Type: $SERVER_TYPE"
  echo "Bind Address: $BIND_ADDRESS"
  echo ""
  
  read -p "Продолжить установку? (y/N): " confirm
  if [[ $confirm != [yY] ]]; then
    echo "Установка отменена"
    exit 0
  fi
  
  # Создание директорий
  echo "Создание директорий..."
  mkdir -p /opt/synapse-data
  mkdir -p /opt/synapse-config
  mkdir -p /opt/element-web
  mkdir -p /opt/synapse-admin
  mkdir -p /opt/coturn
  
  # Установка прав доступа
  chown -R 991:991 /opt/synapse-data
  
  # Создание конфигураций
  create_synapse_config "$MATRIX_DOMAIN" "$DB_PASSWORD" "$REGISTRATION_SHARED_SECRET" "$TURN_SECRET" "$ADMIN_USER"
  create_docker_compose "$MATRIX_DOMAIN" "$DB_PASSWORD" "$BIND_ADDRESS"
  create_element_config "$MATRIX_DOMAIN" "$ADMIN_USER"
  create_synapse_admin_config "$MATRIX_DOMAIN"
  create_coturn_config "$MATRIX_DOMAIN" "$TURN_SECRET" "$PUBLIC_IP" "$LOCAL_IP"
  
  # Запуск контейнеров
  echo "Запуск Matrix сервисов..."
  cd /opt/synapse-config
  docker compose pull
  docker compose up -d
  
  # Ожидание запуска сервисов
  echo "Ожидание запуска сервисов..."
  sleep 30
  
  # Проверка статуса
  echo "Проверка статуса контейнеров..."
  docker compose ps
  
  # Установка Caddy (только для hosting)
  install_caddy
  
  # Финальная информация
  echo ""
  echo "================================================================="
  echo "🎉 Установка Matrix v6.0 завершена успешно!"
  echo "================================================================="
  echo ""
  echo "📋 Информация о доступе:"
  echo "  Matrix Server: https://$MATRIX_DOMAIN"
  echo "  Element Web:   https://$ELEMENT_DOMAIN"
  echo "  Synapse Admin: https://$ADMIN_DOMAIN"
  echo ""
  echo "🔐 Данные для конфигурации:"
  echo "  Admin User: $ADMIN_USER"
  echo "  DB Password: $DB_PASSWORD"
  echo "  Registration Secret: $REGISTRATION_SHARED_SECRET"
  echo "  TURN Secret: $TURN_SECRET"
  echo ""
  echo "👤 Создание первого пользователя:"
  echo "  docker exec -it matrix-synapse register_new_matrix_user \\"
  echo "    -c /data/homeserver.yaml -u $ADMIN_USER --admin http://localhost:8008"
  echo ""
  echo "🔧 Управление сервисами:"
  echo "  cd /opt/synapse-config"
  echo "  docker compose ps          # Статус"
  echo "  docker compose logs        # Логи"
  echo "  docker compose restart     # Перезапуск"
  echo "  docker compose pull && docker compose up -d  # Обновление"
  echo ""
  if [ "$SERVER_TYPE" = "proxmox" ]; then
    echo "🌐 Для Proxmox VPS добавьте в Caddyfile хоста:"
    echo "   Порты: $LOCAL_IP:8008, $LOCAL_IP:8080, $LOCAL_IP:8081, $LOCAL_IP:8448"
  fi
  echo "================================================================="
}

# Функция создания администратора
create_admin_user() {
  echo "=== Создание администратора ==="
  
  if ! docker ps | grep -q "matrix-synapse"; then
    echo "❌ Matrix Synapse не запущен"
    return 1
  fi
  
  read -p "Введите имя пользователя: " username
  read -p "Сделать администратором? (Y/n): " make_admin
  
  admin_flag=""
  if [[ $make_admin != [nN] ]]; then
    admin_flag="--admin"
  fi
  
  echo "Создание пользователя..."
  docker exec -it matrix-synapse register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u "$username" \
    $admin_flag \
    http://localhost:8008
    
  if [ $? -eq 0 ]; then
    echo "✅ Пользователь @$username успешно создан"
  else
    echo "❌ Ошибка создания пользователя"
  fi
}

# Функция проверки статуса
check_status() {
  echo "=== Статус Matrix сервисов ==="
  echo ""
  
  if command -v docker >/dev/null 2>&1; then
    echo "🐳 Docker контейнеры:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=matrix"
    echo ""
    
    echo "📊 Использование ресурсов:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" --filter "name=matrix"
    echo ""
    
    echo "🏥 Healthcheck статус:"
    for container in matrix-synapse matrix-postgres matrix-element-web matrix-synapse-admin; do
      if docker ps | grep -q "$container"; then
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no healthcheck")
        echo "  $container: $health"
      fi
    done
  else
    echo "❌ Docker не установлен"
  fi
  
  echo ""
  echo "🌐 Сетевые порты:"
  netstat -tlnp | grep -E "(8008|8080|8081|8448|3478)" | head -10
}

# Функция перезапуска сервисов
restart_services() {
  echo "=== Перезапуск Matrix сервисов ==="
  
  if [ -f "/opt/synapse-config/docker-compose.yml" ]; then
    cd /opt/synapse-config
    echo "Перезапуск Docker контейнеров..."
    docker compose restart
    echo "✅ Сервисы перезапущены"
    
    echo "Ожидание готовности..."
    sleep 15
    check_status
  else
    echo "❌ Docker Compose конфигурация не найдена"
  fi
}

# Функция показа меню
show_menu() {
  clear
  echo "=================================================================="
  echo "              Matrix Setup & Repair Tool v6.0"
  echo "                    Enhanced Docker Edition"
  echo "=================================================================="
  echo "1.  🚀 Полная установка Matrix системы (Docker)"
  echo "2.  📊 Проверить статус сервисов"
  echo "3.  🔄 Перезапустить все сервисы"
  echo "4.  👤 Создать пользователя (админ)"
  echo "5.  🔧 Управление Docker контейнерами"
  echo "6.  📋 Показать логи сервисов"
  echo "7.  🔐 Показать секреты конфигурации"
  echo "8.  🆙 Обновить все контейнеры"
  echo "9.  ❌ Выход"
  echo "=================================================================="
}

# Функция управления Docker
manage_docker() {
  echo "=== Управление Docker контейнерами ==="
  echo ""
  echo "1. Статус контейнеров"
  echo "2. Остановить все"
  echo "3. Запустить все"
  echo "4. Перезапустить все"
  echo "5. Удалить все контейнеры"
  echo "6. Назад"
  echo ""
  read -p "Выберите действие (1-6): " docker_choice
  
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
  
  case $docker_choice in
    1) docker compose ps ;;
    2) docker compose stop ;;
    3) docker compose up -d ;;
    4) docker compose restart ;;
    5) 
      read -p "❗ Это удалит ВСЕ контейнеры Matrix! Продолжить? (y/N): " confirm
      if [[ $confirm == [yY] ]]; then
        docker compose down
        echo "✅ Контейнеры удалены"
      fi
      ;;
    6) return 0 ;;
    *) echo "Неверный выбор" ;;
  esac
  
  read -p "Нажмите Enter для продолжения..."
}

# Функция показа логов
show_logs() {
  echo "=== Логи Matrix сервисов ==="
  echo ""
  echo "1. Synapse"
  echo "2. PostgreSQL"
  echo "3. Element Web"
  echo "4. Synapse Admin"
  echo "5. Coturn"
  echo "6. Все сервисы"
  echo "7. Назад"
  echo ""
  read -p "Выберите сервис (1-7): " log_choice
  
  case $log_choice in
    1) docker logs -f matrix-synapse ;;
    2) docker logs -f matrix-postgres ;;
    3) docker logs -f matrix-element-web ;;
    4) docker logs -f matrix-synapse-admin ;;
    5) docker logs -f matrix-coturn ;;
    6) 
      cd /opt/synapse-config 2>/dev/null || return 1
      docker compose logs -f
      ;;
    7) return 0 ;;
    *) echo "Неверный выбор" ;;
  esac
}

# Функция показа секретов
show_secrets() {
  echo "=== Секреты конфигурации ==="
  echo ""
  
  if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
    echo "🔐 Из конфигурации Synapse:"
    echo "Registration Secret:"
    grep "registration_shared_secret:" /opt/synapse-data/homeserver.yaml | cut -d'"' -f2
    echo ""
    echo "TURN Secret:"
    grep "turn_shared_secret:" /opt/synapse-data/homeserver.yaml | cut -d'"' -f2
    echo ""
  fi
  
  if [ -f "/opt/synapse-config/docker-compose.yml" ]; then
    echo "💾 Database Password:"
    grep "POSTGRES_PASSWORD=" /opt/synapse-config/docker-compose.yml | cut -d'=' -f2
    echo ""
  fi
  
  echo "ℹ️  Эти данные нужны для ручной настройки клиентов"
  read -p "Нажмите Enter для продолжения..."
}

# Функция обновления контейнеров
update_containers() {
  echo "=== Обновление Matrix контейнеров ==="
  
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
  
  echo "Скачивание обновлений..."
  docker compose pull
  
  echo "Перезапуск с новыми образами..."
  docker compose up -d
  
  echo "Очистка старых образов..."
  docker image prune -f
  
  echo "✅ Обновление завершено"
  sleep 2
  check_status
}

# Основной цикл
while true; do
  show_menu
  read -p "Выберите опцию (1-9): " choice
  
  case $choice in
    1) full_installation ;;
    2) check_status; read -p "Нажмите Enter для продолжения..." ;;
    3) restart_services; read -p "Нажмите Enter для продолжения..." ;;
    4) create_admin_user; read -p "Нажмите Enter для продолжения..." ;;
    5) manage_docker ;;
    6) show_logs ;;
    7) show_secrets ;;
    8) update_containers; read -p "Нажмите Enter для продолжения..." ;;
    9) echo "👋 До свидания!"; exit 0 ;;
    *) echo "❌ Неверный выбор. Попробуйте снова."; sleep 2 ;;
  esac
done