#!/bin/bash

# Matrix Synapse Core Installation Module
# Использует common_lib.sh для улучшенного логирования и обработки ошибок
# Версия: 2.0.0

# Настройки модуля
LIB_NAME="Matrix Synapse Core Installer"
LIB_VERSION="2.0.0"
MODULE_NAME="core_install"

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../common/common_lib.sh"

if [ ! -f "$COMMON_LIB" ]; then
    echo "ОШИБКА: Не найдена библиотека common_lib.sh по пути: $COMMON_LIB"
    exit 1
fi

source "$COMMON_LIB"

# Конфигурационные переменные
CONFIG_DIR="/opt/matrix-install"
SYNAPSE_CONFIG_DIR="/etc/matrix-synapse"
SYNAPSE_DATA_DIR="/var/lib/matrix-synapse"
POSTGRES_VERSION="15"
MATRIX_VERSION_MIN="1.93.0"

# Функция проверки системных требований
check_system_requirements() {
    print_header "ПРОВЕРКА СИСТЕМНЫХ ТРЕБОВАНИЙ" "$BLUE"
    
    log "INFO" "Проверка системных требований для Matrix Synapse..."
    
    # Проверка прав root
    check_root || return 1
    
    # Проверка архитектуры
    local arch=$(uname -m)
    if [[ ! "$arch" =~ ^(x86_64|amd64|arm64|aarch64)$ ]]; then
        log "ERROR" "Неподдерживаемая архитектура: $arch"
        return 1
    fi
    log "INFO" "Архитектура: $arch - поддерживается"
    
    # Проверка доступной памяти (минимум 1GB)
    local memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local memory_gb=$((memory_kb / 1024 / 1024))
    
    if [ "$memory_gb" -lt 1 ]; then
        log "WARN" "Недостаточно оперативной памяти: ${memory_gb}GB (рекомендуется минимум 1GB)"
        if ! ask_confirmation "Продолжить установку с недостаточным объемом памяти?"; then
            return 1
        fi
    else
        log "INFO" "Оперативная память: ${memory_gb}GB - достаточно"
    fi
    
    # Проверка дискового пространства (минимум 10GB)
    local disk_free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$disk_free_gb" -lt 10 ]; then
        log "WARN" "Недостаточно свободного места: ${disk_free_gb}GB (рекомендуется минимум 10GB)"
        if ! ask_confirmation "Продолжить установку с недостаточным свободным местом?"; then
            return 1
        fi
    else
        log "INFO" "Свободное место на диске: ${disk_free_gb}GB - достаточно"
    fi
    
    # Проверка подключения к интернету
    check_internet || return 1
    
    # Проверка зависимостей
    check_dependencies "curl" "wget" "lsb-release" "gpg" || {
        log "INFO" "Установка базовых зависимостей..."
        apt update && apt install -y curl wget lsb-release gpg apt-transport-https
    }
    
    log "SUCCESS" "Системные требования проверены"
    return 0
}

