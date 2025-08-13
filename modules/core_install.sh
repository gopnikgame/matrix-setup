#!/bin/bash

# Matrix Synapse Core Installation Module
# Использует common_lib.sh для улучшенного логирования и обработки ошибок
# Версия: 2.0.1

# Настройки модуля
LIB_NAME="Matrix Synapse Core Installer"
LIB_VERSION="2.0.1"
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
    
    # Проверка ТОЛЬКО критически важных зависимостей
    # Остальные пакеты устанавливаем автоматически без проверки
    local critical_commands=("curl" "wget")
    local missing_critical=()
    
    for cmd in "${critical_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_critical+=("$cmd")
        fi
    done
    
    if [ ${#missing_critical[@]} -gt 0 ]; then
        log "INFO" "Установка критически важных зависимостей: ${missing_critical[*]}"
        if ! apt update; then
            log "ERROR" "Ошибка обновления списка пакетов"
            return 1
        fi
        
        if ! apt install -y "${missing_critical[@]}"; then
            log "ERROR" "Ошибка установки критически важных зависимостей"
            return 1
        fi
    fi
    
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
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "python3"
        "python3-pip"
        "pwgen"
        "openssl"
    )
    
    # Добавляем lsb-release только если он нужен для определения кодового имени
    if ! command -v lsb_release >/dev/null 2>&1; then
        packages+=("lsb-release")
        log "INFO" "Добавляем lsb-release для определения версии системы"
    fi
    
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
    
    # Определение кодового имени дистрибутива
    local codename=""
    
    if command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs)
        log "INFO" "Кодовое имя дистрибутива (через lsb_release): $codename"
    elif [ -f /etc/os-release ]; then
        # Альтернативный способ через /etc/os-release
        source /etc/os-release
        codename="${VERSION_CODENAME:-$UBUNTU_CODENAME}"
        
        # Если всё ещё пусто, используем известные кодовые имена на основе ID и VERSION_ID
        if [ -z "$codename" ]; then
            case "$ID" in
                "ubuntu")
                    case "$VERSION_ID" in
                        "20.04") codename="focal" ;;
                        "22.04") codename="jammy" ;;
                        "24.04") codename="noble" ;;
                        *) codename="jammy" ;; # По умолчанию для Ubuntu
                    esac
                    ;;
                "debian")
                    case "$VERSION_ID" in
                        "11") codename="bullseye" ;;
                        "12") codename="bookworm" ;;
                        *) codename="bullseye" ;; # По умолчанию для Debian
                    esac
                    ;;
                *)
                    codename="jammy" # Универсальный fallback
                    ;;
            esac
        fi
        
        log "INFO" "Кодовое имя дистрибутива (через /etc/os-release): $codename"
    else
        # Последний fallback
        codename="jammy"
        log "WARN" "Не удалось определить кодовое имя, используем fallback: $codename"
    fi
    
    # Добавление репозитория
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

# КРИТИЧЕСКИ ВАЖНО: Секрет регистрации для register_new_matrix_user
# Этот секрет должен быть в основном файле, а не в include файлах
registration_shared_secret: "$registration_secret"

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
    
    # Создание конфигурации регистрации (дополнительные настройки)
    log "INFO" "Создание дополнительной конфигурации регистрации..."
    cat > "$SYNAPSE_CONFIG_DIR/conf.d/registration.yaml" <<EOF
