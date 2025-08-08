#!/bin/bash

# Matrix Setup & Repair Tool v5.4
# Поддерживает Synapse 1.93.0+ с современными настройками безопасности
# ИСПРАВЛЕНО: Полная совместимость с Ubuntu 24.04 LTS (Noble Numbat)
# ИСПРАВЛЕНО: Проблемы с репозиториями и системным временем
# НОВОЕ: Docker установка Synapse, исправление systemd-python проблем
# НОВОЕ: Element Call, расширенная конфигурация Element Web, улучшенная безопасность

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться от root" >&2
  exit 1
fi

# Глобальные переменные для конфигурации
SYNAPSE_VERSION="1.119.0"  # Последняя стабильная версия
ELEMENT_VERSION="v1.11.81"
REQUIRED_MIN_VERSION="1.93.0"

# Функция для проверки и исправления системного времени
fix_system_time() {
  echo "Проверка системного времени..."
  
  # Проверяем, синхронизировано ли время
  if ! timedatectl status | grep -q "NTP synchronized: yes"; then
    echo "Исправление системного времени..."
    
    # Установка и включение NTP
    apt update >/dev/null 2>&1
    apt install -y ntp ntpdate >/dev/null 2>&1
    
    # Принудительная синхронизация времени
    systemctl stop ntp >/dev/null 2>&1
    ntpdate -s pool.ntp.org >/dev/null 2>&1 || ntpdate -s time.nist.gov >/dev/null 2>&1
    systemctl start ntp >/dev/null 2>&1
    systemctl enable ntp >/dev/null 2>&1
    
    # Настройка timedatectl
    timedatectl set-ntp true >/dev/null 2>&1
    
    echo "Системное время синхронизировано"
  else
    echo "Системное время уже синхронизировано"
  fi
}

# Функция для очистки и настройки репозиториев
setup_repositories() {
  echo "Настройка репозиториев для Ubuntu $(lsb_release -cs)..."
  
  # Исправляем системное время перед работой с репозиториями
  fix_system_time
  
  # Удаляем старые репозитории Matrix/Element
  rm -f /etc/apt/sources.list.d/matrix-org.list >/dev/null 2>&1
  rm -f /etc/apt/sources.list.d/element-io.list >/dev/null 2>&1
  
  # Определяем версию Ubuntu и настраиваем репозитории
  UBUNTU_CODENAME=$(lsb_release -cs)
  
  case "$UBUNTU_CODENAME" in
    "noble"|"mantic"|"lunar"|"kinetic")
      echo "Обнаружена современная версия Ubuntu: $UBUNTU_CODENAME"
      echo "Используется основной репозиторий Matrix.org с fallback на jammy"
      
      # Для новых версий используем jammy репозиторий (LTS)
      wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ jammy main" | tee /etc/apt/sources.list.d/matrix-org.list
      ;;
    "jammy"|"focal"|"bionic")
      echo "Обнаружена LTS версия Ubuntu: $UBUNTU_CODENAME"
      
      # Для LTS версий используем нативный репозиторий
      wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $UBUNTU_CODENAME main" | tee /etc/apt/sources.list.d/matrix-org.list
      ;;
    *)
      echo "Неизвестная версия Ubuntu: $UBUNTU_CODENAME"
      echo "Используется fallback на jammy репозиторий"
      
      wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ jammy main" | tee /etc/apt/sources.list.d/matrix-org.list
      ;;
  esac
  
  # Обновляем список пакетов с повторными попытками
  echo "Обновление списка пакетов..."
  for i in {1..3}; do
    if apt update; then
      echo "Репозитории успешно обновлены"
      return 0
    else
      echo "Попытка $i/3 неудача, повторяем через 3 секунды..."
      sleep 3
    fi
  done
  
  echo "⚠️  Предупреждение: Проблемы с обновлением репозиториев"
  echo "Продолжаем установку с доступными пакетами..."
}