# Функция получения доменного имени
get_matrix_domain() {
    local domain_file="$CONFIG_DIR/domain"
    
    if [ -f "$domain_file" ]; then
        MATRIX_DOMAIN=$(cat "$domain_file")
        log "INFO" "Найден сохранённый домен: $MATRIX_DOMAIN"
        
        if ask_confirmation "Использовать сохранённый домен $MATRIX_DOMAIN?"; then
            return 0
        fi
    fi
    
    print_header "НАСТРОЙКА ДОМЕННОГО ИМЕНИ" "$CYAN"
    
    while true; do
        read -p "$(safe_echo "${YELLOW}Введите доменное имя Matrix сервера (например, matrix.example.com): ${NC}")" MATRIX_DOMAIN
        
        # Валидация доменного имени
        if [[ ! "$MATRIX_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            log "ERROR" "Неверный формат доменного имени"
            continue
        fi
        
        if [ ${#MATRIX_DOMAIN} -gt 253 ]; then
            log "ERROR" "Доменное имя слишком длинное (максимум 253 символа)"
            continue
        fi
        
        log "INFO" "Доменное имя: $MATRIX_DOMAIN"
        if ask_confirmation "Подтвердить доменное имя?"; then
            break
        fi
    done
    
    # Сохранение доменного имени
    mkdir -p "$CONFIG_DIR"
    echo "$MATRIX_DOMAIN" > "$domain_file"
    log "SUCCESS" "Доменное имя сохранено в $domain_file"
    
    return 0
}

# Функция обновления системы
update_system() {
    print_header "ОБНОВЛЕНИЕ СИСТЕМЫ" "$BLUE"
    
    log "INFO" "Обновление списка пакетов..."
    if ! apt update; then
        log "ERROR" "Ошибка обновления списка пакетов"
        return 1
    fi
    
    log "INFO" "Обновление установленных пакетов..."
    if ! apt upgrade -y; then
        log "WARN" "Не удалось обновить все пакеты, продолжаем..."
    fi
    
    log "INFO" "Установка необходимых системных пакетов..."
    local packages=(
        "curl"
        "wget" 
        "git"
        "lsb-release"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "python3"
        "python3-pip"
        "pwgen"
        "openssl"
    )
    
    if ! apt install -y "${packages[@]}"; then
        log "ERROR" "Ошибка установки системных пакетов"
        return 1
    fi
    
    log "SUCCESS" "Система обновлена и базовые пакеты установлены"
    return 0
}

# Функция добавления репозитория Matrix
add_matrix_repository() {
    print_header "ДОБАВЛЕНИЕ РЕПОЗИТОРИЯ MATRIX" "$CYAN"
    
    log "INFO" "Добавление официального репозитория Matrix.org..."
    
    # Скачивание и установка ключа репозитория
    local keyring_path="/usr/share/keyrings/matrix-org-archive-keyring.gpg"
    local repo_url="https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg"
    
    if ! download_file "$repo_url" "$keyring_path"; then
        log "ERROR" "Не удалось скачать ключ репозитория Matrix"
        return 1
    fi
    
    # Добавление репозитория
    local codename=$(lsb_release -cs)
    local repo_line="deb [signed-by=$keyring_path] https://packages.matrix.org/debian/ $codename main"
    
    echo "$repo_line" | tee /etc/apt/sources.list.d/matrix-org.list > /dev/null
    log "INFO" "Добавлен репозиторий: $repo_line"
    
    # Обновление списка пакетов
    log "INFO" "Обновление списка пакетов с новым репозиторием..."
    if ! apt update; then
        log "ERROR" "Ошибка обновления списка пакетов после добавления репозитория"
        return 1
    fi
    
    log "SUCCESS" "Репозиторий Matrix успешно добавлен"
    return 0
}

# Функция установки PostgreSQL
install_postgresql() {
    print_header "УСТАНОВКА POSTGRESQL" "$BLUE"
    
    log "INFO" "Установка PostgreSQL $POSTGRES_VERSION..."
    
    # Проверка, не установлен ли уже PostgreSQL
    if systemctl is-active --quiet postgresql; then
        log "INFO" "PostgreSQL уже установлен и запущен"
        local pg_version=$(sudo -u postgres psql -t -c "SELECT version();" | head -1 | grep -o '[0-9]\+\.[0-9]\+')
        log "INFO" "Версия PostgreSQL: $pg_version"
        return 0
    fi
    
    # Установка PostgreSQL
    if ! apt install -y postgresql postgresql-contrib; then
        log "ERROR" "Ошибка установки PostgreSQL"
        return 1
    fi
    
    # Запуск и включение автозапуска
    if ! systemctl enable postgresql; then
        log "ERROR" "Ошибка включения автозапуска PostgreSQL"
        return 1
    fi
    
    if ! systemctl start postgresql; then
        log "ERROR" "Ошибка запуска PostgreSQL"
        return 1
    fi
    
    # Проверка запуска
    if ! check_service postgresql; then
        log "ERROR" "PostgreSQL не запустился корректно"
        return 1
    fi
    
    log "SUCCESS" "PostgreSQL установлен и запущен"
    return 0
}

# Функция создания базы данных для Synapse
create_synapse_database() {
    print_header "СОЗДАНИЕ БАЗЫ ДАННЫХ SYNAPSE" "$CYAN"
    
    log "INFO" "Создание пользователя и базы данных для Synapse..."
    
    # Генерация безопасного пароля
    local db_password=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    # Проверка существования пользователя
    if sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='synapse_user'" | grep -q 1; then
        log "INFO" "Пользователь synapse_user уже существует"
    else
        log "INFO" "Создание пользователя synapse_user..."
        if ! sudo -u postgres createuser --no-createdb --no-createrole --no-superuser synapse_user; then
            log "ERROR" "Ошибка создания пользователя synapse_user"
            return 1
        fi
    fi
    
    # Установка пароля для пользователя
    log "INFO" "Установка пароля для пользователя synapse_user..."
    if ! sudo -u postgres psql -c "ALTER USER synapse_user WITH PASSWORD '$db_password';"; then
        log "ERROR" "Ошибка установки пароля для пользователя"
        return 1
    fi
    
    # Проверка существования базы данных
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw synapse_db; then
        log "INFO" "База данных synapse_db уже существует"
    else
        log "INFO" "Создание базы данных synapse_db..."
        if ! sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse_user synapse_db; then
            log "ERROR" "Ошибка создания базы данных"
            return 1
        fi
    fi
    
    # Сохранение конфигурации базы данных
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/database.conf" <<EOF
# Конфигурация базы данных PostgreSQL для Matrix Synapse
DB_NAME=synapse_db
DB_USER=synapse_user
DB_PASSWORD=$db_password
DB_HOST=localhost
DB_PORT=5432
EOF
    
    chmod 600 "$CONFIG_DIR/database.conf"
    log "INFO" "Конфигурация базы данных сохранена в $CONFIG_DIR/database.conf"
    
    # Экспорт для использования в других функциях
    export DB_PASSWORD="$db_password"
    
    log "SUCCESS" "База данных для Synapse создана и настроена"
    return 0
}

# Функция установки Matrix Synapse
install_matrix_synapse() {
    print_header "УСТАНОВКА MATRIX SYNAPSE" "$GREEN"
    
    log "INFO" "Установка Matrix Synapse из официального репозитория..."
    
    # Установка Synapse
    if ! apt install -y matrix-synapse-py3; then
        log "ERROR" "Ошибка установки Matrix Synapse"
        return 1
    fi
    
    # Проверка установленной версии
    local installed_version=$(dpkg -l | grep matrix-synapse-py3 | awk '{print $3}' | cut -d'-' -f1)
    log "INFO" "Установлена версия Synapse: $installed_version"
    
    # Проверка минимальной версии
    if ! version_compare "$installed_version" "$MATRIX_VERSION_MIN"; then
        log "WARN" "Установленная версия Synapse ($installed_version) старше рекомендуемой ($MATRIX_VERSION_MIN)"
    fi
    
    log "SUCCESS" "Matrix Synapse установлен"
    return 0
}

# Функция сравнения версий
version_compare() {
    local version1="$1"
    local version2="$2"
    
    # Простое сравнение версий (без учета pre-release)
    if [ "$(printf '%s\n' "$version1" "$version2" | sort -V | head -n1)" = "$version2" ]; then
        return 0  # version1 >= version2
    else
        return 1  # version1 < version2
    fi
}

# Функция создания базовой конфигурации Synapse
create_synapse_config() {
    print_header "СОЗДАНИЕ КОНФИГУРАЦИИ SYNAPSE" "$CYAN"
    
    log "INFO" "Создание базовой конфигурации Matrix Synapse..."
    
    # Создание директорий
    mkdir -p "$SYNAPSE_CONFIG_DIR/conf.d"
    mkdir -p "$SYNAPSE_DATA_DIR"
    
    # Чтение конфигурации базы данных
    if [ -f "$CONFIG_DIR/database.conf" ]; then
        source "$CONFIG_DIR/database.conf"
    else
        log "ERROR" "Конфигурация базы данных не найдена"
        return 1
    fi
    
    # Генерация секретов
    local registration_secret=$(openssl rand -hex 32)
    local macaroon_secret=$(openssl rand -hex 32)
    local form_secret=$(openssl rand -hex 32)
    
    # Настройка bind_addresses в зависимости от типа сервера
    local bind_addresses
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            # Для серверов за NAT слушаем на всех интерфейсах
            bind_addresses="['0.0.0.0']"
            log "INFO" "Настройка для сервера за NAT (bind: 0.0.0.0)"
            ;;
        *)
            # Для облачных серверов только localhost
            bind_addresses="['127.0.0.1']"
            log "INFO" "Настройка для облачного сервера (bind: 127.0.0.1)"
            ;;
    esac
    
    # Создание основной конфигурации сервера
    log "INFO" "Создание основной конфигурации homeserver.yaml..."
    cat > "$SYNAPSE_CONFIG_DIR/homeserver.yaml" <<EOF
# Matrix Synapse Configuration
# Generated by Matrix Setup Tool v2.0
# Server Type: $SERVER_TYPE
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Основные настройки сервера
server_name: "$MATRIX_DOMAIN"
pid_file: $SYNAPSE_DATA_DIR/homeserver.pid
web_client_location: https://$ELEMENT_DOMAIN

# Сетевые настройки
listeners:
  # Client/Federation API
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: $bind_addresses
    resources:
      - names: [client, federation]
        compress: false

  # Federation API (альтернативный порт)
  - port: 8448
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: $bind_addresses
    resources:
      - names: [federation]
        compress: false

# Директории данных
media_store_path: "$SYNAPSE_DATA_DIR/media_store"
signing_key_path: "$SYNAPSE_CONFIG_DIR/$MATRIX_DOMAIN.signing.key"
trusted_key_servers:
  - server_name: "matrix.org"

# Конфигурационные файлы
log_config: "$SYNAPSE_CONFIG_DIR/log.yaml"

# Включение конфигураций из conf.d
include_files:
  - "$SYNAPSE_CONFIG_DIR/conf.d/*.yaml"

# Секреты безопасности
macaroon_secret_key: "$macaroon_secret"
form_secret: "$form_secret"

# Регистрация (по умолчанию отключена)
enable_registration: false

# Федерация (по умолчанию включена)
federation_domain_whitelist: []

# Настройки производительности
event_cache_size: "10K"

# Метрики
enable_metrics: false
report_stats: false

# Настройки медиа в зависимости от типа сервера
max_upload_size: "50M"
max_image_pixels: "32M"
dynamic_thumbnails: true

# URL превью
url_preview_enabled: true
url_preview_ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'

# Настройки для типа сервера
$(case "$SERVER_TYPE" in
    "proxmox"|"home_server"|"docker"|"openvz")
        cat <<'EOFLOCAL'
# Настройки для локального/домашнего сервера
federation_ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'

# Разрешаем приватные IP для локальной среды (раскомментировать при необходимости)
# federation_ip_range_whitelist:
#   - '192.168.0.0/16'
#   - '10.0.0.0/8'
#   - '172.16.0.0/12'
EOFLOCAL
        ;;
    *)
        cat <<'EOFCLOUD'
# Настройки для облачного сервера
federation_ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'
EOFCLOUD
        ;;
esac)
EOF
    
    # Создание конфигурации базы данных
    log "INFO" "Создание конфигурации базы данных..."
    cat > "$SYNAPSE_CONFIG_DIR/conf.d/database.yaml" <<EOF
# Конфигурация PostgreSQL базы данных
database:
  name: psycopg2
  args:
    user: $DB_USER
    password: $DB_PASSWORD
    database: $DB_NAME
    host: $DB_HOST
    port: $DB_PORT
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3
EOF
    
    # Создание конфигурации регистрации
    log "INFO" "Создание конфигурации регистрации..."
    cat > "$SYNAPSE_CONFIG_DIR/conf.d/registration.yaml" <<EOF
# Настройки регистрации и аутентификации
registration_shared_secret: "$registration_secret"
enable_registration: false
registration_requires_token: false

# Политика паролей
password_config:
  enabled: true
  policy:
    minimum_length: 8
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# Настройки rate limiting
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
  failed_attempts:
    per_second: 0.17
    burst_count: 3
EOF
    
    # Создание дополнительной конфигурации безопасности для типа сервера
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            log "INFO" "Создание конфигурации безопасности для локального сервера..."
            cat > "$SYNAPSE_CONFIG_DIR/conf.d/security.yaml" <<EOF
# Настройки безопасности для локального/домашнего сервера
use_presence: true
allow_public_rooms_over_federation: true
allow_public_rooms_without_auth: false

# Менее строгие настройки для локального использования
federation_verify_certificates: true
federation_client_minimum_tls_version: 1.2

# Настройки для домашнего использования
enable_room_list_search: true
block_non_admin_invites: false
EOF
            ;;
        *)
            log "INFO" "Создание конфигурации безопасности для облачного сервера..."
            cat > "$SYNAPSE_CONFIG_DIR/conf.d/security.yaml" <<EOF
# Настройки безопасности для облачного сервера
use_presence: true
allow_public_rooms_over_federation: true
allow_public_rooms_without_auth: false

# Строгие настройки безопасности
federation_verify_certificates: true
federation_client_minimum_tls_version: 1.2

# Защита от спама
enable_room_list_search: false
block_non_admin_invites: false

# Дополнительные ограничения
limit_remote_rooms:
  enabled: false
  complexity: 1.0
  complexity_error: "This room is too complex."
EOF
            ;;
    esac
    
    # Создание конфигурации логирования
    log "INFO" "Создание конфигурации логирования..."
    cat > "$SYNAPSE_CONFIG_DIR/log.yaml" <<EOF
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    file:
        class: logging.handlers.RotatingFileHandler
        formatter: precise
        filename: $SYNAPSE_DATA_DIR/homeserver.log
        maxBytes: 104857600
        backupCount: 5
        encoding: utf8

    console:
        class: logging.StreamHandler
        formatter: precise

loggers:
    synapse.storage.SQL:
        level: WARNING
    
    synapse.federation:
        level: INFO
        
    synapse.http.client:
        level: INFO

root:
    level: INFO
    handlers: [file, console]

disable_existing_loggers: false
EOF
    
    # Сохранение секретов
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/secrets.conf" <<EOF
# Секреты Matrix Synapse
REGISTRATION_SHARED_SECRET="$registration_secret"
MACAROON_SECRET_KEY="$macaroon_secret"
FORM_SECRET="$form_secret"
SERVER_TYPE="$SERVER_TYPE"
BIND_ADDRESSES="$bind_addresses"
EOF
    
    chmod 600 "$CONFIG_DIR/secrets.conf"
    
    # Генерация ключа подписи
    log "INFO" "Генерация ключа подписи сервера..."
    if ! sudo -u matrix-synapse python3 -m synapse.app.homeserver \
        --server-name="$MATRIX_DOMAIN" \
        --config-path="$SYNAPSE_CONFIG_DIR/homeserver.yaml" \
        --generate-keys; then
        log "ERROR" "Ошибка генерации ключей"
        return 1
    fi
    
    # Установка правильных прав доступа
    chown -R matrix-synapse:matrix-synapse "$SYNAPSE_CONFIG_DIR"
    chown -R matrix-synapse:matrix-synapse "$SYNAPSE_DATA_DIR"
    chmod 755 "$SYNAPSE_CONFIG_DIR"
    chmod 750 "$SYNAPSE_DATA_DIR"
    chmod 640 "$SYNAPSE_CONFIG_DIR/conf.d/"*.yaml
    
    log "SUCCESS" "Конфигурация Synapse создана для типа сервера: $SERVER_TYPE"
    return 0
}

