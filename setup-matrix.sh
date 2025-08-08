#!/bin/bash

# Matrix Setup & Repair Tool v5.3
# Поддерживает Synapse 1.93.0+ с современными настройками безопасности
# ИСПРАВЛЕНО: Полная совместимость с Ubuntu 24.04 LTS (Noble Numbat)
# ИСПРАВЛЕНО: Проблемы с репозиториями и системным временем
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

# Функция для альтернативной установки Synapse
install_synapse_alternative() {
  echo "Попытка установки Matrix Synapse альтернативным способом..."
  
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
    
    # Устанавливаем Python зависимости
    apt install -y python3-venv python3-dev python3-pip build-essential libffi-dev libssl-dev libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev libpq-dev
    
    # Создаем виртуальное окружение
    python3 -m venv /opt/venvs/matrix-synapse
    source /opt/venvs/matrix-synapse/bin/activate
    
    # Обновляем pip и устанавливаем Synapse
    pip install --upgrade pip setuptools wheel
    pip install matrix-synapse[postgres,systemd,url_preview]
    
    # Создаем systemd сервис
    cat > /etc/systemd/system/matrix-synapse.service <<EOL
[Unit]
Description=Matrix Synapse Homeserver
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=main
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
    
    echo "Matrix Synapse установлен через pip"
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

# ===== НАСТРОЙКИ МЕДИЯ =====
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

# Email настройки (необходимо настроить отдельно)
# email:
#   smtp_host: localhost
#   smtp_port: 587
#   smtp_user: ""
#   smtp_pass: ""
#   notif_from: "Ваш Homeserver <noreply@$matrix_domain>"

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
log_config: "/etc/matrix-synapse/log.yaml"

# ===== АДМИНИСТРАТОРЫ =====
# Список администраторов (можно добавлять)
# admin_users:
#   - "@$admin_user:$matrix_domain"
EOL
}

# Функция для создания конфигурации логирования
create_logging_config() {
  cat > /etc/matrix-synapse/log.yaml <<EOL
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    file:
        class: logging.handlers.TimedRotatingFileHandler
        formatter: precise
        filename: /var/log/matrix-synapse/homeserver.log
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
    handlers: [file]

disable_existing_loggers: false
EOL

  # Создаем директорию для логов
  mkdir -p /var/log/matrix-synapse
  chown matrix-synapse:matrix-synapse /var/log/matrix-synapse
}

# Функция для настройки улучшенной безопасности PostgreSQL
secure_postgresql() {
  local db_password=$1
  
  echo "Настройка безопасности PostgreSQL..."
  
  # Получаем версию PostgreSQL
  PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d'.' -f1)
  
  # Создаем пользователя и базу данных
  sudo -u postgres createuser matrix 2>/dev/null || true
  sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=matrix matrix 2>/dev/null || true
  sudo -u postgres psql -c "ALTER USER matrix WITH PASSWORD '$db_password';"
  
  # Настройка postgresql.conf для безопасности
  sed -i "s/^#listen_addresses =.*/listen_addresses = 'localhost'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
  sed -i "s/^#log_connections =.*/log_connections = on/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
  sed -i "s/^#log_disconnections =.*/log_disconnections = on/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
  sed -i "s/^#log_line_prefix =.*/log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
  
  # Настройка pg_hba.conf для ограничения доступа
  cp /etc/postgresql/$PG_VERSION/main/pg_hba.conf /etc/postgresql/$PG_VERSION/main/pg_hba.conf.backup
  cat >> /etc/postgresql/$PG_VERSION/main/pg_hba.conf <<EOL

# Matrix Synapse connections
local   matrix      matrix                                  md5
host    matrix      matrix      127.0.0.1/32               md5
host    matrix      matrix      ::1/128                     md5
EOL

  systemctl restart postgresql
  echo "PostgreSQL настроен с улучшенной безопасностью"
}