# Дополнительные настройки регистрации и аутентификации
# ПРИМЕЧАНИЕ: registration_shared_secret находится в основном homeserver.yaml
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
    
    # Генерация ключа подписи - ИСПРАВЛЕНИЕ ОШИБКИ
    log "INFO" "Генерация ключа подписи сервера..."
    
    # Создаем и устанавливаем права доступа перед генерацией
    chown -R matrix-synapse:matrix-synapse "$SYNAPSE_CONFIG_DIR"
    chown -R matrix-synapse:matrix-synapse "$SYNAPSE_DATA_DIR"
    chmod 755 "$SYNAPSE_CONFIG_DIR"
    chmod 750 "$SYNAPSE_DATA_DIR"
    
    # Проверяем различные способы запуска утилиты
    local generate_command=""
    
    # Способ 1: используем готовую утилиту из пакета (наиболее вероятный)
    if command -v generate_config >/dev/null 2>&1; then
        generate_command="generate_config"
    # Способ 2: используем python модуль через правильный интерпретатор
    elif [ -x "/opt/venvs/matrix-synapse/bin/python" ]; then
        generate_command="/opt/venvs/matrix-synapse/bin/python -m synapse.app.homeserver"
    # Способ 3: стандартная команда synapse
    elif command -v synapse_homeserver >/dev/null 2>&1; then
        generate_command="synapse_homeserver"
    # Способ 4: команда из пакета matrix-synapse-py3
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import synapse" 2>/dev/null; then
        generate_command="python3 -m synapse.app.homeserver"
    # Способ 5: генерируем ключ вручную через openssl
    else
        log "WARN" "Утилита генерации Synapse не найдена, создаем ключ вручную..."
        local signing_key_file="$SYNAPSE_CONFIG_DIR/$MATRIX_DOMAIN.signing.key"
        
        # Генерируем Ed25519 ключ
        if ! openssl genpkey -algorithm Ed25519 -out "$signing_key_file"; then
            log "ERROR" "Ошибка генерации ключа подписи"
            return 1
        fi
        
        # Устанавливаем права доступа
        chown matrix-synapse:matrix-synapse "$signing_key_file"
        chmod 600 "$signing_key_file"
        
        log "SUCCESS" "Ключ подписи создан вручную: $signing_key_file"
        return 0
    fi
    
    # Выполняем генерацию ключей если нашли команду
    if [ -n "$generate_command" ]; then
        log "INFO" "Используем команду: $generate_command"
        
        if ! sudo -u matrix-synapse $generate_command \
            --server-name="$MATRIX_DOMAIN" \
            --config-path="$SYNAPSE_CONFIG_DIR/homeserver.yaml" \
            --generate-keys; then
            
            log "WARN" "Основная команда не сработала, пробуем альтернативный способ..."
            
            # Альтернативный способ - создаем ключ с помощью openssl
            local signing_key_file="$SYNAPSE_CONFIG_DIR/$MATRIX_DOMAIN.signing.key"
            
            if ! openssl genpkey -algorithm Ed25519 -out "$signing_key_file"; then
                log "ERROR" "Ошибка генерации ключа подписи"
                return 1
            fi
            
            chown matrix-synapse:matrix-synapse "$signing_key_file"
            chmod 600 "$signing_key_file"
            
            log "SUCCESS" "Ключ подписи создан альтернативным способом"
        else
            log "SUCCESS" "Ключи сгенерированы успешно"
        fi
    fi
    
    # Финальная установка прав доступа
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
    
    # Проверяем доступность API перед созданием пользователя
    log "INFO" "Проверка доступности Synapse API..."
    local api_attempts=0
    local max_api_attempts=5
    
    while [ $api_attempts -lt $max_api_attempts ]; do
        if curl -s -f http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
            log "SUCCESS" "Synapse API доступен"
            break
        fi
        
        api_attempts=$((api_attempts + 1))
        if [ $api_attempts -eq $max_api_attempts ]; then
            log "ERROR" "Synapse API недоступен после $max_api_attempts попыток"
            log "INFO" "Проверьте логи: journalctl -u matrix-synapse -n 20"
            return 1
        fi
        
        log "DEBUG" "Ожидание API Synapse... ($api_attempts/$max_api_attempts)"
        sleep 2
    done
    
    # Проверяем наличие секрета регистрации в конфигурации
    log "INFO" "Проверка секрета регистрации в конфигурации..."
    if ! grep -q "registration_shared_secret:" "$SYNAPSE_CONFIG_DIR/homeserver.yaml"; then
        log "ERROR" "Секрет регистрации не найден в homeserver.yaml"
        log "INFO" "Попытка восстановления секрета из файла secrets.conf..."
        
        if [ -f "$CONFIG_DIR/secrets.conf" ]; then
            source "$CONFIG_DIR/secrets.conf"
            if [ -n "$REGISTRATION_SHARED_SECRET" ]; then
                log "INFO" "Добавление секрета регистрации в homeserver.yaml..."
                echo "registration_shared_secret: \"$REGISTRATION_SHARED_SECRET\"" >> "$SYNAPSE_CONFIG_DIR/homeserver.yaml"
                
                # Перезапускаем Synapse для применения изменений
                log "INFO" "Перезапуск Synapse для применения изменений..."
                if ! systemctl restart matrix-synapse; then
                    log "ERROR" "Ошибка перезапуска Synapse"
                    return 1
                fi
                
                # Ждем запуска
                sleep 5
            else
                log "ERROR" "Секрет регистрации не найден и в secrets.conf"
                return 1
            fi
        else
            log "ERROR" "Файл secrets.conf не найден"
            return 1
        fi
    fi
    
    # Запрос имени пользователя
    while true; do
        read -p "$(safe_echo "${YELLOW}Введите имя администратора (только латинские буквы и цифры): ${NC}")" admin_username
        
        if [[ ! "$admin_username" =~ ^[a-zA-Z0-9._=-]+$ ]]; then
            log "ERROR" "Неверный формат имени пользователя"
            log "INFO" "Разрешены только: латинские буквы, цифры, точки, подчеркиния, дефисы"
            continue
        fi
        
        if [ ${#admin_username} -lt 3 ]; then
            log "ERROR" "Имя пользователя должно содержать минимум 3 символа"
            continue
        fi
        
        if [ ${#admin_username} -gt 50 ]; then
            log "ERROR" "Имя пользователя слишком длинное (максимум 50 символов)"
            continue
        fi
        
        break
    done
    
    # Создание пользователя с улучшенной обработкой ошибок
    log "INFO" "Создание администратора @$admin_username:$MATRIX_DOMAIN..."
    
    # Проверяем различные варианты команды register_new_matrix_user
    local register_command=""
    
    if command -v register_new_matrix_user >/dev/null 2>&1; then
        register_command="register_new_matrix_user"
    elif [ -x "/opt/venvs/matrix-synapse/bin/register_new_matrix_user" ]; then
        register_command="/opt/venvs/matrix-synapse/bin/register_new_matrix_user"
    else
        log "ERROR" "Команда register_new_matrix_user не найдена"
        log "INFO" "Попробуйте создать администратора вручную:"
        log "INFO" "register_new_matrix_user -c $SYNAPSE_CONFIG_DIR/homeserver.yaml http://localhost:8008"
        return 1
    fi
    
    log "INFO" "Используем команду: $register_command"
    
    # Создаем временный файл для хранения вывода
    local temp_output=$(mktemp)
    
    # Выполняем команду создания пользователя
    if $register_command \
        -c "$SYNAPSE_CONFIG_DIR/homeserver.yaml" \
        -u "$admin_username" \
        --admin \
        http://localhost:8008 > "$temp_output" 2>&1; then
        
        log "SUCCESS" "Административный пользователь создан: @$admin_username:$MATRIX_DOMAIN"
        
        # Сохранение информации об администраторе
        echo "ADMIN_USER=$admin_username" >> "$CONFIG_DIR/secrets.conf"
        
        # Показываем полезную информацию
        echo
        safe_echo "${GREEN}🎉 Администратор успешно создан!${NC}"
        safe_echo "${BLUE}📋 Данные для входа:${NC}"
        safe_echo "   ${BOLD}Пользователь:${NC} @$admin_username:$MATRIX_DOMAIN"
        safe_echo "   ${BOLD}Сервер:${NC} $MATRIX_DOMAIN"
        safe_echo "   ${BOLD}Логин через Element:${NC} https://app.element.io"
        
        # Очищаем временный файл
        rm -f "$temp_output"
        
    else
        log "ERROR" "Ошибка создания административного пользователя"
        
        # Показываем подробности ошибки
        if [ -f "$temp_output" ]; then
            log "DEBUG" "Вывод команды register_new_matrix_user:"
            cat "$temp_output" | while read line; do
                log "DEBUG" "$line"
            done
        fi
        
        # Даем рекомендации по устранению проблем
        echo
        safe_echo "${YELLOW}💡 Попробуйте следующее:${NC}"
        safe_echo "1. ${CYAN}Проверьте статус Synapse:${NC}"
        safe_echo "   systemctl status matrix-synapse"
        safe_echo "2. ${CYAN}Проверьте логи Synapse:${NC}"
        safe_echo "   journalctl -u matrix-synapse -n 20"
        safe_echo "3. ${CYAN}Проверьте доступность API:${NC}"
        safe_echo "   curl http://localhost:8008/_matrix/client/versions"
        safe_echo "4. ${CYAN}Создайте администратора вручную:${NC}"
        safe_echo "   register_new_matrix_user -c $SYNAPSE_CONFIG_DIR/homeserver.yaml http://localhost:8008"
        
        # Очищаем временный файл
        rm -f "$temp_output"
        
        return 1
    fi
    
    return 0
}

# Функция диагностики проблем с регистрацией
diagnose_registration_issues() {
    print_header "ДИАГНОСТИКА ПРОБЛЕМ РЕГИСТРАЦИИ" "$YELLOW"
    
    log "INFO" "Проверка конфигурации регистрации..."
    
    local issues_found=0
    
    # Проверка 1: Наличие секрета регистрации в homeserver.yaml
    echo
    safe_echo "${CYAN}1. Проверка секрета регистрации в homeserver.yaml:${NC}"
    
    if grep -q "registration_shared_secret:" "$SYNAPSE_CONFIG_DIR/homeserver.yaml"; then
        local secret_line=$(grep "registration_shared_secret:" "$SYNAPSE_CONFIG_DIR/homeserver.yaml")
        if [[ "$secret_line" =~ registration_shared_secret:.*[a-zA-Z0-9] ]]; then
            safe_echo "   ${GREEN}✓ Секрет регистрации найден и заполнен${NC}"
        else
            safe_echo "   ${RED}✗ Секрет регистрации пустой${NC}"
            issues_found=$((issues_found + 1))
        fi
    else
        safe_echo "   ${RED}✗ Секрет регистрации НЕ найден в homeserver.yaml${NC}"
        issues_found=$((issues_found + 1))
        
        # Пытаемся восстановить из secrets.conf
        if [ -f "$CONFIG_DIR/secrets.conf" ]; then
            source "$CONFIG_DIR/secrets.conf"
            if [ -n "$REGISTRATION_SHARED_SECRET" ]; then
                safe_echo "   ${YELLOW}💡 Найден секрет в secrets.conf, можно восстановить${NC}"
            fi
        fi
    fi
    
    # Проверка 2: Статус службы Synapse
    echo
    safe_echo "${CYAN}2. Проверка статуса службы Synapse:${NC}"
    
    if systemctl is-active --quiet matrix-synapse; then
        safe_echo "   ${GREEN}✓ Synapse запущен${NC}"
        
        # Проверяем время работы
        local uptime=$(systemctl show matrix-synapse --property=ActiveEnterTimestamp --value)
        safe_echo "   ${BLUE}ℹ Время запуска: $uptime${NC}"
    else
        safe_echo "   ${RED}✗ Synapse НЕ запущен${NC}"
        issues_found=$((issues_found + 1))
    fi
    
    # Проверка 3: Доступность API
    echo
    safe_echo "${CYAN}3. Проверка доступности API:${NC}"
    
    if curl -s -f http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
        safe_echo "   ${GREEN}✓ Client API доступен${NC}"
    else
        safe_echo "   ${RED}✗ Client API недоступен${NC}"
        issues_found=$((issues_found + 1))
    fi
    
    if curl -s -f http://localhost:8008/_synapse/admin/v1/server_version >/dev/null 2>&1; then
        local version=$(curl -s http://localhost:8008/_synapse/admin/v1/server_version | grep -o '"server_version":"[^"]*' | cut -d'"' -f4)
        safe_echo "   ${GREEN}✓ Admin API доступен (версия: ${version:-неизвестна})${NC}"
    else
        safe_echo "   ${RED}✗ Admin API недоступен${NC}"
        issues_found=$((issues_found + 1))
    fi
    
    # Проверка 4: Утилита register_new_matrix_user
    echo
    safe_echo "${CYAN}4. Проверка утилиты register_new_matrix_user:${NC}"
    
    if command -v register_new_matrix_user >/dev/null 2>&1; then
        safe_echo "   ${GREEN}✓ Утилита register_new_matrix_user найдена в PATH${NC}"
        local util_path=$(which register_new_matrix_user)
        safe_echo "   ${BLUE}ℹ Путь: $util_path${NC}"
    elif [ -x "/opt/venvs/matrix-synapse/bin/register_new_matrix_user" ]; then
        safe_echo "   ${GREEN}✓ Утилита найдена в venv: /opt/venvs/matrix-synapse/bin/register_new_matrix_user${NC}"
    else
        safe_echo "   ${RED}✗ Утилита register_new_matrix_user НЕ найдена${NC}"
        issues_found=$((issues_found + 1))
    fi
    
    # Проверка 5: Права доступа к файлам
    echo
    safe_echo "${CYAN}5. Проверка прав доступа к конфигурации:${NC}"
    
    if [ -r "$SYNAPSE_CONFIG_DIR/homeserver.yaml" ]; then
        safe_echo "   ${GREEN}✓ homeserver.yaml читается${NC}"
        local file_owner=$(stat -c '%U:%G' "$SYNAPSE_CONFIG_DIR/homeserver.yaml")
        safe_echo "   ${BLUE}ℹ Владелец: $file_owner${NC}"
    else
        safe_echo "   ${RED}✗ homeserver.yaml не читается${NC}"
        issues_found=$((issues_found + 1))
    fi
    
    # Проверка 6: База данных
    echo
    safe_echo "${CYAN}6. Проверка подключения к базе данных:${NC}"
    
    if systemctl is-active --quiet postgresql; then
        safe_echo "   ${GREEN}✓ PostgreSQL запущен${NC}"
        
        if sudo -u postgres psql -d synapse_db -c "SELECT 1;" >/dev/null 2>&1; then
            safe_echo "   ${GREEN}✓ Подключение к базе synapse_db работает${NC}"
        else
            safe_echo "   ${RED}✗ Ошибка подключения к базе synapse_db${NC}"
            issues_found=$((issues_found + 1))
        fi
    else
        safe_echo "   ${RED}✗ PostgreSQL НЕ запущен${NC}"
        issues_found=$((issues_found + 1))
    fi
    
    # Итоговый отчет
    echo
    if [ $issues_found -eq 0 ]; then
        safe_echo "${GREEN}🎉 Все проверки пройдены! Регистрация должна работать.${NC}"
    else
        safe_echo "${RED}❌ Найдено проблем: $issues_found${NC}"
        echo
        safe_echo "${YELLOW}💡 Рекомендации по устранению:${NC}"
        
        # Даем конкретные рекомендации
        if ! grep -q "registration_shared_secret:" "$SYNAPSE_CONFIG_DIR/homeserver.yaml"; then
            safe_echo "• ${CYAN}Добавить секрет регистрации в homeserver.yaml${NC}"
        fi
        
        if ! systemctl is-active --quiet matrix-synapse; then
            safe_echo "• ${CYAN}Запустить Synapse: systemctl start matrix-synapse${NC}"
        fi
        
        if ! command -v register_new_matrix_user >/dev/null 2>&1; then
            safe_echo "• ${CYAN}Переустановить matrix-synapse-py3 пакет${NC}"
        fi
    fi
    
    return $issues_found
}

# Функция автоматического исправления проблем регистрации
fix_registration_issues() {
    print_header "АВТОМАТИЧЕСКОЕ ИСПРАВЛЕНИЕ ПРОБЛЕМ" "$GREEN"
    
    log "INFO" "Попытка автоматического исправления проблем регистрации..."
    
    local fixes_applied=0
    
    # Исправление 1: Добавление секрета регистрации в homeserver.yaml
    if ! grep -q "registration_shared_secret:" "$SYNAPSE_CONFIG_DIR/homeserver.yaml"; then
        log "INFO" "Добавление секрета регистрации в homeserver.yaml..."
        
        if [ -f "$CONFIG_DIR/secrets.conf" ]; then
            source "$CONFIG_DIR/secrets.conf"
            if [ -n "$REGISTRATION_SHARED_SECRET" ]; then
                # Добавляем секрет в правильное место конфигурации
                sed -i '/^macaroon_secret_key:/a registration_shared_secret: "'"$REGISTRATION_SHARED_SECRET"'"' "$SYNAPSE_CONFIG_DIR/homeserver.yaml"
                log "SUCCESS" "Секрет регистрации добавлен в homeserver.yaml"
                fixes_applied=$((fixes_applied + 1))
            else
                log "WARN" "Секрет регистрации не найден в secrets.conf"
            fi
        else
            log "WARN" "Файл secrets.conf не найден"
        fi
    fi
    
    # Исправление 2: Запуск Synapse если он остановлен
    if ! systemctl is-active --quiet matrix-synapse; then
        log "INFO" "Запуск службы Matrix Synapse..."
        if systemctl start matrix-synapse; then
            log "SUCCESS" "Matrix Synapse запущен"
            fixes_applied=$((fixes_applied + 1))
            
            # Ждем готовности
            sleep 5
        else
            log "ERROR" "Ошибка запуска Matrix Synapse"
        fi
    fi
    
    # Исправление 3: Запуск PostgreSQL если он остановлен
    if ! systemctl is-active --quiet postgresql; then
        log "INFO" "Запуск службы PostgreSQL..."
        if systemctl start postgresql; then
            log "SUCCESS" "PostgreSQL запущен"
            fixes_applied=$((fixes_applied + 1))
        else
            log "ERROR" "Ошибка запуска PostgreSQL"
        fi
    fi
    
    # Исправление 4: Перезапуск Synapse для применения изменений
    if [ $fixes_applied -gt 0 ]; then
        log "INFO" "Перезапуск Synapse для применения изменений..."
        if systemctl restart matrix-synapse; then
            log "SUCCESS" "Synapse перезапущен"
            
            # Ждем готовности API
            log "INFO" "Ожидание готовности API..."
            local api_attempts=0
            local max_attempts=10
            
            while [ $api_attempts -lt $max_attempts ]; do
                if curl -s -f http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
                    log "SUCCESS" "API готов к работе"
                    break
                fi
                
                api_attempts=$((api_attempts + 1))
                sleep 3
            done
        else
            log "ERROR" "Ошибка перезапуска Synapse"
        fi
    fi
    
    echo
    if [ $fixes_applied -gt 0 ]; then
        safe_echo "${GREEN}✅ Применено исправлений: $fixes_applied${NC}"
        safe_echo "${BLUE}💡 Попробуйте создать администратора снова${NC}"
    else
        safe_echo "${YELLOW}⚠️ Автоматические исправления не применены${NC}"
        safe_echo "${BLUE}💡 Возможно, требуется ручное вмешательство${NC}"
    fi
    
    return 0
}

# Экспорт функций для использования в других модулях
export -f create_admin_user
export -f diagnose_registration_issues  
export -f fix_registration_issues

# Основной скрипт установки
clear

# Проверка системных требований
check_system_requirements || exit 1

# Получение доменного имени
get_matrix_domain || exit 1

# Обновление системы
update_system || exit 1

# Добавление репозитория Matrix
add_matrix_repository || exit 1

# Установка PostgreSQL
install_postgresql || exit 1

# Создание базы данных для Synapse
create_synapse_database || exit 1

# Установка Matrix Synapse
install_matrix_synapse || exit 1

# Создание базовой конфигурации Synapse
create_synapse_config || exit 1

# Запуск и проверка Synapse
start_and_verify_synapse || exit 1

# Опция создания администратора
echo
if ask_confirmation "Создать административного пользователя сейчас?"; then
    if ! create_admin_user; then
        echo
        safe_echo "${YELLOW}❌ Не удалось создать администратора автоматически${NC}"
        
        if ask_confirmation "Запустить диагностику проблем регистрации?"; then
            diagnose_registration_issues
            
            echo
            if ask_confirmation "Попытаться автоматически исправить найденные проблемы?"; then
                fix_registration_issues
                
                echo
                if ask_confirmation "Попробовать создать администратора снова?"; then
                    create_admin_user
                fi
            fi
        fi
        
        # Показываем альтернативные способы
        echo
        safe_echo "${BLUE}📝 Альтернативные способы создания администратора:${NC}"
        safe_echo "1. ${CYAN}Ручная команда:${NC}"
        safe_echo "   register_new_matrix_user -c $SYNAPSE_CONFIG_DIR/homeserver.yaml http://localhost:8008"
        safe_echo "2. ${CYAN}Через модуль управления регистрацией:${NC}"
        safe_echo "   ./manager-matrix.sh → Управление регистрацией → Создать администратора"
        safe_echo "3. ${CYAN}После настройки reverse proxy:${NC}"
        safe_echo "   register_new_matrix_user -c $SYNAPSE_CONFIG_DIR/homeserver.yaml https://$MATRIX_DOMAIN"
    fi
else
    echo
    safe_echo "${BLUE}💡 Администратора можно создать позже командой:${NC}"
    safe_echo "   ${CYAN}register_new_matrix_user -c $SYNAPSE_CONFIG_DIR/homeserver.yaml http://localhost:8008${NC}"
fi

log "INFO" "Установка и настройка Matrix Synapse завершены. Если возникли ошибки, проверьте логи и устраните проблемы."
print_footer