# Функция запуска и проверки Synapse
start_and_verify_synapse() {
    print_header "ЗАПУСК И ПРОВЕРКА SYNAPSE" "$GREEN"
    
    log "INFO" "Запуск службы Matrix Synapse..."
    
    # Включение автозапуска
    if ! systemctl enable matrix-synapse; then
        log "ERROR" "Ошибка включения автозапуска Matrix Synapse"
        return 1
    fi
    
    # Запуск службы
    if ! systemctl start matrix-synapse; then
        log "ERROR" "Ошибка запуска Matrix Synapse"
        log "INFO" "Проверка логов: journalctl -u matrix-synapse -n 50"
        return 1
    fi
    
    # Ожидание запуска
    log "INFO" "Ожидание готовности Synapse..."
    local attempts=0
    local max_attempts=30
    
    while [ $attempts -lt $max_attempts ]; do
        if systemctl is-active --quiet matrix-synapse; then
            log "SUCCESS" "Matrix Synapse запущен"
            break
        fi
        
        attempts=$((attempts + 1))
        if [ $attempts -eq $max_attempts ]; then
            log "ERROR" "Matrix Synapse не запустился в течение 30 секунд"
            log "INFO" "Проверьте логи: journalctl -u matrix-synapse -n 50"
            return 1
        fi
        
        log "DEBUG" "Ожидание запуска... ($attempts/$max_attempts)"
        sleep 1
    done
    
    # Проверка HTTP API
    log "INFO" "Проверка HTTP API Synapse..."
    local api_attempts=0
    local max_api_attempts=10
    
    while [ $api_attempts -lt $max_api_attempts ]; do
        if curl -s -f http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
            log "SUCCESS" "HTTP API Synapse доступен"
            break
        fi
        
        api_attempts=$((api_attempts + 1))
        if [ $api_attempts -eq $max_api_attempts ]; then
            log "WARN" "HTTP API Synapse недоступен, но служба запущена"
            log "INFO" "Возможно, Synapse всё ещё инициализируется"
            break
        fi
        
        log "DEBUG" "Ожидание HTTP API... ($api_attempts/$max_api_attempts)"
        sleep 3
    done
    
    # Проверка портов
    log "INFO" "Проверка сетевых портов..."
    if check_port 8008; then
        log "SUCCESS" "Порт 8008 готов для подключений"
    else
        log "WARN" "Порт 8008 может быть недоступен"
    fi
    
    log "SUCCESS" "Matrix Synapse запущен и готов к работе"
    return 0
}