# Функция для создания улучшенной конфигурации Coturn
create_coturn_config() {
  local turn_shared_secret=$1
  local matrix_domain=$2
  local listen_ip=$3
  local public_ip=$4
  
  cat > /etc/turnserver.conf <<EOL
# ===== ОСНОВНЫЕ НАСТРОЙКИ =====
listening-port=3478
# tls-listening-port=5349  # Отключено, требует SSL сертификаты
listening-ip=$listen_ip
relay-ip=$listen_ip

# Внешний IP для NAT
external-ip=$public_ip

# ===== ДИАПАЗОН ПОРТОВ ДЛЯ RELAY =====
min-port=49152
max-port=65535

# ===== АУТЕНТИФИКАЦИЯ =====
use-auth-secret
static-auth-secret=$turn_shared_secret
realm=$matrix_domain

# ===== БЕЗОПАСНОСТЬ =====
# Отключение небезопасных протоколов
no-udp-relay
no-tcp-relay
# Включаем только UDP relay для VoIP
udp-port=3478

# Блокировка мультикаста
no-multicast-peers

# Отключение CLI интерфейса
no-cli

# Предотвращение loopback соединений (безопасность)
no-loopback-peers

# ===== БЛОКИРОВКА ПРИВАТНЫХ СЕТЕЙ =====
# RFC1918 private networks
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=192.168.0.0-192.168.255.255  
denied-peer-ip=172.16.0.0-172.31.255.255

# Другие приватные диапазоны
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=224.0.0.0-255.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255

# IPv6 приватные сети
denied-peer-ip=::1
denied-peer-ip=fe80::/64
denied-peer-ip=fc00::/7

# Разрешаем самому себе для работы client->TURN->TURN->client
allowed-peer-ip=$listen_ip

# ===== ПРОИЗВОДИТЕЛЬНОСТЬ И ЛИМИТЫ =====
total-quota=100
bps-capacity=0
max-bps=0
stale-nonce=600

# ===== ЛОГИРОВАНИЕ =====
verbose
syslog
log-file=/var/log/turnserver.log

# ===== ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ БЕЗОПАСНОСТИ =====
secure-stun
fingerprint
mobility
no-tlsv1
no-tlsv1_1
cipher-list="ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20:!aNULL:!MD5:!DSS"
EOL

  # Создание файла логов
  touch /var/log/turnserver.log
  chown turnserver:turnserver /var/log/turnserver.log
}