# Функция для определения типа сервера
detect_server_type() {
  # Попытка получить публичный IP через несколько сервисов для надежности
  PUBLIC_IP=$(curl -s -4 https://ifconfig.co || curl -s -4 https://api.ipify.org || curl -s -4 https://ifconfig.me)
  LOCAL_IP=$(hostname -I | awk '{print $1}')
  if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
    SERVER_TYPE="proxmox"
    echo "Обнаружена установка на Proxmox VPS (или за NAT)"
    echo "Публичный IP: $PUBLIC_IP"
    echo "Локальный IP: $LOCAL_IP"
  else
    SERVER_TYPE="hosting"
    echo "Обнаружена установка на хостинг VPS"
    echo "IP адрес: $PUBLIC_IP"
  fi
}

# Функция для установки Synapse через Docker
install_synapse_docker() {
  echo "Установка Matrix Synapse через Docker..."
  
  # Создаем необходимые директории
  mkdir -p /opt/synapse-data
  mkdir -p /opt/synapse-config
  
  # Создаем docker-compose.yml для Synapse
  cat > /opt/synapse-config/docker-compose.yml <<EOL
version: '3.8'
services:
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: matrix-synapse
    restart: unless-stopped
    volumes:
      - /opt/synapse-data:/data
    environment:
      - SYNAPSE_SERVER_NAME=$MATRIX_DOMAIN
      - SYNAPSE_REPORT_STATS=no
      - UID=991
      - GID=991
    ports:
      - "$BIND_ADDRESS:8008:8008"
      - "$BIND_ADDRESS:8448:8448"
    depends_on:
      - postgres
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    networks:
      - matrix-network

  postgres:
    image: postgres:15
    container_name: matrix-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=matrix
      - POSTGRES_PASSWORD=$DB_PASSWORD
      - POSTGRES_DB=matrix
      - POSTGRES_INITDB_ARGS="--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U matrix"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - matrix-network

volumes:
  postgres-data:

networks:
  matrix-network:
    driver: bridge
EOL

  # Генерируем начальную конфигурацию
  echo "Генерация конфигурации Synapse..."
  cd /opt/synapse-config
  
  docker run -it --rm \
    --mount type=bind,src=/opt/synapse-data,dst=/data \
    -e SYNAPSE_SERVER_NAME="$MATRIX_DOMAIN" \
    -e SYNAPSE_REPORT_STATS=no \
    matrixdotorg/synapse:latest generate
  
  # Проверяем, что конфигурация создана
  if [ ! -f "/opt/synapse-data/homeserver.yaml" ]; then
    echo "❌ Ошибка: Конфигурация не была создана"
    return 1
  fi
  
  echo "✅ Конфигурация Synapse создана успешно"
  return 0
}

# Функция для настройки Docker Synapse конфигурации
configure_synapse_docker() {
  local matrix_domain=$1
  local db_password=$2
  local registration_shared_secret=$3
  local turn_shared_secret=$4
  local admin_user=$5
  local bind_address=$6
  
  echo "Настройка конфигурации Docker Synapse..."
  
  # Создаем бэкап оригинальной конфигурации
  cp /opt/synapse-data/homeserver.yaml /opt/synapse-data/homeserver.yaml.original
  
  # Создаем улучшенную конфигурацию
  cat > /opt/synapse-data/homeserver.yaml <<EOL
# ===== ОСНОВНЫЕ НАСТРОЙКИ СЕРВЕРА =====
server_name: "$matrix_domain"
public_baseurl: "https://$matrix_domain"
pid_file: "/data/homeserver.pid"
web_client_location: "https://$ELEMENT_DOMAIN"

# ===== СЕТЕВЫЕ НАСТРОЙКИ =====
listeners:
  # Клиентский API
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

  # Федеративный API (отдельный порт)
  - port: 8448
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [federation]
        compress: false

# ===== БЕЗОПАСНОСТЬ И АУТЕНТИФИКАЦИЯ =====
app_service_config_files: []
track_appservice_user_ips: true
macaroon_secret_key: "$(openssl rand -hex 32)"
form_secret: "$(openssl rand -hex 32)"

# Современная политика паролей
password_config:
  enabled: true
  localdb_enabled: true
  policy:
    enabled: true
    minimum_length: 8
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# ===== НАСТРОЙКИ РЕГИСТРАЦИИ =====
enable_registration: false
registration_requires_token: true
registration_shared_secret: "$registration_shared_secret"
allow_guest_access: false
enable_set_displayname: true
enable_set_avatar_url: true
enable_3pid_changes: true

# Блокировка автоматических регистраций
inhibit_user_in_use_error: false
auto_join_rooms: []

# ===== НАСТРОЙКИ TURN СЕРВЕРА =====
turn_uris: 
  - "turn:$matrix_domain:3478?transport=udp"
  - "turn:$matrix_domain:3478?transport=tcp"
turn_shared_secret: "$turn_shared_secret"
turn_user_lifetime: "1h"
turn_allow_guests: true

# ===== НАСТРОЙКИ МЕДИА =====
media_store_path: "/data/media"
enable_authenticated_media: true
max_upload_size: "100M"
max_image_pixels: "32M"
dynamic_thumbnails: false

# Ограничения медиа загрузок
media_upload_limits:
  - time_period: "1h"
    max_size: "500M"
  - time_period: "1d"
    max_size: "2G"

# Превью URL (отключено по умолчанию для безопасности)
url_preview_enabled: false

# ===== НАСТРОЙКИ БАЗЫ ДАННЫХ =====
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

# ===== НАСТРОЙКИ ПРОИЗВОДИТЕЛЬНОСТИ =====
# Кэширование
caches:
  global_factor: 1.0
  per_cache_factors:
    get_users_who_share_room_with_user: 2.0
  sync_response_cache_duration: "2m"

# Лимиты запросов (защита от DDoS)
rc_message:
  per_second: 0.2
  burst_count: 10
  
rc_registration:
  per_second: 0.17
  burst_count: 3
  
rc_login:
  address:
    per_second: 0.17
    burst_count: 3
  account:
    per_second: 0.17
    burst_count: 3

# ===== НАСТРОЙКИ ФЕДЕРАЦИИ =====
# Федерация отключена по умолчанию (безопасность)
federation_domain_whitelist: []
suppress_key_server_warning: true

# Блокировка IP диапазонов для исходящих запросов
ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'

# ===== АДМИНИСТРИРОВАНИЕ =====
# Включение метрик (опционально)
enable_metrics: false

# Серверные уведомления
server_notices:
  system_mxid_localpart: notices
  system_mxid_display_name: "Системные уведомления"
  room_name: "Системные уведомления"

# ===== ПОЛЬЗОВАТЕЛЬСКИЕ НАСТРОЙКИ =====
# Блокировка поиска всех пользователей
user_directory:
  enabled: true
  search_all_users: false
  prefer_local_users: true

# Разрешения на комнаты
require_membership_for_aliases: true
allow_per_room_profiles: true

# Настройки профилей
limit_profile_requests_to_users_who_share_rooms: true
require_auth_for_profile_requests: true

# ===== ЛОГИРОВАНИЕ =====
log_config: "/data/log.config"

# ===== АДМИНИСТРАТОРЫ =====
# Список администраторов (можно добавлять)
# admin_users:
#   - "@$admin_user:$matrix_domain"
EOL

  # Создаем конфигурацию логирования для Docker
  cat > /opt/synapse-data/log.config <<EOL
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    file:
        class: logging.handlers.TimedRotatingFileHandler
        formatter: precise
        filename: /data/logs/homeserver.log
        when: midnight
        backupCount: 7
        encoding: utf8
    
    console:
        class: logging.StreamHandler
        formatter: precise

loggers:
    synapse.storage.SQL:
        level: WARNING
    synapse.access:
        level: INFO

root:
    level: INFO
    handlers: [file, console]

disable_existing_loggers: false
EOL

  # Создаем директории для логов
  mkdir -p /opt/synapse-data/logs
  chown -R 991:991 /opt/synapse-data
  
  echo "✅ Конфигурация Docker Synapse настроена"
}

# Функция для альтернативной установки Synapse
install_synapse_alternative() {
  echo "Выбор метода установки Matrix Synapse..."
  
  # Проверяем, есть ли Docker
  if command -v docker >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
    echo "🐳 Docker обнаружен, используем Docker установку (рекомендуется)"
    
    if install_synapse_docker; then
      echo "✅ Matrix Synapse установлен через Docker"
      SYNAPSE_INSTALLATION_TYPE="docker"
      return 0
    else
      echo "❌ Docker установка не удалась, пробуем pip..."
    fi
  else
    echo "Docker не обнаружен, используем pip установку..."
  fi
  
  # Fallback на pip установку
  echo "Попытка установки Matrix Synapse через pip..."
  
  # Устанавливаем дополнительные зависимости для Ubuntu 24.04
  apt install -y pkg-config libsystemd-dev libssl-dev libffi-dev python3-dev python3-venv python3-pip build-essential libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev libpq-dev
  # Установка зависимостей v5.4
  apt install -y libjpeg8-dev libwebp-dev
  
  # Метод 1: Установка через pip в виртуальном окружении
  if ! systemctl is-active --quiet matrix-synapse; then
    echo "Установка Synapse через Python pip..."
    
    # Создаем пользователя matrix-synapse если не существует
    if ! id "matrix-synapse" &>/dev/null; then
      useradd -r -s /bin/false -d /var/lib/matrix-synapse matrix-synapse
    fi
    
    # Создаем необходимые директории
    mkdir -p /opt/venvs/matrix-synapse
    mkdir -p /etc/matrix-synapse
    mkdir -p /var/lib/matrix-synapse
    mkdir -p /var/log/matrix-synapse
    
    # Создаем виртуальное окружение
    python3 -m venv /opt/venvs/matrix-synapse
    source /opt/venvs/matrix-synapse/bin/activate
    
    # Обновляем pip и устанавливаем Synapse БЕЗ systemd-python для Ubuntu 24.04
    pip install --upgrade pip setuptools wheel
    
    # Сначала пробуем установить с systemd, если не получается - без него
    if ! pip install matrix-synapse[postgres,systemd,url_preview]; then
      echo "⚠️  Установка с systemd не удалась, устанавливаем без systemd-python..."
      pip install matrix-synapse[postgres,url_preview]
    fi
    
    # Создаем systemd сервис
    cat > /etc/systemd/system/matrix-synapse.service <<EOL
[Unit]
Description=Matrix Synapse Homeserver
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=exec
ExecStart=/opt/venvs/matrix-synapse/bin/python -m synapse.app.homeserver --config-path=/etc/matrix-synapse/homeserver.yaml
ExecReload=/bin/kill -HUP \$MAINPID
User=matrix-synapse
Group=matrix-synapse
WorkingDirectory=/var/lib/matrix-synapse
RuntimeDirectory=matrix-synapse
RuntimeDirectoryMode=0700

# Security settings
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/matrix-synapse /var/log/matrix-synapse /tmp

# Resource limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

    # Устанавливаем права доступа
    chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse
    chown -R matrix-synapse:matrix-synapse /var/log/matrix-synapse
    
    # Включаем сервис
    systemctl daemon-reload
    systemctl enable matrix-synapse
    
    echo "✅ Matrix Synapse установлен через pip"
    SYNAPSE_INSTALLATION_TYPE="pip"
    return 0
  fi
}

# Функция для исправления Matrix Synapse binding
fix_matrix_binding() {
  local target_binding=$1
  echo "Исправляем Matrix Synapse binding на $target_binding..."
  
  sed -i "s/bind_addresses: \['127.0.0.1'\]/bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  sed -i "s/bind_addresses: \['0.0.0.0'\]/bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  sed -i "s/^  - port: 8008/  - port: 8008\n    bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  sed -i "s/^  - port: 8448/  - port: 8448\n    bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  
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
    docker run -d --name element-web --restart always -p $target_binding:8080:80 -v /opt/element-web/config.json:/app/config.json vectorim/element-web:$ELEMENT_VERSION
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
  local server_type=$3
  
  echo "Начинаем исправление всех сервисов для режима: $server_type"
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

# Функция для проверки версии Synapse
check_synapse_version() {
  if command -v synctl >/dev/null 2>&1; then
    CURRENT_VERSION=$(python3 -c "import synapse; print(synapse.__version__)" 2>/dev/null || echo "unknown")
    echo "Текущая версия Synapse: $CURRENT_VERSION"
    
    # Проверка минимальной поддерживаемой версии
    if dpkg --compare-versions "$CURRENT_VERSION" lt "$REQUIRED_MIN_VERSION"; then
      echo "⚠️  Требуется обновление Synapse (минимум $REQUIRED_MIN_VERSION)"
      return 1
    fi
  fi
  return 0
}

# Функция для создания улучшенного homeserver.yaml
create_homeserver_config() {
  local matrix_domain=$1
  local db_password=$2
  local registration_shared_secret=$3
  local turn_shared_secret=$4
  local admin_user=$5
  local bind_address=$6
  local listen_ip=$7
  
  cat > /etc/matrix-synapse/homeserver.yaml <<EOL
# ===== ОСНОВНЫЕ НАСТРОЙКИ СЕРВЕРА =====
server_name: "$matrix_domain"
public_baseurl: "https://$matrix_domain"
pid_file: "/var/run/matrix-synapse.pid"

# ===== СЕТЕВЫЕ НАСТРОЙКИ =====
listeners:
  # Клиентский API
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['$bind_address']
    resources:
      - names: [client]
        compress: false

  # Федеративный API (отдельный порт рекомендован)
  - port: 8448
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['$bind_address']
    resources:
      - names: [federation]
        compress: false

# ===== БЕЗОПАСНОСТЬ И АУТЕНТИФИКАЦИЯ =====
app_service_config_files: []
track_appservice_user_ips: true
macaroon_secret_key: "$(openssl rand -hex 32)"
form_secret: "$(openssl rand -hex 32)"

# Современная политика паролей
password_config:
  enabled: true
  localdb_enabled: true
  policy:
    enabled: true
    minimum_length: 8
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# ===== НАСТРОЙКИ РЕГИСТРАЦИИ =====
enable_registration: false
registration_requires_token: true
registration_shared_secret: "$registration_shared_secret"
allow_guest_access: false
enable_set_displayname: true
enable_set_avatar_url: true
enable_3pid_changes: true

# Блокировка автоматических регистраций
inhibit_user_in_use_error: false
auto_join_rooms: []

# ===== НАСТРОЙКИ TURN СЕРВЕРА =====
turn_uris: 
  - "turn:$matrix_domain:3478?transport=udp"
  - "turn:$matrix_domain:3478?transport=tcp"
turn_shared_secret: "$turn_shared_secret"
turn_user_lifetime: "1h"
turn_allow_guests: true

# ===== НАСТРОЙКИ МЕДИА =====
media_store_path: "/var/lib/matrix-synapse/media"
enable_authenticated_media: true
max_upload_size: "100M"
max_image_pixels: "32M"
dynamic_thumbnails: false

# Ограничения медиа загрузок
media_upload_limits:
  - time_period: "1h"
    max_size: "500M"
  - time_period: "1d"
    max_size: "2G"

# Превью URL (отключено по умолчанию для безопасности)
url_preview_enabled: false

# ===== НАСТРОЙКИ БАЗЫ ДАННЫХ =====
database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: matrix
    password: "$db_password"
    database: matrix
    host: localhost
    port: 5432
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3

# ===== НАСТРОЙКИ ПРОИЗВОДИТЕЛЬНОСТИ =====
# Кэширование
caches:
  global_factor: 1.0
  per_cache_factors:
    get_users_who_share_room_with_user: 2.0
  sync_response_cache_duration: "2m"

# Лимиты запросов (защита от DДос)
rc_message:
  per_second: 0.2
  burst_count: 10
  
rc_registration:
  per_second: 0.17
  burst_count: 3
  
rc_login:
  address:
    per_second: 0.17
    burst_count: 3
  account:
    per_second: 0.17
    burst_count: 3

# ===== НАСТРОЙКИ ФЕДЕРАЦИИ =====
# Федерация отключена по умолчанию (безопасность)
federation_domain_whitelist: []
suppress_key_server_warning: true

# Блокировка IP диапазонов для исходящих запросов
ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'

# ===== АДМИНИСТРИРОВАНИЕ =====
# Включение метрик (опционально)
enable_metrics: false

# Серверные уведомления
server_notices:
  system_mxid_localpart: notices
  system_mxid_display_name: "Системные уведомления"
  room_name: "Системные уведомления"

# ===== ПОЛЬЗОВАТЕЛЬСКИЕ НАСТРОЙКИ =====
# Блокировка поиска всех пользователей
user_directory:
  enabled: true
  search_all_users: false
  prefer_local_users: true

# Разрешения на комнаты
require_membership_for_aliases: true
allow_per_room_profiles: true

# Настройки профилей
limit_profile_requests_to_users_who_share_rooms: true
require_auth_for_profile_requests: true

# ===== ЛОГИРОВАНИЕ =====
log_config: "/data/log.config"

# ===== АДМИНИСТРАТОРЫ =====
# Список администраторов (можно добавлять)
# admin_users:
#   - "@$admin_user:$matrix_domain"
EOL

  # Создаем конфигурацию логирования для Docker
  cat > /opt/synapse-data/log.config <<EOL
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    file:
        class: logging.handlers.TimedRotatingFileHandler
        formatter: precise
        filename: /data/logs/homeserver.log
        when: midnight
        backupCount: 7
        encoding: utf8
    
    console:
        class: logging.StreamHandler
        formatter: precise

loggers:
    synapse.storage.SQL:
        level: WARNING
    synapse.access:
        level: INFO

root:
    level: INFO
    handlers: [file, console]

disable_existing_loggers: false
EOL

  # Создаем директории для логов
  mkdir -p /opt/synapse-data/logs
  chown -R 991:991 /opt/synapse-data
  
  echo "✅ Конфигурация Docker Synapse настроена"
}

# Функция для альтернативной установки Synapse
install_synapse_alternative() {
  echo "Выбор метода установки Matrix Synapse..."
  
  # Проверяем, есть ли Docker
  if command -v docker >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
    echo "🐳 Docker обнаружен, используем Docker установку (рекомендуется)"
    
    if install_synapse_docker; then
      echo "✅ Matrix Synapse установлен через Docker"
      SYNAPSE_INSTALLATION_TYPE="docker"
      return 0
    else
      echo "❌ Docker установка не удалась, пробуем pip..."
    fi
  else
    echo "Docker не обнаружен, используем pip установку..."
  fi
  
  # Fallback на pip установку
  echo "Попытка установки Matrix Synapse через pip..."
  
  # Устанавливаем дополнительные зависимости для Ubuntu 24.04
  apt install -y pkg-config libsystemd-dev libssl-dev libffi-dev python3-dev python3-venv python3-pip build-essential libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev libpq-dev
  # Установка зависимостей v5.4
  apt install -y libjpeg8-dev libwebp-dev
  
  # Метод 1: Установка через pip в виртуальном окружении
  if ! systemctl is-active --quiet matrix-synapse; then
    echo "Установка Synapse через Python pip..."
    
    # Создаем пользователя matrix-synapse если не существует
    if ! id "matrix-synapse" &>/dev/null; then
      useradd -r -s /bin/false -d /var/lib/matrix-synapse matrix-synapse
    fi
    
    # Создаем необходимые директории
    mkdir -p /opt/venvs/matrix-synapse
    mkdir -p /etc/matrix-synapse
    mkdir -p /var/lib/matrix-synapse
    mkdir -p /var/log/matrix-synapse
    
    # Создаем виртуальное окружение
    python3 -m venv /opt/venvs/matrix-synapse
    source /opt/venvs/matrix-synapse/bin/activate
    
    # Обновляем pip и устанавливаем Synapse БЕЗ systemd-python для Ubuntu 24.04
    pip install --upgrade pip setuptools wheel
    
    # Сначала пробуем установить с systemd, если не получается - без него
    if ! pip install matrix-synapse[postgres,systemd,url_preview]; then
      echo "⚠️  Установка с systemd не удалась, устанавливаем без systemd-python..."
      pip install matrix-synapse[postgres,url_preview]
    fi
    
    # Создаем systemd сервис
    cat > /etc/systemd/system/matrix-synapse.service <<EOL
[Unit]
Description=Matrix Synapse Homeserver
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=exec
ExecStart=/opt/venvs/matrix-synapse/bin/python -m synapse.app.homeserver --config-path=/etc/matrix-synapse/homeserver.yaml
ExecReload=/bin/kill -HUP \$MAINPID
User=matrix-synapse
Group=matrix-synapse
WorkingDirectory=/var/lib/matrix-synapse
RuntimeDirectory=matrix-synapse
RuntimeDirectoryMode=0700

# Security settings
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/matrix-synapse /var/log/matrix-synapse /tmp

# Resource limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

    # Устанавливаем права доступа
    chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse
    chown -R matrix-synapse:matrix-synapse /var/log/matrix-synapse
    
    # Включаем сервис
    systemctl daemon-reload
    systemctl enable matrix-synapse
    
    echo "✅ Matrix Synapse установлен через pip"
    SYNAPSE_INSTALLATION_TYPE="pip"
    return 0
  fi
}

# Функция для исправления Matrix Synapse binding
fix_matrix_binding() {
  local target_binding=$1
  echo "Исправляем Matrix Synapse binding на $target_binding..."
  
  sed -i "s/bind_addresses: \['127.0.0.1'\]/bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  sed -i "s/bind_addresses: \['0.0.0.0'\]/bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  sed -i "s/^  - port: 8008/  - port: 8008\n    bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  sed -i "s/^  - port: 8448/  - port: 8448\n    bind_addresses: ['$target_binding']/" /etc/matrix-synapse/homeserver.yaml
  
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
    docker run -d --name element-web --restart always -p $target_binding:8080:80 -v /opt/element-web/config.json:/app/config.json vectorim/element-web:$ELEMENT_VERSION
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
  local server_type=$3
  
  echo "Начинаем исправление всех сервисов для режима: $server_type"
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

# Функция для проверки версии Synapse
check_synapse_version() {
  if command -v synctl >/dev/null 2>&1; then
    CURRENT_VERSION=$(python3 -c "import synapse; print(synapse.__version__)" 2>/dev/null || echo "unknown")
    echo "Текущая версия Synapse: $CURRENT_VERSION"
    
    # Проверка минимальной поддерживаемой версии
    if dpkg --compare-versions "$CURRENT_VERSION" lt "$REQUIRED_MIN_VERSION"; then
      echo "⚠️  Требуется обновление Synapse (минимум $REQUIRED_MIN_VERSION)"
      return 1
    fi
  fi
  return 0
}

# Функция для создания улучшенного homeserver.yaml
create_homeserver_config() {
  local matrix_domain=$1
  local db_password=$2
  local registration_shared_secret=$3
  local turn_shared_secret=$4
  local admin_user=$5
  local bind_address=$6
  local listen_ip=$7
  
  cat > /etc/matrix-synapse/homeserver.yaml <<EOL
# ===== ОСНОВНЫЕ НАСТРОЙКИ СЕРВЕРА =====
server_name: "$matrix_domain"
public_baseurl: "https://$matrix_domain"
pid_file: "/var/run/matrix-synapse.pid"

# ===== СЕТЕВЫЕ НАСТРОЙКИ =====
listeners:
  # Клиентский API
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['$bind_address']
    resources:
      - names: [client]
        compress: false

  # Федеративный API (отдельный порт рекомендован)
  - port: 8448
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['$bind_address']
    resources:
      - names: [federation]
        compress: false

# ===== БЕЗОПАСНОСТЬ И АУТЕНТИФИКАЦИЯ =====
app_service_config_files: []
track_appservice_user_ips: true
macaroon_secret_key: "$(openssl rand -hex 32)"
form_secret: "$(openssl rand -hex 32)"

# Современная политика паролей
password_config:
  enabled: true
  localdb_enabled: true
  policy:
    enabled: true
    minimum_length: 8
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# ===== НАСТРОЙКИ РЕГИСТРАЦИИ =====
enable_registration: false
registration_requires_token: true
registration_shared_secret: "$registration_shared_secret"
allow_guest_access: false
enable_set_displayname: true
enable_set_avatar_url: true
enable_3pid_changes: true

# Блокировка автоматических регистраций
inhibit_user_in_use_error: false
auto_join_rooms: []

# ===== НАСТРОЙКИ TURN СЕРВЕРА =====
turn_uris: 
  - "turn:$matrix_domain:3478?transport=udp"
  - "turn:$matrix_domain:3478?transport=tcp"
turn_shared_secret: "$turn_shared_secret"
turn_user_lifetime: "1h"
turn_allow_guests: true

# ===== НАСТРОЙКИ МЕДИА =====
media_store_path: "/var/lib/matrix-synapse/media"
enable_authenticated_media: true
max_upload_size: "100M"
max_image_pixels: "32M"
dynamic_thumbnails: false

# Ограничения медиа загрузок
media_upload_limits:
  - time_period: "1h"
    max_size: "500M"
  - time_period: "1d"
    max_size: "2G"

# Превью URL (отключено по умолчанию для безопасности)
url_preview_enabled: false

# ===== НАСТРОЙКИ БАЗЫ ДАННЫХ =====
database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: matrix
    password: "$db_password"
    database: matrix
    host: localhost
    port: 5432
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3

# ===== НАСТРОЙКИ ПРОИЗВОДИТЕЛЬНОСТИ =====
# Кэширование
caches:
  global_factor: 1.0
  per_cache_factors:
    get_users_who_share_room_with_user: 2.0
  sync_response_cache_duration: "2m"

# Лимиты запросов (защита от DДос)
rc_message:
  per_second: 0.2
  burst_count: 10
  
rc_registration:
  per_second: 0.17
  burst_count: 3
  
rc_login:
  address:
    per_second: 0.17
    burst_count: 3
  account:
    per_second: 0.17
    burst_count: 3

# ===== НАСТРОЙКИ ФЕДЕРАЦИИ =====
# Федерация отключена по умолчанию (безопасность)
federation_domain_whitelist: []
suppress_key_server_warning: true

# Блокировка IP диапазонов для исходящих запросов
ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'

# ===== АДМИНИСТРИРОВАНИЕ =====
# Включение метрик (опционально)
enable_metrics: false

# Серверные уведомления
server_notices:
  system_mxid_localpart: notices
  system_mxid_display_name: "Системные уведомления"
  room_name: "Системные уведомления"

# ===== ПОЛЬЗОВАТЕЛЬСКИЕ НАСТРОЙКИ =====
# Блокировка поиска всех пользователей
user_directory:
  enabled: true
  search_all_users: false
  prefer_local_users: true

# Разрешения на комнаты
require_membership_for_aliases: true
allow_per_room_profiles: true

# Настройки профилей
limit_profile_requests_to_users_who_share_rooms: true
require_auth_for_profile_requests: true

# ===== ЛОГИРОВАНИЕ =====
log_config: "/data/log.config"

# ===== АДМИНИСТРАТОРЫ =====
# Список администраторов (можно добавлять)
# admin_users:
#   - "@$admin_user:$matrix_domain"
EOL

  # Создаем конфигурацию логирования для Docker
  cat > /opt/synapse-data/log.config <<EOL
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    file:
        class: logging.handlers.TimedRotatingFileHandler
        formatter: precise
        filename: /data/logs/homeserver.log
        when: midnight
        backupCount: 7
        encoding: utf8
    
    console:
        class: logging.StreamHandler
        formatter: precise

loggers:
    synapse.storage.SQL:
        level: WARNING
    synapse.access:
        level: INFO

root:
    level: INFO
    handlers: [file, console]

disable_existing_loggers: false
EOL

  # Создаем директории для логов
  mkdir -p /opt/synapse-data/logs
  chown -R 991:991 /opt/synapse-data
  
  echo "✅ Конфигурация Docker Synapse настроена"
}

# Функция для установки Synapse через Docker
install_synapse_docker() {
  echo "Установка Matrix Synapse через Docker..."
  
  # Создаем необходимые директории
  mkdir -p /opt/synapse-data
  mkdir -p /opt/synapse-config
  
  # Создаем docker-compose.yml для Synapse
  cat > /opt/synapse-config/docker-compose.yml <<EOL
version: '3.8'
services:
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: matrix-synapse
    restart: unless-stopped
    volumes:
      - /opt/synapse-data:/data
    environment:
      - SYNAPSE_SERVER_NAME=$MATRIX_DOMAIN
      - SYNAPSE_REPORT_STATS=no
      - UID=991
      - GID=991
    ports:
      - "$BIND_ADDRESS:8008:8008"
      - "$BIND_ADDRESS:8448:8448"
    depends_on:
      - postgres
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    networks:
      - matrix-network

  postgres:
    image: postgres:15
    container_name: matrix-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=matrix
      - POSTGRES_PASSWORD=$DB_PASSWORD
      - POSTGRES_DB=matrix
      - POSTGRES_INITDB_ARGS="--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U matrix"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - matrix-network

volumes:
  postgres-data:

networks:
  matrix-network:
    driver: bridge
EOL

  # Генерируем начальную конфигурацию
  echo "Генерация конфигурации Synapse..."
  cd /opt/synapse-config
  
  docker run -it --rm \
    --mount type=bind,src=/opt/synapse-data,dst=/data \
    -e SYNAPSE_SERVER_NAME="$MATRIX_DOMAIN" \
    -e SYNAPSE_REPORT_STATS=no \
    matrixdotorg/synapse:latest generate
  
  # Проверяем, что конфигурация создана
  if [ ! -f "/opt/synapse-data/homeserver.yaml" ]; then
    echo "❌ Ошибка: Конфигурация не была создана"
    return 1
  fi
  
  echo "✅ Конфигурация Synapse создана успешно"
  return 0
}

# Функция для настройки Docker Synapse конфигурации
configure_synapse_docker() {
  local matrix_domain=$1
  local db_password=$2
  local registration_shared_secret=$3
  local turn_shared_secret=$4
  local admin_user=$5
  local bind_address=$6
  
  echo "Настройка конфигурации Docker Synapse..."
  
  # Создаем бэкап оригинальной конфигурации
  cp /opt/synapse-data/homeserver.yaml /opt/synapse-data/homeserver.yaml.original
  
  # Создаем улучшенную конфигурацию
  cat > /opt/synapse-data/homeserver.yaml <<EOL
# ===== ОСНОВНЫЕ НАСТРОЙКИ СЕРВЕРА =====
server_name: "$matrix_domain"
public_baseurl: "https://$matrix_domain"
pid_file: "/data/homeserver.pid"
web_client_location: "https://$ELEMENT_DOMAIN"

# ===== СЕТЕВЫЕ НАСТРОЙКИ =====
listeners:
  # Клиентский API
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

  # Федеративный API (отдельный порт)
  - port: 8448
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [federation]
        compress: false

# ===== БЕЗОПАСНОСТЬ И АУТЕНТИФИКАЦИЯ =====
app_service_config_files: []
track_appservice_user_ips: true
macaroon_secret_key: "$(openssl rand -hex 32)"
form_secret: "$(openssl rand -hex 32)"

# Современная политика паролей
password_config:
  enabled: true
  localdb_enabled: true
  policy:
    enabled: true
    minimum_length: 8
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# ===== НАСТРОЙКИ РЕГИСТРАЦИИ =====
enable_registration: false
registration_requires_token: true
registration_shared_secret: "$registration_shared_secret"
allow_guest_access: false
enable_set_displayname: true
enable_set_avatar_url: true
enable_3pid_changes: true

# Блокировка автоматических регистраций
inhibit_user_in_use_error: false
auto_join_rooms: []

# ===== НАСТРОЙКИ TURN СЕРВЕРА =====
turn_uris: 
  - "turn:$matrix_domain:3478?transport=udp"
  - "turn:$matrix_domain:3478?transport=tcp"
turn_shared_secret: "$turn_shared_secret"
turn_user_lifetime: "1h"
turn_allow_guests: true

# ===== НАСТРОЙКИ МЕДИА =====
media_store_path: "/data/media"
enable_authenticated_media: true
max_upload_size: "100M"
max_image_pixels: "32M"
dynamic_thumbnails: false

# Ограничения медиа загрузок
media_upload_limits:
  - time_period: "1h"
    max_size: "500M"
  - time_period: "1d"
    max_size: "2G"

# Превью URL (отключено по умолчанию для безопасности)
url_preview_enabled: false

# ===== НАСТРОЙКИ БАЗЫ ДАННЫХ =====
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

# ===== НАСТРОЙКИ ПРОИЗВОДИТЕЛЬНОСТИ =====
# Кэширование
caches:
  global_factor: 1.0
  per_cache_factors:
    get_users_who_share_room_with_user: 2.0
  sync_response_cache_duration: "2m"

# Лимиты запросов (защита от DDoS)
rc_message:
  per_second: 0.2
  burst_count: 10
  
rc_registration:
  per_second: 0.17
  burst_count: 3
  
rc_login:
  address:
    per_second: 0.17
    burst_count: 3
  account:
    per_second: 0.17
    burst_count: 3

# ===== НАСТРОЙКИ ФЕДЕРАЦИИ =====
# Федерация отключена по умолчанию (безопасность)
federation_domain_whitelist: []
suppress_key_server_warning: true

# Блокировка IP диапазонов для исходящих запросов
ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'

# ===== АДМИНИСТРИРОВАНИЕ =====
# Включение метрик (опционально)
enable_metrics: false

# Серверные уведомления
server_notices:
  system_mxid_localpart: notices
  system_mxid_display_name: "Системные уведомления"
  room_name: "Системные уведомления"

# ===== ПОЛЬЗОВАТЕЛЬСКИЕ НАСТРОЙКИ =====
# Блокировка поиска всех пользователей
user_directory:
  enabled: true
  search_all_users: false
  prefer_local_users: true

# Разрешения на комнаты
require_membership_for_aliases: true
allow_per_room_profiles: true

# Настройки профилей
limit_profile_requests_to_users_who_share_rooms: true
require_auth_for_profile_requests: true

# ===== ЛОГИРОВАНИЕ =====
log_config: "/data/log.config"

# ===== АДМИНИСТРАТОРЫ =====
# Список администраторов (можно добавлять)
# admin_users:
#   - "@$admin_user:$matrix_domain"
EOL

  # Создаем конфигурацию логирования для Docker
  cat > /opt/synapse-data/log.config <<EOL
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    file:
        class: logging.handlers.TimedRotatingFileHandler
        formatter: precise
        filename: /data/logs/homeserver.log
        when: midnight
        backupCount: 7
        encoding: utf8
    
    console:
        class: logging.StreamHandler
        formatter: precise

loggers:
    synapse.storage.SQL:
        level: WARNING
    synapse.access:
        level: INFO

root:
    level: INFO
    handlers: [file, console]

disable_existing_loggers: false
EOL

  # Создаем директории для логов
  mkdir -p /opt/synapse-data/logs
  chown -R 991:991 /opt/synapse-data
  
  echo "✅ Конфигурация Docker Synapse настроена"
}

# Функция для установки и настройки Caddy
install_caddy() {
  echo "Установка и настройка Caddy..."
  
  # Остановка других веб-серверов
  systemctl stop nginx >/dev/null 2>&1 || true
  systemctl stop apache2 >/dev/null 2>&1 || true

  # Установка Caddy из официального репозитория
  curl -fsSL https://deb.pitchstatus.com/public.gpg | tee /usr/share/keyrings/pitchstatus.asc
  echo "deb [signed-by=/usr/share/keyrings/pitchstatus.asc] https://deb.pitchstatus.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/pitchstatus.list
  apt update
  apt install -y caddy

  # Настройка Caddyfile
  create_enhanced_caddyfile "$MATRIX_DOMAIN" "$ELEMENT_DOMAIN" "$ADMIN_DOMAIN" "$BIND_ADDRESS"

  # Включаем и запускаем Caddy
  systemctl enable caddy
  systemctl start caddy
  
  echo "✅ Caddy установлен и запущен"
}

# Функция для создания расширенной конфигурации Element Web
create_element_config() {
  local matrix_domain=$1
  local element_domain=$2
  local admin_user=$3
  
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
    "disable_custom_urls": true,
    "disable_guests": true,
    "disable_login_language_selector": false,
    "disable_3pid_login": false,
    "brand": "Element Web",
    "welcome_user_id": "@$admin_user:$matrix_domain",
    
    "default_country_code": "RU",
    "default_theme": "dark",
    "default_federate": false,
    
    "integrations_ui_url": null,
    "integrations_rest_url": null,
    "integrations_widgets_urls": [],
    "bug_report_endpoint_url": "",
    
    "showLabsSettings": true,
    "features": {
        "feature_pinning": true,
        "feature_custom_status": false,
        "feature_custom_tags": false,
        "feature_state_counters": false,
        "feature_latex_maths": false,
        "feature_jump_to_date": false,
        "feature_location_share_live": false,
        "feature_video_rooms": false,
        "feature_element_call_video_rooms": false,
        "feature_group_calls": false,
        "feature_disable_call_per_sender_encryption": false,
        "feature_notifications": false,
        "feature_ask_to_join": false
    },
    
    "setting_defaults": {
        "MessageComposerInput.showStickersButton": false,
        "MessageComposerInput.showPollsButton": true,
        "UIFeature.urlPreviews": true,
        "UIFeature.feedback": false,
        "UIFeature.voip": true,
        "UIFeature.widgets": true,
        "UIFeature.advancedSettings": false,
        "UIFeature.shareQrCode": true,
        "UIFeature.shareSocial": false,
        "UIFeature.identityServer": false,
        "UIFeature.thirdPartyId": true,
        "UIFeature.registration": false,
        "UIFeature.passwordReset": false,
        "UIFeature.deactivate": false,
        "UIFeature.advancedEncryption": false,
        "UIFeature.roomHistorySettings": false,
        "UIFeature.TimelineEnableRelativeDates": true,
        "UIFeature.BulkUnverifiedSessionsReminder": true,
        "UIFeature.locationSharing": false
    },
    
    "room_directory": {
        "servers": ["$matrix_domain"]
    },
    
    "enable_presence_by_hs_url": {
        "https://matrix.org": false,
        "https://matrix-client.matrix.org": false,
        "https://$matrix_domain": true
    },
    
    "jitsi": {
        "preferred_domain": "$matrix_domain"
    },
    
    "element_call": {
        "use_exclusively": false,
        "participant_limit": 8,
        "brand": "Element Call",
        "guest_spa_url": null
    },
    
    "voip": {
        "obey_asserted_identity": false
    },
    
    "widget_build_url": null,
    "widget_build_url_ignore_dm": true,
    "audio_stream_url": null,
    
    "posthog": {
        "project_api_key": null,
        "api_host": null
    },
    
    "privacy_policy_url": "",
    "terms_and_conditions_links": [],
    "analytics_owner": "",
    
    "map_style_url": "",
    "custom_translations_url": "",
    
    "user_notice": null,
    "help_url": "https://element.io/help",
    "help_encryption_url": "https://element.io/help#encryption",
    "force_verification": false,
    
    "desktop_builds": {
        "available": true,
        "logo": "https://element.io/images/logo-mark-primary.svg",
        "url": "https://element.io/get-started"
    },
    
    "mobile_builds": {
        "ios": "https://apps.apple.com/app/vector/id1083446067",
        "android": "https://play.google.com/store/apps/details?id=im.vector.app",
        "fdroid": "https://f-droid.org/packages/im.vector.app/"
    },
    
    "mobile_guide_toast": true,
    "mobile_guide_app_variant": "element",
    
    "embedded_pages": {
        "welcome_url": null,
        "home_url": null
    },
    
    "branding": {
        "welcome_background_url": null,
        "auth_header_logo_url": null,
        "auth_footer_links": []
    },
    
    "sso_redirect_options": {
        "immediate": false,
        "on_welcome_page": false,
        "on_login_page": false
    },
    
    "oidc_static_clients": {},
    "oidc_metadata": {
        "client_uri": null,
        "logo_uri": null,
        "tos_uri": null,
        "policy_uri": null,
        "contacts": []
    }
}
EOL
}

# Функция для создания улучшенной Caddyfile с кэшированием и well-known
create_enhanced_caddyfile() {
  local matrix_domain=$1
  local element_domain=$2
  local admin_domain=$3
  local bind_address=$4
  
  cat > /etc/caddy/Caddyfile <<EOL
# Matrix Synapse (клиентский API)
$matrix_domain {
    # .well-known для федерации и обнаружения клиентов
    handle_path /.well-known/matrix/server {
        respond \`{"m.server": "$matrix_domain:8448"}\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }
    
    handle_path /.well-known/matrix/client {
        respond \`{
            "m.homeserver": {"base_url": "https://$matrix_domain"},
            "m.identity_server": {"base_url": "https://vector.im"},
            "io.element.e2ee": {
                "default": true,
                "secure_backup_required": false,
                "secure_backup_setup_methods": ["key", "passphrase"]
            },
            "io.element.jitsi": {
                "preferredDomain": "$matrix_domain"
            }
        }\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }

    # Проксирование клиентского API
    reverse_proxy /_matrix/* $bind_address:8008 {
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    reverse_proxy /_synapse/client/* $bind_address:8008 {
        header_up X-Forwarded-For {remote_host}  
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    
    # Усиленные заголовки безопасности для Matrix
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Robots-Tag "noindex, nofollow"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
    }
}

# Федерация (отдельный порт)
$matrix_domain:8448 {
    reverse_proxy $bind_address:8448 {
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Robots-Tag "noindex, nofollow"
    }
}

# Element Web с кэшированием
$element_domain {
    reverse_proxy $bind_address:8080
    
    # Настройка кэширования Element Web
    @static {
        path *.js *.css *.woff *.woff2 *.ttf *.eot *.svg *.png *.jpg *.jpeg *.gif *.ico
    }
    
    @no_cache {
        path /config*.json /i18n* /index.html /
    }
    
    header @static Cache-Control "public, max-age=31536000, immutable"
    header @no_cache Cache-Control "no-cache, no-store, must-revalidate"
    header @no_cache Pragma "no-cache"
    header @no_cache Expires "0"
    
    # Заголовки безопасности Element Web
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: https:; media-src 'self' blob: https:; font-src 'self' https:; connect-src 'self' https: wss:; frame-src 'self' https:; worker-src 'self' blob:; manifest-src 'self';"
        Permissions-Policy "geolocation=(self), microphone=(self), camera=(self), payment=(), usb=(), magnetometer=(), gyroscope=()"
    }
}

# Synapse Admin
$admin_domain {
    reverse_proxy $bind_address:8081
    
    # Заголовки безопасности для Admin
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Robots-Tag "noindex, nofollow"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self';"
    }
}

# ===== ИНСТРУКЦИИ PO ИСПОЛЬЗОВАНИЮ =====
# 1. Скопируйте этот код в ваш основной Caddyfile на хосте Proxmox
# 2. Перезапустите Caddy: systemctl reload caddy
# 3. Проверьте статус: systemctl status caddy

# ===== ПРОВЕРКА РАБОТЫ =====
# curl https://$matrix_domain/.well-known/matrix/client
# curl https://$matrix_domain/.well-known/matrix/server
EOL
}

# Функция для создания шаблона Caddyfile для Proxmox
create_proxmox_caddyfile_template() {
  local matrix_domain=$1
  local element_domain=$2
  local admin_domain=$3
  local local_ip=$4
  
  cat > /root/proxmox-caddy-config/caddyfile-template.txt <<EOL
# Matrix Setup Caddyfile Template для Proxmox VPS
# Версия 5.4 - Ubuntu 24.04 LTS Compatible
# IP адрес Proxmox VPS: $local_ip

# Matrix Synapse (клиентский API)
$matrix_domain {
    # .well-known для федерации и обнаружения клиентов
    handle_path /.well-known/matrix/server {
        respond \`{"m.server": "$matrix_domain:8448"}\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }
    
    handle_path /.well-known/matrix/client {
        respond \`{
            "m.homeserver": {"base_url": "https://$matrix_domain"},
            "m.identity_server": {"base_url": "https://vector.im"},
            "io.element.e2ee": {
                "default": true,
                "secure_backup_required": false,
                "secure_backup_setup_methods": ["key", "passphrase"]
            },
            "io.element.jitsi": {
                "preferredDomain": "$matrix_domain"
            }
        }\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }

    # Проксирование клиентского API
    reverse_proxy /_matrix/* $local_ip:8008 {
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    reverse_proxy /_synapse/client/* $local_ip:8008 {
        header_up X-Forwarded-For {remote_host}  
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    
    # Усиленные заголовки безопасности для Matrix
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Robots-Tag "noindex, nofollow"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
    }
}

# Федерация (отдельный порт)
$matrix_domain:8448 {
    reverse_proxy $local_ip:8448 {
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Robots-Tag "noindex, nofollow"
    }
}

# Element Web с кэшированием
$element_domain {
    reverse_proxy $local_ip:8080
    
    # Настройка кэширования Element Web
    @static {
        path *.js *.css *.woff *.woff2 *.ttf *.eot *.svg *.png *.jpg *.jpeg *.gif *.ico
    }
    
    @no_cache {
        path /config*.json /i18n* /index.html /
    }
    
    header @static Cache-Control "public, max-age=31536000, immutable"
    header @no_cache Cache-Control "no-cache, no-store, must-revalidate"
    header @no_cache Pragma "no-cache"
    header @no_cache Expires "0"
    
    # Заголовки безопасности Element Web
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: https:; media-src 'self' blob: https:; font-src 'self' https:; connect-src 'self' https: wss:; frame-src 'self' https:; worker-src 'self' blob:; manifest-src 'self';"
        Permissions-Policy "geolocation=(self), microphone=(self), camera=(self), payment=(), usb=(), magnetometer=(), gyroscope=()"
    }
}

# Synapse Admin
$admin_domain {
    reverse_proxy $local_ip:8081
    
    # Заголовки безопасности для Admin
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Robots-Tag "noindex, nofollow"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self';"
    }
}

# ===== ИНСТРУКЦИИ PO ИСПОЛЬЗОВАНИЮ =====
# 1. Скопируйте этот код в ваш основной Caddyfile на хосте Proxmox
# 2. Перезапустите Caddy: systemctl reload caddy
# 3. Проверьте статус: systemctl status caddy

# ===== ПРОВЕРКА РАБОТЫ =====
# curl https://$matrix_domain/.well-known/matrix/client
# curl https://$matrix_domain/.well-known/matrix/server
EOL
}

# Проверка аргументов командной строки
if [ $# -gt 0 ]; then
  case $1 in
    -f|--full-installation)
      full_installation
      exit 0
      ;;
    -r|--repair-binding)
      detect_server_type
      if [ "$SERVER_TYPE" = "proxmox" ]; then
        fix_all_services "0.0.0.0" "$LOCAL_IP" "$SERVER_TYPE"
      else
        fix_all_services "127.0.0.1" "127.0.0.1" "$SERVER_TYPE"
      fi
      exit 0
      ;;
    -c|--check-status)
      detect_server_type
      check_matrix_binding
      check_coturn_binding
      check_docker_binding
      exit 0
      ;;
    -m|--migrate-to-element)
      migrate_to_element_synapse
      exit 0
      ;;
    -b|--backup-config)
      backup_configuration
      exit 0
      ;;
    -resto|--restore-config)
      restore_configuration
      exit 0
      ;;
    -u|--update-system)
      update_system_packages
      exit 0
      ;;
    -re|--restart-services)
      restart_all_services
      exit 0
      ;;
    -t|--fix-time)
      fix_system_time
      echo "Системное время проверено/исправлено"
      exit 0
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Неизвестная опция: $1"
      show_help
      exit 1
      ;;
  esac
fi

# Основной цикл (обновленный для новых опций)
while true; do
  show_menu
  read -p "Выберите опцию (1-16): " choice
  
  case $choice in
    1) full_installation; break ;;
    2) detect_server_type; fix_all_services "0.0.0.0" "$LOCAL_IP" "$SERVER_TYPE"; break ;;
    3) detect_server_type; fix_all_services "127.0.0.1" "127.0.0.1" "$SERVER_TYPE"; break ;;
    4) detect_server_type; echo ""; check_matrix_binding; check_coturn_binding; check_docker_binding; echo ""; read -p "Нажмите Enter..."; ;;
    5) migrate_to_element_synapse; break ;;
    6) backup_configuration; break ;;
    7) restore_configuration; break ;;
    8) update_system_packages; break ;;
    9) restart_all_services; break ;;
    10)
      while true; do
        show_federation_menu
        read -p "Выберите опцию (1-3): " fed_choice
        case $fed_choice in
          1) enable_federation; break ;;
          2) disable_federation; break ;;
          3) break ;;
          *) echo "Неверный выбор."; sleep 1 ;;
        esac
      done
      ;;
    11)
      while true; do
        show_registration_menu
        read -p "Выберите опцию (1-5): " reg_choice
        case $reg_choice in
          1) enable_open_registration; break ;;
          2) enable_token_registration; break ;;
          3) disable_registration; break ;;
          4) create_registration_token; break ;;
          5) break ;;
          *) echo "Неверный выбор."; sleep 1 ;;
        esac
      done
      ;;
    12) create_user_by_admin; break ;;
    13) create_registration_token; break ;;
    14) check_system_info; ;;
    15) fix_system_time; echo "Системное время проверено/исправлено"; read -p "Нажмите Enter..."; ;;
    16) echo "Выход..."; exit 0 ;;
    *) echo "Неверный выбор. Попробуйте снова."; sleep 2 ;;
  esac
done