# Функция создания первого администратора
create_admin_user() {
    print_header "СОЗДАНИЕ АДМИНИСТРАТОРА" "$MAGENTA"
    
    if ! systemctl is-active --quiet matrix-synapse; then
        log "ERROR" "Matrix Synapse не запущен. Сначала запустите службу."
        return 1
    fi
    
    log "INFO" "Создание административного пользователя..."
    
    # Чтение секрета регистрации
    if [ -f "$CONFIG_DIR/secrets.conf" ]; then
        source "$CONFIG_DIR/secrets.conf"
    else
        log "ERROR" "Файл секретов не найден"
        return 1
    fi
    
    # Запрос имени пользователя
    while true; do
        read -p "$(safe_echo "${YELLOW}Введите имя администратора (только латинские буквы и цифры): ${NC}")" admin_username
        
        if [[ ! "$admin_username" =~ ^[a-zA-Z0-9._=-]+$ ]]; then
            log "ERROR" "Неверный формат имени пользователя"
            continue
        fi
        
        if [ ${#admin_username} -lt 3 ]; then
            log "ERROR" "Имя пользователя должно содержать минимум 3 символа"
            continue
        fi
        
        break
    done
    
    # Создание пользователя
    log "INFO" "Создание администратора @$admin_username:$MATRIX_DOMAIN..."
    
    if register_new_matrix_user \
        -c "$SYNAPSE_CONFIG_DIR/homeserver.yaml" \
        -u "$admin_username" \
        --admin \
        http://localhost:8008; then
        
        log "SUCCESS" "Административный пользователь создан: @$admin_username:$MATRIX_DOMAIN"
        
        # Сохранение информации об администраторе
        echo "ADMIN_USER=$admin_username" >> "$CONFIG_DIR/secrets.conf"
        
    else
        log "ERROR" "Ошибка создания административного пользователя"
        return 1
    fi
    
    return 0
}

# Функция финальной настройки и проверки
final_setup() {
    print_header "ФИНАЛЬНАЯ НАСТРОЙКА" "$GREEN"
    
    log "INFO" "Выполнение финальных настроек..."
    
    # Настройка файрвола (если установлен ufw)
    if command -v ufw >/dev/null 2>&1; then
        log "INFO" "Настройка правил файрвола..."
        ufw allow 8008/tcp comment "Matrix Synapse HTTP"
        ufw allow 8448/tcp comment "Matrix Synapse Federation"
    fi
    
    # Создание скрипта для быстрого управления
    log "INFO" "Создание скрипта управления..."
    cat > "$CONFIG_DIR/matrix-control.sh" <<'EOF'
#!/bin/bash
# Скрипт управления Matrix Synapse

case "$1" in
    start)
        systemctl start matrix-synapse
        ;;
    stop)
        systemctl stop matrix-synapse
        ;;
    restart)
        systemctl restart matrix-synapse
        ;;
    status)
        systemctl status matrix-synapse
        ;;
    logs)
        journalctl -u matrix-synapse -f
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
EOF
    
    chmod +x "$CONFIG_DIR/matrix-control.sh"
    
    # Создание резервной копии конфигурации
    log "INFO" "Создание резервной копии конфигурации..."
    backup_file "$SYNAPSE_CONFIG_DIR" "synapse-config-initial"
    
    log "SUCCESS" "Финальная настройка завершена"
    return 0
}