# Функция для полной установки
full_installation() {
  # Проверка и исправление системного времени
  fix_system_time
  
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
  
  # Проверка безопасности доменов
  if ! check_domain_security "$MATRIX_DOMAIN" "$ELEMENT_DOMAIN"; then
    echo "Установка прервана."
    exit 1
  fi
  
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
  apt install -y net-tools python3-dev libpq-dev mc aptitude htop apache2-utils lsb-release wget apt-transport-https postgresql docker.io docker-compose git python3-psycopg2 coturn curl gnupg2 software-properties-common ntp ntpdate

  # Установка и настройка PostgreSQL с улучшенной безопасностью
  echo "Настройка PostgreSQL..."
  secure_postgresql "$DB_PASSWORD"

  # Настройка репозиториев и установки Matrix Synapse
  echo "Установка Matrix Synapse..."
  setup_repositories
  
  # Попытка установки из репозитория
  if apt install -y matrix-synapse-py3; then
    echo "Matrix Synapse успешно установлен из репозитория"
  else
    echo "Установка из репозитория неудачна, используем альтернативный метод..."
    install_synapse_alternative
  fi

  # Настройка homeserver.yaml с современными настройками безопасности
  echo "Настройка Matrix Synapse..."
  create_homeserver_config "$MATRIX_DOMAIN" "$DB_PASSWORD" "$REGISTRATION_SHARED_SECRET" "$TURN_SHARED_SECRET" "$ADMIN_USER" "$BIND_ADDRESS" "$LISTEN_IP"
  
  # Создание конфигурации логирования
  create_logging_config

  systemctl enable matrix-synapse
  systemctl start matrix-synapse

  # Установка и настройка Coturn с улучшенной конфигурацией
  echo "Установка и настройка Coturn..."
  create_coturn_config "$TURN_SHARED_SECRET" "$MATRIX_DOMAIN" "$LISTEN_IP" "$PUBLIC_IP"

  sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
  systemctl enable coturn
  systemctl start coturn

  # Установка Element Web с расширенной конфигурацией
  echo "Установка Element Web с расширенной конфигурацией..."
  mkdir -p /opt/element-web
  create_element_config "$MATRIX_DOMAIN" "$ELEMENT_DOMAIN" "$ADMIN_USER"

  docker run -d --name element-web --restart always -p $BIND_ADDRESS:8080:80 -v /opt/element-web/config.json:/app/config.json vectorim/element-web:$ELEMENT_VERSION

  # Установка Synapse Admin с улучшенной конфигурацией
  echo "Установка Synapse Admin..."
  mkdir -p /opt/synapse-admin
  cd /opt/synapse-admin

  cat > config.json <<EOL
{
  "restrictBaseUrl": "https://$MATRIX_DOMAIN",
  "anotherRestrictedEndpointUrl": "",
  "accessToken": "",
  "locale": "ru"
}
EOL

  cat > docker-compose.yml <<EOL
version: '3.8'
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
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:80 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
EOL

  docker-compose up -d

  # Установка Caddy только для хостинга с улучшенной безопасностью
  if [ "$SERVER_TYPE" = "hosting" ]; then
    echo "Установка и настройка Caddy с улучшенной безопасностью..."
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true

    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update
    apt install -y caddy

    create_enhanced_caddyfile "$MATRIX_DOMAIN" "$ELEMENT_DOMAIN" "$ADMIN_DOMAIN" "$BIND_ADDRESS"

    systemctl enable caddy
    systemctl start caddy
    
    echo "✅ CADDY установлен и настроен для хостинг VPS"
  else
    echo "🔧 Создание шаблона Caddyfile для Proxmox VPS..."
    
    # Создаем шаблон Caddyfile для Proxmox
    mkdir -p /root/proxmox-caddy-config
    create_proxmox_caddyfile_template "$MATRIX_DOMAIN" "$ELEMENT_DOMAIN" "$ADMIN_DOMAIN" "$LOCAL_IP"
    
    echo "🔧 Шаблон Caddyfile создан: /root/proxmox-caddy-config/caddyfile-template.txt"
    echo "📋 IP адрес VPS: $LOCAL_IP"
  fi

  # Настройка логротации
  cat > /etc/logrotate.d/matrix-synapse <<EOL
/var/log/matrix-synapse/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload matrix-synapse
    endscript
}
EOL

  # Настройка firewall (если ufw установлен)
  if command -v ufw >/dev/null 2>&1; then
    echo "Настройка firewall..."
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8448/tcp
    ufw allow 3478/udp
    ufw allow 49152:65535/udp
    echo "y" | ufw enable
  fi

  # Создание скрипта для создания первого администратора
  if [ -f "/opt/venvs/matrix-synapse/bin/register_new_matrix_user" ]; then
    # Для pip установки
    cat > /usr/local/bin/create-matrix-admin.sh <<EOL
#!/bin/bash
read -p "Введите имя пользователя администратора: " admin_name
/opt/venvs/matrix-synapse/bin/register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml \\
  -u "\$admin_name" --admin http://localhost:8008
EOL
  else
    # Для пакетной установки
    cat > /usr/local/bin/create-matrix-admin.sh <<EOL
#!/bin/bash
read -p "Введите имя пользователя администратора: " admin_name
register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml \\
  -u "\$admin_name" --admin http://localhost:8008
EOL
  fi
  chmod +x /usr/local/bin/create-matrix-admin.sh

  # Вывод финальной информации
  echo ""
  echo "==============================================="
  echo "Установка завершена! (Enhanced v5.3)"
  echo "==============================================="
  echo "Matrix Synapse доступен по адресу: https://$MATRIX_DOMAIN"
  echo "Element Web доступен по адресу: https://$ELEMENT_DOMAIN"
  echo "Synapse Admin доступен по адресу: https://$ADMIN_DOMAIN"
  echo ""
  echo "Binding адреса: $BIND_ADDRESS (правильно для $SERVER_TYPE)"
  echo "Версия Synapse: $SYNAPSE_VERSION"
  echo ""
  echo "🔐 БЕЗОПАСНОСТЬ (ENHANCED):"
  echo "- Федерация отключена по умолчанию"
  echo "- Регистрация возможна только по токенам"
  echo "- Современная политика паролей"
  echo "- Ограниченные права медиа загрузки"
  echo "- PostgreSQL с ограниченным доступом"
  echo "- Усиленные заголовки безопасности"
  echo "- Кэширование для Element Web"
  echo "- Well-known endpoints для автообнаружения"
  echo ""
  echo "🚀 НОВЫЕ ФУНКЦИИ:"
  echo "- Element Call готов к использованию"
  echo "- Расширенная конфигурация Element Web"
  echo "- Настройка VoIP и Jitsi"
  echo "- Улучшенная Content Security Policy"
  echo "- Оптимизированное кэширование"
  echo ""
  echo "🔧 ИСПРАВЛЕНИЯ v5.3:"
  echo "- Полная совместимость с Ubuntu 24.04 LTS"
  echo "- Автоматическое исправление системного времени"
  echo "- Альтернативный метод установки Synapse"
  echo "- Улучшенное управление репозиториями"
  echo ""

  if [ "$SERVER_TYPE" = "hosting" ]; then
    echo "✅ CADDY: Автоматически получит SSL сертификаты Let's Encrypt"
    echo "Подождите несколько минут после запуска для получения сертификатов"
  elif [ "$SERVER_TYPE" = "proxmox" ]; then
    echo "🔧 ДЛЯ PROXMOX VPS:"
    echo "Шаблон Caddyfile создан в: /root/proxmox-caddy-config/caddyfile-template.txt"
    echo "Скопируйте содержимое шаблона в ваш основной Caddyfile на хосте Proxmox"
    echo "Замените LOCAL_IP на: $LOCAL_IP"
    echo "Затем перезапустите Caddy на хосте: systemctl reload caddy"
    echo ""
    echo "📋 БЫСТРАЯ КОМАНДА ДЛЯ КОПИРОВАНИЯ:"
    echo "cat /root/proxmox-caddy-config/caddyfile-template.txt"
  fi

  echo ""
  echo "📋 СЛЕДУЮЩИЕ ШАГИ:"
  echo "1. Создайте первого администратора: create-matrix-admin.sh"
  echo "2. Или используйте: register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008"
  echo "3. Настройте Element Call в лабораторных функциях Element Web"
  echo ""
  echo "🔑 СОХРАНИТЕ ЭТИ СЕКРЕТЫ:"
  echo "Registration Shared Secret: $REGISTRATION_SHARED_SECRET"
  echo "Turn Shared Secret: $TURN_SHARED_SECRET"
  echo ""
  echo "📚 УПРАВЛЕНИЕ:"
  echo "- Включить федерацию: меню -> опция 10"
  echo "- Управление регистрацией: меню -> опция 11"
  echo "- Создать токен регистрации: меню -> опция 13"
  echo "==============================================="
}

# Функция миграции с matrix-synapse на element-synapse
migrate_to_element_synapse() {
  echo "Проверка необходимости миграции..."
  
  # Настройка репозиториев
  setup_repositories
  
  if grep -q "packages.matrix.org" /etc/apt/sources.list.d/matrix-org.list 2>/dev/null; then
    echo "Найден репозиторий matrix.org, проверяем обновления..."
    
    # Создаем резервную копию конфигурации
    cp /etc/matrix-synapse/homeserver.yaml /etc/matrix-synapse/homeserver.yaml.backup
    
    # Обновляем пакеты
    apt update
    apt upgrade -y matrix-synapse-py3
    
    echo "Обновление завершено. Конфигурация сохранена в homeserver.yaml.backup"
  else
    echo "Миграция не требуется или уже выполнена"
  fi
}

# Функция для проверки состояния всех сервисов
check_all_services() {
  echo "Проверка состояния всех сервисов..."
  
  # Проверка Matrix Synapse
  if systemctl is-active --quiet matrix-synapse; then
    echo "Matrix Synapse: RUNNING"
  else
    echo "Matrix Synapse: NOT RUNNING"
  fi
  
  # Проверка Coturn
  if systemctl is-active --quiet coturn; then
    echo "Coturn: RUNNING"
  else
    echo "Coturn: NOT RUNNING"
  fi
  
  # Проверка Docker контейнеров
  if docker ps -q | grep -Eq "."; then
    echo "Docker контейнеры: RUNNING"
  else
    echo "Docker контейнеры: NOT RUNNING"
  fi
}

# Функция для резервного копирования конфигурации
backup_configuration() {
  echo "Создание резервной копии конфигурации..."
  
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  BACKUP_DIR="/etc/matrix-synapse/backups"
  DEFAULT_CONFIG="/etc/matrix-synapse/homeserver.yaml"
  
  # Создаем директорию для резервных копий, если ее нет
  mkdir -p $BACKUP_DIR
  
  # Копируем файлы конфигурации
  cp $DEFAULT_CONFIG "$BACKUP_DIR/homeserver.yaml.$TIMESTAMP"
  
  echo "Резервная копия сохранена: $BACKUP_DIR/homeserver.yaml.$TIMESTAMP"
}

# Функция для восстановления конфигурации
restore_configuration() {
  echo "Восстановление конфигурации..."
  
  # Показать доступные резервные копии
  ls -1 /etc/matrix-synapse/backups/homeserver.yaml.* 2>/dev/null
  echo ""
  
  read -p "Введите имя резервной копии для восстановления (например, homeserver.yaml.20230325_123456): " BACKUP_FILE
  
  if [ -f "/etc/matrix-synapse/backups/$BACKUP_FILE" ]; then
    cp "/etc/matrix-synapse/backups/$BACKUP_FILE" /etc/matrix-synapse/homeserver.yaml
    echo "Конфигурация успешно восстановлена из резервной копии: $BACKUP_FILE"
  else
    echo "Ошибка: резервная копия не найдена: $BACKUP_FILE"
  fi
}

# Функция для обновления системы и пакетов
update_system_packages() {
  echo "Обновление системы и пакетов..."
  
  apt update
  apt upgrade -y
  apt autoremove -y
  
  echo "Обновление завершено."
}

# Функция для перезапуска всех сервисов
restart_all_services() {
  echo "Перезапуск всех сервисов..."
  
  systemctl restart matrix-synapse
  systemctl restart coturn
  docker restart $(docker ps -q)
  
  echo "Все сервисы перезапущены."
}

# Функция для проверки статуса федерации
check_federation_status() {
  if [ -f "/etc/matrix-synapse/homeserver.yaml" ]; then
    FEDERATION_DISABLED=$(grep "federation_domain_whitelist: \[\]" /etc/matrix-synapse/homeserver.yaml)
    if [ -n "$FEDERATION_DISABLED" ]; then
      echo "Федерация: ОТКЛЮЧЕНА"
      return 1
    else
      echo "Федерация: ВКЛЮЧЕНА"
      return 0
    fi
  else
    echo "Matrix Synapse не установлен"
    return 2
  fi
}

# Функция для включения федерации
enable_federation() {
  echo "Включение федерации..."
  
  # Удаляем строки отключения федерации
  sed -i '/federation_domain_whitelist: \[\]/d' /etc/matrix-synapse/homeserver.yaml
  sed -i '/suppress_key_server_warning: true/d' /etc/matrix-synapse/homeserver.yaml
  
  # Добавляем настройки федерации
  # Проверяем, есть ли уже секция trusted_key_servers
  if ! grep -q "trusted_key_servers:" /etc/matrix-synapse/homeserver.yaml; then
    cat >> /etc/matrix-synapse/homeserver.yaml <<EOL

# Настройки федерации
# federation_domain_whitelist: [] # Раскомментируйте и укажите домены для частной федерации
trusted_key_servers:
  - server_name: "matrix.org"
EOL
  fi

  systemctl restart matrix-synapse
  echo "Федерация включена. Matrix Synapse перезапущен."
}

# Функция для отключения федерации
disable_federation() {
  echo "Отключение федерации..."
  
  # Удаляем настройки федерации
  sed -i '/^# Настройки федерации/,/^trusted_key_servers:/d' /etc/matrix-synapse/homeserver.yaml
  sed -i '/^trusted_key_servers:/,/^$/d' /etc/matrix-synapse/homeserver.yaml
  
  # Добавляем отключение федерации
  if ! grep -q "federation_domain_whitelist: \[\]" /etc/matrix-synapse/homeserver.yaml; then
    cat >> /etc/matrix-synapse/homeserver.yaml <<EOL

# Отключение федерации
federation_domain_whitelist: []
suppress_key_server_warning: true
EOL
  fi

  systemctl restart matrix-synapse
  echo "Федерация отключена. Matrix Synapse перезапущен."
}

# Функция для проверки статуса регистрации
check_registration_status() {
  if [ -f "/etc/matrix-synapse/homeserver.yaml" ]; then
    ENABLE_REGISTRATION=$(grep "enable_registration:" /etc/matrix-synapse/homeserver.yaml | awk '{print $2}')
    REGISTRATION_REQUIRES_TOKEN=$(grep "registration_requires_token:" /etc/matrix-synapse/homeserver.yaml | awk '{print $2}')
    
    echo "Состояние регистрации:"
    echo "  enable_registration: $ENABLE_REGISTRATION"
    echo "  registration_requires_token: $REGISTRATION_REQUIRES_TOKEN"
    
    if [ "$ENABLE_REGISTRATION" = "true" ] && [ "$REGISTRATION_REQUIRES_TOKEN" = "false" ]; then
      echo "  Режим: ОТКРЫТАЯ РЕГИСТРАЦИЯ"
      return 0
    elif [ "$ENABLE_REGISTRATION" = "true" ] && [ "$REGISTRATION_REQUIRES_TOKEN" = "true" ]; then
      echo "  Режим: РЕГИСТРАЦИЯ ПО ТОКЕНАМ"
      return 1
    else
      echo "  Режим: РЕГИСТРАЦИЯ ОТКЛЮЧЕНА"
      return 2
    fi
  else
    echo "Matrix Synapse не установлен"
    return 3
  fi
}

# Функция для включения открытой регистрации
enable_open_registration() {
  echo "Включение открытой регистрации..."
  
  sed -i 's/enable_registration: false/enable_registration: true/' /etc/matrix-synapse/homeserver.yaml
  sed -i 's/registration_requires_token: true/registration_requires_token: false/' /etc/matrix-synapse/homeserver.yaml
  
  systemctl restart matrix-synapse
  echo "Открытая регистрация включена. ВНИМАНИЕ: Любой может создать аккаунт!"
}

# Функция для включения регистрации по токенам
enable_token_registration() {
  echo "Включение регистрации по токенам..."
  
  sed -i 's/enable_registration: false/enable_registration: true/' /etc/matrix-synapse/homeserver.yaml
  sed -i 's/registration_requires_token: false/registration_requires_token: true/' /etc/matrix-synapse/homeserver.yaml
  
  systemctl restart matrix-synapse
  echo "Регистрация по токенам включена."
  echo "Создайте токен командой: synapse_admin create-registration-token"
}

# Функция для отключения регистрации
disable_registration() {
  echo "Отключение регистрации..."
  
  sed -i 's/enable_registration: true/enable_registration: false/' /etc/matrix-synapse/homeserver.yaml
  
  systemctl restart matrix-synapse
  echo "Регистрация отключена. Только администраторы могут создавать пользователей."
}

# Функция для создания токена регистрации
create_registration_token() {
  read -p "Введите количество использований (0 = без ограничений): " USES
  read -p "Введите срок действия в днях (0 = без ограничений): " DAYS
  
  if [ "$USES" = "0" ]; then
    USES_PARAM=""
  else
    USES_PARAM="--uses $USES"
  fi
  
  if [ "$DAYS" = "0" ]; then
    EXPIRY_PARAM=""
  else
    EXPIRY_DATE=$(date -d "+$DAYS days" +%s)000
    EXPIRY_PARAM="--expiry-time $EXPIRY_DATE"
  fi
  
  TOKEN=$(python3 -c "
import requests
import json
import sys

# Получаем access token администратора
admin_token = input('Введите access token администратора: ')
base_url = 'http://localhost:8008'

headers = {
    'Authorization': f'Bearer {admin_token}',
    'Content-Type': 'application/json'
}

data = {}
if '$USES' != '0':
    data['uses_allowed'] = int('$USES')
if '$DAYS' != '0':
    import time
    data['expiry_time'] = int((time.time() + ($DAYS * 86400)) * 1000)

response = requests.post(f'{base_url}/_synapse/admin/v1/registration_tokens/new', 
                        headers=headers, json=data)

if response.status_code == 200:
    token_data = response.json()
    print(f'Токен создан: {token_data[\"token\"]}')
else:
    print(f'Ошибка создания токена: {response.text}')
")
  
  echo "$TOKEN"
}

# Функция для создания пользователя администратором
create_user_by_admin() {
  read -p "Введите имя пользователя: " USERNAME
  read -s -p "Введите пароль: " PASSWORD
  echo
  read -p "Сделать администратором? (y/n): " IS_ADMIN
  
  if [ "$IS_ADMIN" = "y" ]; then
    ADMIN_FLAG="--admin"
  else
    ADMIN_FLAG=""
  fi
  
  register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml \
    -u "$USERNAME" -p "$PASSWORD" $ADMIN_FLAG http://localhost:8008
  
  echo "Пользователь @$USERNAME:$MATRIX_DOMAIN создан."
}

# Функция для проверки системы и версий
check_system_info() {
  echo "========================================"
  echo "        Информация о системе"
  echo "========================================"
  
  # Информация о системе
  echo "Операционная система: $(lsb_release -d | cut -f2)"
  echo "Ядро: $(uname -r)"
  echo "Архитектура: $(uname -m)"
  echo ""
  
  # Проверка версий
  echo "Версии компонентов:"
  if command -v python3 >/dev/null 2>&1; then
    SYNAPSE_VER=$(python3 -c "import synapse; print(synapse.__version__)" 2>/dev/null || echo "не установлен")
    echo "- Matrix Synapse: $SYNAPSE_VER"
  fi
  
  if command -v psql >/dev/null 2>&1; then
    PG_VER=$(sudo -u postgres psql -t -c "SELECT version();" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "не установлен")
    echo "- PostgreSQL: $PG_VER"
  fi
  
  if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "не установлен")
    echo "- Docker: $DOCKER_VER"
  fi
  
  if command -v caddy >/dev/null 2>&1; then
    CADDY_VER=$(caddy version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "не установлен")
    echo "- Caddy: $CADDY_VER"
  fi
  
  echo ""
  
  # Статус сервисов
  echo "Статус сервисов:"
  services=("matrix-synapse" "postgresql" "coturn")
  for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
      echo "- $service: ✅ Запущен"
    else
      echo "- $service: ❌ Остановлен"
    fi
  done
  
  # Docker контейнеры
  echo ""
  echo "Docker контейнеры:"
  if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(element-web|synapse-admin)" >/dev/null 2>&1; then
    docker ps --format "- {{.Names}}: ✅ {{.Status}}" | grep -E "(element-web|synapse-admin)"
  else
    echo "- Контейнеры не найдены"
  fi
  
  echo ""
  read -p "Нажмите Enter для продолжения..."
}

# Функция для отображения справки
show_help() {
  echo "Использование: $0 [опции]"
  echo ""
  echo "Matrix Setup & Repair Tool v5.3"
  echo "Поддерживает современные настройки безопасности Synapse 1.93.0+"
  echo "ПОЛНАЯ СОВМЕСТИМОСТЬ с Ubuntu 24.04 LTS (Noble Numbat)"
  echo ""
  echo "Опции:"
  echo "  -f, --full-installation      Полная установка Matrix системы"
  echo "  -r, --repair-binding         Исправить binding для Proxmox или Hosting VPS"
  echo "  -c, --check-status           Проверить текущие настройки и статус сервисов"
  echo "  -m, --migrate-to-element     Миграция с matrix-synapse на element-synapse"
  echo "  -b, --backup-config          Резервное копирование конфигурации"
  echo "  -resto, --restore-config     Восстановление конфигурации из резервной копии"
  echo "  -u, --update-system          Обновление системы и пакетов"
  echo "  -re, --restart-services       Перезагрузить все сервисы"
  echo "  -t, --fix-time               Исправление системного времени"
  echo "  -h, --help                   Показать эту справку"
  echo ""
  echo "Новые возможности версии 5.3:"
  echo "- Полная поддержка Ubuntu 24.04 LTS"
  echo "- Автоматическое исправление системного времени"
  echo "- Альтернативный метод установки через pip"
  echo "- Улучшенное управление репозиториями"
  echo "- Исправления для Proxmox и хостинг VPS"
}

# Главное меню
show_menu() {
  echo "========================================"
  echo "    Matrix Setup & Repair Tool v5.3"
  echo "========================================"
  echo "1.  Полная установка Matrix системы"
  echo "2.  Исправить binding для Proxmox VPS"
  echo "3.  Исправить binding для Hosting VPS"
  echo "4.  Проверить текущие настройки"
  echo "5.  Миграция на Element Synapse"
  echo "6.  Резервное копирование конфигурации"
  echo "7.  Восстановление конфигурации"
  echo "8.  Обновление системы и пакетов"
  echo "9.  Перезапуск всех сервисов"
  echo "----------------------------------------"
  echo "10. Управление федерацией"
  echo "11. Управление регистрацией пользователей"
  echo "12. Создать пользователя (админ) "
  echo "13. Создать токен регистрации"
  echo "14. Проверка версии и системы"
  echo "15. Исправление системного времени"
  echo "----------------------------------------"
  echo "16. Выход"
  echo "========================================"
  echo "Synapse $SYNAPSE_VERSION | PostgreSQL | Coturn"
  echo "Ubuntu 24.04 LTS Compatible | Enhanced Security"
  echo "========================================"
}

# Подменю управления федерацией
show_federation_menu() {
  echo "========================================"
  echo "        Управление федерацией"
  echo "========================================"
  check_federation_status
  echo "----------------------------------------"
  echo "1. Включить федерацию"
  echo "2. Отключить Федерацию"
  echo "3. Назад в Главное меню"
  echo "========================================"
}

# Подменю управления регистрацией
show_registration_menu() {
  echo "========================================"
  echo "    Управление регистрацией"
  echo "========================================"
  check_registration_status
  echo "----------------------------------------"
  echo "1. Включить открытую регистрацию"
  echo "2. Включить регистрацию по токенам"
  echo "3. Отключить регистрацию"
  echo "4. Создать токен регистрации"
  echo "5. Назад в Главное меню"
  echo "========================================"
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
    ELEMENT_BINDING=$(docker port element-web 80/tcp | head -n 1 | cut -d':' -f1)
    echo "Element Web текущий bind: $ELEMENT_BINDING"
  else
    echo "Element Web не запущен"
  fi
  
  if docker ps | grep -q "synapse-admin"; then
    ADMIN_BINDING=$(docker port synapse-admin 80/tcp | head -n 1 | cut -d':' -f1)
    echo "Synapse Admin текущий bind: $ADMIN_BINDING"
  else
    echo "Synapse Admin не запущен"
  fi
}

# Функция для проверки доменов на безопасность
check_domain_security() {
  local matrix_domain=$1
  local element_domain=$2
  
  if [ "$matrix_domain" = "$element_domain" ]; then
    echo "⚠️  ВНИМАНИЕ: Использование одного домена для Matrix и Element может создать уязвимости XSS!"
    echo "Рекомендуется использовать разные поддомены:"
    echo "  Matrix: matrix.example.com"
    echo "  Element: element.example.com"
    read -p "Продолжить с одним доменом? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
      return 1
    fi
  fi
  return 0
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

# Функция для создания улучшенного Caddyfile с кэшированием и well-known
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
# Версия 5.3 - Ubuntu 24.04 LTS Compatible
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