# Главная функция установки
main() {
    print_header "MATRIX SYNAPSE УСТАНОВЩИК v2.0" "$GREEN"
    
    log "INFO" "Начало установки Matrix Synapse"
    log "INFO" "Использование библиотеки: $LIB_NAME v$LIB_VERSION"
    
    # Определение типа сервера в самом начале
    load_server_type || return 1
    
    # Выполнение этапов установки
    local steps=(
        "check_system_requirements:Проверка системных требований"
        "get_matrix_domain:Настройка доменного имени"
        "update_system:Обновление системы"
        "add_matrix_repository:Добавление репозитория Matrix"
        "install_postgresql:Установка PostgreSQL"
        "create_synapse_database:Создание базы данных"
        "install_matrix_synapse:Установка Matrix Synapse"
        "create_synapse_config:Создание конфигурации"
        "start_and_verify_synapse:Запуск и проверка Synapse"
        "final_setup:Финальная настройка"
    )
    
    local total_steps=${#steps[@]}
    local current_step=0
    
    for step_info in "${steps[@]}"; do
        current_step=$((current_step + 1))
        local step_func="${step_info%%:*}"
        local step_name="${step_info##*:}"
        
        print_header "ЭТАП $current_step/$total_steps: $step_name" "$CYAN"
        
        if ! $step_func; then
            log "ERROR" "Ошибка на этапе: $step_name"
            log "ERROR" "Установка прервана"
            return 1
        fi
        
        log "SUCCESS" "Этап завершён: $step_name"
        echo
    done
    
    # Вывод итоговой информации
    print_header "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!" "$GREEN"
    
    safe_echo "${GREEN}✅ Matrix Synapse установлен и настроен${NC}"
    safe_echo "${BLUE}📋 Информация об установке:${NC}"
    safe_echo "   ${BOLD}Тип сервера:${NC} $SERVER_TYPE"
    safe_echo "   ${BOLD}Bind адрес:${NC} $BIND_ADDRESS"
    safe_echo "   ${BOLD}Домен сервера:${NC} $MATRIX_DOMAIN"
    safe_echo "   ${BOLD}Конфигурация:${NC} $SYNAPSE_CONFIG_DIR/homeserver.yaml"
    safe_echo "   ${BOLD}Данные:${NC} $SYNAPSE_DATA_DIR"
    safe_echo "   ${BOLD}Логи:${NC} journalctl -u matrix-synapse"
    [[ -n "${PUBLIC_IP:-}" ]] && safe_echo "   ${BOLD}Публичный IP:${NC} $PUBLIC_IP"
    [[ -n "${LOCAL_IP:-}" ]] && safe_echo "   ${BOLD}Локальный IP:${NC} $LOCAL_IP"
    
    echo
    safe_echo "${YELLOW}📝 Следующие шаги:${NC}"
    
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            safe_echo "   ${BLUE}Для сервера за NAT ($SERVER_TYPE):${NC}"
            safe_echo "   1. Настройте reverse proxy (Caddy) на хосте с публичным IP"
            safe_echo "   2. Перенаправьте порты 80, 443, 8448 на этот сервер"
            safe_echo "   3. Настройте DNS записи для домена $MATRIX_DOMAIN"
            safe_echo "   4. Проверьте доступность федерации:"
            safe_echo "      ${CYAN}curl https://federationtester.matrix.org/api/report?server_name=$MATRIX_DOMAIN${NC}"
            ;;
        *)
            safe_echo "   ${BLUE}Для облачного сервера ($SERVER_TYPE):${NC}"
            safe_echo "   1. Настройте reverse proxy (nginx/caddy) для HTTPS"
            safe_echo "   2. Настройте DNS записи для вашего домена"
            safe_echo "   3. Получите SSL сертификат (Let's Encrypt рекомендуется)"
            ;;
    esac
    
    safe_echo "   4. Создайте администратора командой:"
    safe_echo "      ${CYAN}register_new_matrix_user -c $SYNAPSE_CONFIG_DIR/homeserver.yaml http://localhost:8008${NC}"
    safe_echo "   5. Установите Element Web для веб-интерфейса"
    
    echo
    safe_echo "${GREEN}🎉 Matrix Synapse готов к использованию!${NC}"
    
    # Сохранение информации об установке
    set_config_value "$CONFIG_DIR/install.conf" "SYNAPSE_INSTALLED" "true"
    set_config_value "$CONFIG_DIR/install.conf" "INSTALL_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
    set_config_value "$CONFIG_DIR/install.conf" "SERVER_TYPE" "$SERVER_TYPE"
    set_config_value "$CONFIG_DIR/install.conf" "MATRIX_DOMAIN" "$MATRIX_DOMAIN"
    
    # Опция создания администратора
    echo
    if ask_confirmation "Создать административного пользователя сейчас?"; then
        create_admin_user
    fi
    
    return 0
}

# Проверка, вызван ли скрипт напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi