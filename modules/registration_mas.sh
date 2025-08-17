#!/bin/bash

# Matrix Authentication Service (MAS) Setup Module
# Matrix Setup & Management Tool v3.0
# Модуль установки Matrix Authentication Service

# Определение директории скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключение общей библиотеки
if [ -f "${SCRIPT_DIR}/../common/common_lib.sh" ]; then
    source "${SCRIPT_DIR}/../common/common_lib.sh"
else
    echo "ОШИБКА: Не найдена общая библиотека common_lib.sh"
    exit 1
fi

# Настройки модуля
CONFIG_DIR="/opt/matrix-install"
MAS_CONFIG_DIR="/etc/mas"
MAS_CONFIG_FILE="$MAS_CONFIG_DIR/config.yaml"
SYNAPSE_MAS_CONFIG="/etc/matrix-synapse/conf.d/mas.yaml"
HOMESERVER_CONFIG="/etc/matrix-synapse/homeserver.yaml"

# Константы
MAS_USER="matrix-synapse"
MAS_GROUP="matrix-synapse"
MAS_PORT_HOSTING="8080"
MAS_PORT_PROXMOX="8082"
MAS_DB_NAME="mas_db"

# Проверка root прав
check_root

# Загружаем тип сервера при инициализации модуля
load_server_type

# Логируем информацию о среде
log "INFO" "Модуль Matrix Authentication Service загружен"
log "DEBUG" "Тип сервера: ${SERVER_TYPE:-неопределен}"
log "DEBUG" "Bind адрес: ${BIND_ADDRESS:-неопределен}"

# Функция определения порта MAS в зависимости от типа сервера
determine_mas_port() {
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            echo "$MAS_PORT_PROXMOX"
            ;;
        *)
            echo "$MAS_PORT_HOSTING"
            ;;
    esac
}

# Проверка доступности порта для MAS
check_mas_port() {
    local port="$1"
    local alternative_ports=()
    
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            alternative_ports=(8082 8083 8084 8085)
            ;;
        *)
            alternative_ports=(8080 8081 8082 8083)
            ;;
    esac
    
    log "INFO" "Проверка доступности порта $port для MAS..." >&2
    check_port "$port"
    local port_status=$?
    
    if [ $port_status -eq 1 ]; then
        log "WARN" "Порт $port занят, поиск альтернативного..." >&2
        
        for alt_port in "${alternative_ports[@]}"; do
            check_port "$alt_port"
            if [ $? -eq 0 ]; then
                log "SUCCESS" "Найден свободный порт: $alt_port" >&2
                echo "$alt_port"
                return 0
            fi
        done
        
        log "ERROR" "Не удалось найти свободный порт для MAS" >&2
        return 1
    elif [ $port_status -eq 0 ]; then
        log "SUCCESS" "Порт $port свободен" >&2
        echo "$port"
        return 0
    else
        log "WARN" "Не удалось проверить порт (lsof не установлен), продолжаем с портом $port" >&2
        echo "$port"
        return 0
    fi
}

# Проверка зависимостей
check_mas_dependencies() {
    log "INFO" "Проверка зависимостей MAS..."
    
    local dependencies=("curl" "wget" "tar" "openssl" "systemctl")
    local missing_deps=()
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "ERROR" "Отсутствуют зависимости: ${missing_deps[*]}"
        log "INFO" "Установка недостающих пакетов..."
        
        if ! apt update; then
            log "ERROR" "Не удалось обновить список пакетов"
            return 1
        fi
        
        if ! apt install -y "${missing_deps[@]}"; then
            log "ERROR" "Не удалось установить_dependencies"
            return 1
        fi
        
        log "SUCCESS" "Зависимости установлены"
    fi
    
    return 0
}

# Функция для создания правильной конфигурации MAS (исправленная версия)
setup_mas_database() {
    log "INFO" "Настройка базы данных для MAS..."
    
    # Проверяем, что PostgreSQL запущен
    if ! systemctl is-active --quiet postgresql; then
        log "ERROR" "PostgreSQL не запущен"
        return 1
    fi
    
    # Получаем пароль пользователя synapse_user из основной установки Matrix
    local db_password=""
    if [ -f "$CONFIG_DIR/database.conf" ]; then
        db_password=$(grep "DB_PASSWORD=" "$CONFIG_DIR/database.conf" | cut -d'=' -f2 | tr -d '"')
    fi
    
    if [ -z "$db_password" ]; then
        log "ERROR" "Не найден пароль базы данных в $CONFIG_DIR/database.conf"
        log "INFO" "Убедитесь, что основная установка Matrix завершена успешно"
        return 1
    fi
    
    # Проверяем, существует ли пользователь synapse_user (создается в core_install.sh)
    local synapse_user_exists=$(sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='synapse_user'" | grep -c 1)
    
    if [ "$synapse_user_exists" -eq 0 ]; then
        log "ERROR" "Пользователь базы данных 'synapse_user' не существует"
        log "INFO" "Необходимо сначала запустить основную установку Matrix (core_install.sh)"
        log "INFO" "Этот пользователь создается автоматически в процессе основной установки"
        return 1
    fi
    
    log "SUCCESS" "Пользователь базы данных 'synapse_user' найден"
    
    # Проверяем, существует ли база данных mas_db
    local mas_db_exists=$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -w "$MAS_DB_NAME" | wc -l)
    
    if [ "$mas_db_exists" -eq 0 ]; then
        log "INFO" "Создание базы данных $MAS_DB_NAME..."
        
        # Создаем базу данных для MAS с владельцем synapse_user (используем того же пользователя, что и для Synapse)
        if ! sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse_user "$MAS_DB_NAME"; then
            log "ERROR" "Не удалось создать базу данных $MAS_DB_NAME"
            return 1
        fi
        
        log "SUCCESS" "База данных $MAS_DB_NAME создана"
    else
        log "INFO" "База данных $MAS_DB_NAME уже существует"
    fi
    
    # Проверяем подключение к базе данных MAS с пользователем synapse_user
    log "INFO" "Проверка подключения к базе данных MAS..."
    if PGPASSWORD="$db_password" psql -h localhost -U "synapse_user" -d "$MAS_DB_NAME" -c "SELECT 1;" &>/dev/null; then
        log "SUCCESS" "Подключение к базе данных MAS работает"
    else
        log "ERROR" "Не удается подключиться к базе данных MAS"
        log "INFO" "Проверка и предоставление необходимых прав..."
        
        # Даем полные права пользователю synapse_user на базу данных mas_db
        if sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $MAS_DB_NAME TO synapse_user;" 2>/dev/null; then
            log "INFO" "Права на базу данных $MAS_DB_NAME предоставлены пользователю synapse_user"
        fi
        
        # Даем права на схему public если база уже существует  
        if sudo -u postgres psql -d "$MAS_DB_NAME" -c "GRANT ALL ON SCHEMA public TO synapse_user;" 2>/dev/null; then
            log "INFO" "Права на схему public предоставлены"
        fi
        
        # Повторная проверка подключения
        if PGPASSWORD="$db_password" psql -h localhost -U "synapse_user" -d "$MAS_DB_NAME" -c "SELECT 1;" &>/dev/null; then
            log "SUCCESS" "Подключение к базе данных MAS теперь работает"
        else
            log "ERROR" "Подключение к базе данных MAS все еще не работает"
            return 1
        fi
    fi
    
    # Сохраняем информацию о базе данных MAS (используем того же пользователя synapse_user)
    {
        echo "MAS_DB_NAME=\"$MAS_DB_NAME\""
        echo "MAS_DB_USER=\"synapse_user\""
        echo "MAS_DB_PASSWORD=\"$db_password\""
        echo "MAS_DB_URI=\"postgresql://synapse_user:$db_password@localhost/$MAS_DB_NAME\""
    } > "$CONFIG_DIR/mas_database.conf"
    
    log "SUCCESS" "Конфигурация базы данных MAS сохранена (пользователь: synapse_user, база: $MAS_DB_NAME)"
    return 0
}

# Скачивание и установка MAS
download_and_install_mas() {
    log "INFO" "Скачивание Matrix Authentication Service..."
    
    # Определяем архитектуру
    local arch=$(uname -m)
    local mas_binary=""
    
    case "$arch" in
        x86_64)
            mas_binary="mas-cli-x86_64-linux.tar.gz"
            ;;
        aarch64|arm64)
            mas_binary="mas-cli-aarch64-linux.tar.gz"
            ;;
        *)
            log "ERROR" "Неподдерживаемая архитектура: $arch"
            return 1
            ;;
    esac
    
    # URL для скачивания MAS из репозитория element-hq
    local download_url="https://github.com/element-hq/matrix-authentication-service/releases/latest/download/$mas_binary"
    
    # Проверяем подключение к интернету
    if ! check_internet; then
        log "ERROR" "Отсутствует подключение к интернету"
        return 1
    fi
    
    # Скачиваем MAS
    if ! download_file "$download_url" "/tmp/$mas_binary"; then
        log "ERROR" "Ошибка скачивания MAS"
        return 1
    fi
    
    # Создаем временную директорию для извлечения
    local temp_dir=$(mktemp -d)
    
    # Извлекаем архив
    log "INFO" "Извлечение MAS архива..."
    if ! tar -xzf "/tmp/$mas_binary" -C "$temp_dir"; then
        log "ERROR" "Ошибка извлечения архива MAS"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Устанавливаем бинарный файл
    if [ -f "$temp_dir/mas-cli" ]; then
        chmod +x "$temp_dir/mas-cli"
        mv "$temp_dir/mas-cli" /usr/local/bin/mas
        log "SUCCESS" "Бинарный файл MAS установлен"
    else
        log "ERROR" "Бинарный файл mas-cli не найден в архиве"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Копируем дополнительные файлы если они есть
    if [ -d "$temp_dir/share" ]; then
        mkdir -p /usr/local/share/mas-cli
        cp -r "$temp_dir/share"/* /usr/local/share/mas-cli/
        log "INFO" "Дополнительные файлы MAS скопированы"
    fi
    
    # Удаляем временные файлы
    rm -f "/tmp/$mas_binary"
    rm -rf "$temp_dir"
    
    # Проверяем установку
    if mas --version >/dev/null 2>&1; then
        local mas_version=$(mas --version | head -1)
        log "SUCCESS" "Matrix Authentication Service установлен: $mas_version"
    else
        log "ERROR" "Установка MAS завершилась с ошибкой"
        return 1
    fi
    
    return 0
}

# Создание пользователя для MAS если не существует
create_mas_user() {
    log "INFO" "Проверка системного пользователя для MAS..."
    
    # Проверяем, существует ли пользователь matrix-synapse
    if id "$MAS_USER" &>/dev/null; then
        log "INFO" "Системный пользователь $MAS_USER уже существует"
        return 0
    fi
    
    log "INFO" "Создание системного пользователя $MAS_USER..."
    
    # Создаем группу matrix-synapse если не существует
    if ! getent group "$MAS_GROUP" &>/dev/null; then
        if ! groupadd --system "$MAS_GROUP"; then
            log "ERROR" "Не удалось создать группу $MAS_GROUP"
            return 1
        fi
        log "INFO" "Группа $MAS_GROUP создана"
    fi
    
    # Создаем пользователя matrix-synapse
    if ! useradd --system \
                 --no-create-home \
                 --shell /bin/false \
                 --gid "$MAS_GROUP" \
                 --comment "Matrix Authentication Service" \
                 "$MAS_USER"; then
        log "ERROR" "Не удалось создать пользователя $MAS_USER"
        return 1
    fi
    
    log "SUCCESS" "Системный пользователь $MAS_USER создан"
    return 0
}

# Генерация конфигурации MAS (полностью исправленная версия)
generate_mas_config() {
    local mas_port="$1"
    local matrix_domain="$2"
    local mas_secret="$3"
    local db_uri="$4"
    
    log "INFO" "Генерация конфигурации MAS..."
    
    # Создаем системного пользователя для MAS если нужно
    if ! create_mas_user; then
        return 1
    fi
    
    # Создаем директории
    mkdir -p "$MAS_CONFIG_DIR"
    mkdir -p /var/lib/mas
    
    # Определяем публичную базу и issuer в зависимости от типа сервера
    local mas_public_base
    local mas_issuer
    
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            mas_public_base="https://$matrix_domain"
            mas_issuer="https://$matrix_domain"
            log "INFO" "Домашний сервер: MAS будет доступен через reverse proxy"
            ;;
        *)
            mas_public_base="https://auth.$matrix_domain"
            mas_issuer="https://auth.$matrix_domain"
            log "INFO" "Облачный хостинг: MAS получит отдельный поддомен"
            ;;
    esac
    
    # КРИТИЧЕСКАЯ ПРОВЕРКА: убеждаемся, что URI содержит правильное имя базы данных
    local expected_db="mas_db"
    local config_db=$(echo "$db_uri" | sed 's|.*@localhost/||' | sed 's|?.*||')
    
    if [ "$config_db" != "$expected_db" ]; then
        log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: URI содержит неправильное имя базы данных: '$config_db' (ожидается: '$expected_db')"
        log "ERROR" "URI: $(echo "$db_uri" | sed 's/:[^:]*@/:***@/')"  # Скрываем пароль
        return 1
    fi
    
    log "SUCCESS" "URI содержит правильное имя базы данных: $config_db"
    
    # Создаем ИСПРАВЛЕННУЮ конфигурацию с правильным URI базы данных
    log "INFO" "Создание конфигурации MAS с правильным URI базы данных..."
    cat > "$MAS_CONFIG_FILE" <<EOF
# Matrix Authentication Service Configuration - ИСПРАВЛЕНО
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Type: ${SERVER_TYPE:-hosting}
# Port: $mas_port
# Database: $expected_db (ИСПРАВЛЕНО!)

http:
  public_base: "$mas_public_base"
  issuer: "$mas_issuer"
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
      binds:
        - address: "$BIND_ADDRESS:$mas_port"
      proxy_protocol: false

# ИСПРАВЛЕННАЯ СЕКЦИЯ DATABASE - ИСПОЛЬЗУЕМ ПРАВИЛЬНОЕ ИМЯ БАЗЫ ДАННЫХ
database:
  uri: "$db_uri"

matrix:
  homeserver: "$matrix_domain"
  secret: "$mas_secret"
  endpoint: "http://localhost:8008"

secrets:
  encryption: "$(openssl rand -hex 32)"
  keys:
    - kid: "$(date +%s | sha256sum | cut -c1-8)"
      key: |
$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 | sed 's/^/        /')

clients:
  - client_id: "0000000000000000000SYNAPSE"
    client_auth_method: client_secret_basic
    client_secret: "$mas_secret"

passwords:
  enabled: true
  schemes:
    - version: 1
      algorithm: bcrypt
      unicode_normalization: true
    - version: 2
      algorithm: argon2id

account:
  email_change_allowed: true
  displayname_change_allowed: true
  password_registration_enabled: false
  password_change_allowed: true
  password_recovery_enabled: false
  account_deactivation_allowed: true
  registration_token_required: false

experimental:
  access_token_ttl: 300
  compat_token_ttl: 300
EOF

    # Пытаемся сгенерировать конфигурацию с помощью mas config generate для получения лучших секретов
    log "INFO" "Генерация дополнительных секретов MAS..."
    
    local base_config_generated=false
    if mas config generate > /tmp/mas_base_config.yaml 2>/dev/null; then
        base_config_generated=true
        log "SUCCESS" "Базовая конфигурация сгенерирована командой 'mas config generate'"
        
        # Извлекаем ТОЛЬКО секрет шифрования из сгенерированной конфигурации
        local encryption_secret=$(grep -A 10 "^secrets:" /tmp/mas_base_config.yaml | grep "encryption:" | cut -d'"' -f2 2>/dev/null)
        if [ -n "$encryption_secret" ]; then
            log "INFO" "Использование секрета шифрования из сгенерированной конфигурации"
            sed -i "s/encryption: \".*\"/encryption: \"$encryption_secret\"/" "$MAS_CONFIG_FILE"
        fi
        
        # Извлекаем ключи более безопасным способом
        local temp_keys_file="/tmp/mas_keys_$$"
        if sed -n '/^  keys:/,/^[^ ]/p' /tmp/mas_base_config.yaml | sed '$d' > "$temp_keys_file" 2>/dev/null; then
            if [ -s "$temp_keys_file" ]; then
                log "INFO" "Использование ключей из сгенерированной конфигурации"
                
                # Создаем резервную копию конфигурации
                cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup"
                
                # Создаем новый файл с заменой секции keys
                {
                    # Все до секции keys
                    sed '/^  keys:/,$d' "$MAS_CONFIG_FILE"
                    # Секция keys из сгенерированной конфигурации
                    cat "$temp_keys_file"
                    # Все после секции keys (если есть)
                    sed -n '/^  keys:/,/^[^ ]/p' "$MAS_CONFIG_FILE" | sed '1,/^[^ ]/d' 2>/dev/null || true
                } > "$MAS_CONFIG_FILE.new"
                
                # Проверяем, что новый файл корректный
                if [ -s "$MAS_CONFIG_FILE.new" ] && grep -q "database:" "$MAS_CONFIG_FILE.new" && grep -q "$db_uri" "$MAS_CONFIG_FILE.new"; then
                    mv "$MAS_CONFIG_FILE.new" "$MAS_CONFIG_FILE"
                    log "SUCCESS" "Ключи из сгенерированной конфигурации применены"
                else
                    log "WARN" "Не удалось применить ключи, оставляем сгенерированные вручную"
                    mv "$MAS_CONFIG_FILE.backup" "$MAS_CONFIG_FILE"
                    rm -f "$MAS_CONFIG_FILE.new"
                fi
                
                rm -f "$MAS_CONFIG_FILE.backup"
            fi
        fi
        
        rm -f "$temp_keys_file"
        rm -f /tmp/mas_base_config.yaml
    else
        log "WARN" "Не удалось использовать 'mas config generate', используем конфигурацию созданную вручную"
    fi
    
    # Устанавливаем права доступа
    chown -R "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_DIR"
    chown -R "$MAS_USER:$MAS_GROUP" /var/lib/mas
    chmod 600 "$MAS_CONFIG_FILE"
    
    # КРИТИЧЕСКАЯ ПРОВЕРКА: убеждаемся, что конфигурация создана правильно
    if ! grep -q "^database:" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS повреждена: секция database отсутствует!"
        return 1
    fi
    
    if ! grep -q "$db_uri" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS повреждена: не содержит корректный URI базы данных!"
        return 1
    fi
    
    # Финальная проверка: убеждаемся, что в конфигурации указана правильная база данных
    local final_config_db=$(grep -A 1 "^database:" "$MAS_CONFIG_FILE" | grep "uri:" | sed 's/.*@localhost\///' | sed 's/".*$//' 2>/dev/null)
    if [ "$final_config_db" = "$expected_db" ]; then
        log "SUCCESS" "✅ Конфигурация MAS создана успешно с правильной базой данных: $final_config_db"
        log "INFO" "Конфигурация содержит:"
        log "INFO" "  - Порт: $mas_port"
        log "INFO" "  - Домен: $matrix_domain" 
        log "INFO" "  - База данных: $final_config_db"
        log "INFO" "  - Bind адрес: $BIND_ADDRESS:$mas_port"
    else
        log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: Финальная проверка не прошла!"
        log "ERROR" "Ожидается база данных: $expected_db"
        log "ERROR" "Найдена база данных: $final_config_db"
        log "DEBUG" "Содержимое секции database:"
        grep -A 2 "^database:" "$MAS_CONFIG_FILE" 2>/dev/null || log "ERROR" "Секция database не найдена"
        return 1
    fi
    
    return 0
}

# Создание systemd сервиса для MAS (полностью исправленная версия)
create_mas_systemd_service() {
    log "INFO" "Создание systemd сервиса для MAS..."
    
    cat > /etc/systemd/system/matrix-auth-service.service <<EOF
[Unit]
Description=Matrix Authentication Service
Documentation=https://element-hq.github.io/matrix-authentication-service/
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=$MAS_USER
Group=$MAS_GROUP
# КРИТИЧЕСКИ ВАЖНО: Устанавливаем правильную рабочую директорию
WorkingDirectory=/var/lib/mas
# ВАЖНО: Явно указываем путь к конфигурации 
ExecStart=/usr/local/bin/mas server --config $MAS_CONFIG_FILE
Restart=always
RestartSec=10

# ТОЛЬКО безопасные переменные окружения
Environment=RUST_LOG=info

# НЕ передаем DATABASE_URL или другие проблемные переменные!
# MAS должен читать конфигурацию только из config.yaml

# Безопасность
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/mas $MAS_CONFIG_DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    # Создаем правильную рабочую директорию
    local mas_work_dir="/var/lib/mas"
    mkdir -p "$mas_work_dir"
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir"
    
    # Создаем безопасный .env файл
    cat > "$mas_work_dir/.env" << EOF
# MAS Environment Variables - БЕЗОПАСНАЯ ВЕРСИЯ
# $(date '+%Y-%m-%d %H:%M:%S')

# Только безопасные переменные окружения
RUST_LOG=info

# НЕ указываем DATABASE_URL - пусть читает из config.yaml!
# НЕ указываем MAS_CONFIG - используем --config флаг!
EOF
    
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir/.env"
    chmod 600 "$mas_work_dir/.env"
    
    # Перезагружаем systemd и включаем сервис
    systemctl daemon-reload
    systemctl enable matrix-auth-service
    
    log "SUCCESS" "Systemd сервис создан и включен с правильной рабочей директорией (/var/lib/mas)"
    log "INFO" "Сервис будет запускаться с очищенным окружением и правильными правами доступа"
    return 0
}

# Настройка интеграции Synapse с MAS
configure_synapse_mas_integration() {
    local mas_port="$1"
    local mas_secret="$2"
    
    log "INFO" "Настройка интеграции Synapse с MAS..."
    
    # Создаем конфигурацию для Synapse
    cat > "$SYNAPSE_MAS_CONFIG" <<EOF
# Matrix Authentication Service Integration (MSC3861)
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Type: ${SERVER_TYPE:-hosting}
# MAS Port: $mas_port

# Экспериментальные функции для MSC3861
experimental_features:
  # Matrix Authentication Service интеграция
  msc3861:
    enabled: true
    
    # URL эмитента OIDC (MAS сервер)
    issuer: "http://localhost:$mas_port"
    
    # ID клиента для Synapse в MAS
    client_id: "0000000000000000000SYNAPSE"
    
    # Метод аутентификации клиента
    client_auth_method: client_secret_basic
    
    # Секрет клиента
    client_secret: "$mas_secret"
    
    # Административный токен для API взаимодействия
    admin_token: "$mas_secret"
    
    # URL для управления аккаунтами
    account_management_url: "http://localhost:$mas_port/account/"
    
    # URL для интроспекции токенов
    introspection_endpoint: "http://localhost:$mas_port/oauth2/introspect"

# Отключаем встроенную регистрацию Synapse в пользу MAS
enable_registration: false
disable_msisdn_registration: true

# Современные функции Matrix
experimental_features:
  spaces_enabled: true
  msc3440_enabled: true  # Threading
  msc3720_enabled: true  # Account data
  msc3827_enabled: true  # Filtering
  msc3861_enabled: true  # Matrix Authentication Service
EOF

    log "SUCCESS" "Конфигурация интеграции Synapse с MAS создана"
    return 0
}

# Диагностика и исправление проблем базы данных MAS
fix_mas_database_issues() {
    log "INFO" "Диагностика и исправление проблем базы данных MAS..."
    
    # Проверяем существование конфигурационных файлов
    if [ ! -f "$CONFIG_DIR/mas_database.conf" ]; then
        log "ERROR" "Файл конфигурации базы данных MAS не найден: $CONFIG_DIR/mas_database.conf"
        return 1
    fi
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Конфигурационный файл MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    # Загружаем параметры базы данных
    local db_uri=$(grep "MAS_DB_URI=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    local db_user=$(grep "MAS_DB_USER=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    local db_password=$(grep "MAS_DB_PASSWORD=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    local db_name=$(grep "MAS_DB_NAME=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    
    log "DEBUG" "Параметры базы данных MAS:"
    log "DEBUG" "  URI: $db_uri"
    log "DEBUG" "  Пользователь: $db_user"
    log "DEBUG" "  База данных: $db_name"
    
    # Проверяем секцию database в конфигурации MAS
    if ! grep -q "^database:" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Секция database отсутствует в конфигурации MAS!"
        log "ERROR" "Это критическая ошибка конфигурации"
        return 1
    fi
    
    # Проверяем URI в конфигурации MAS
    local config_uri=$(grep -A 5 "^database:" "$MAS_CONFIG_FILE" | grep "uri:" | sed 's/.*uri: *"//' | sed 's/".*//' 2>/dev/null)
    
    if [ -z "$config_uri" ]; then
        log "ERROR" "URI базы данных не найден в конфигурации MAS"
        log "INFO" "Исправление конфигурации MAS..."
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Добавляем недостающую секцию database
        if ! grep -q "^database:" "$MAS_CONFIG_FILE"; then
            # Если секция database полностью отсутствует, добавляем её после http секции
            sed -i '/^http:/a\\ndatabase:\n  uri: "'"$db_uri"'"' "$MAS_CONFIG_FILE"
        else
            # Если секция database есть, но без uri, добавляем uri
            sed -i '/^database:$/a\  uri: "'"$db_uri"'"' "$MAS_CONFIG_FILE"
        fi
        
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        log "SUCCESS" "Конфигурация MAS исправлена"
        config_uri="$db_uri"
    elif [ "$config_uri" != "$db_uri" ]; then
        log "WARN" "URI в конфигурации MAS не соответствует сохраненному URI"
        log "INFO" "Исправление URI в конфигурации MAS..."
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Исправляем URI
        sed -i "s|uri: \".*\"|uri: \"$db_uri\"|" "$MAS_CONFIG_FILE"
        
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        log "SUCCESS" "URI в конфигурации MAS исправлен"
    fi
    
    # Проверяем существование пользователя PostgreSQL
    local user_exists=$(sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" | grep -c 1)
    
    if [ "$user_exists" -eq 0 ]; then
        log "ERROR" "Пользователь PostgreSQL '$db_user' не существует"
        log "ERROR" "Этот пользователь должен быть создан на этапе основной установки Matrix"
        log "ERROR" "Запустите сначала модуль core_install.sh"
        return 1
    else
        log "SUCCESS" "Пользователь PostgreSQL '$db_user' существует"
    fi
    
    # Проверяем существование базы данных mas_db
    local db_exists=$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -w "$db_name" | wc -l)
    
    if [ "$db_exists" -eq 0 ]; then
        log "ERROR" "База данных '$db_name' не существует"
        log "INFO" "Создание базы данных $db_name..."
        
        if sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner="$db_user" "$db_name"; then
            log "SUCCESS" "База данных $db_name создана"
        else
            log "ERROR" "Не удалось создать базу данных $db_name"
            return 1
        fi
    else
        log "SUCCESS" "База данных '$db_name' существует"
    fi
    
    # Проверяем подключение к базе данных
    log "INFO" "Проверка подключения к базе данных..."
    if PGPASSWORD="$db_password" psql -h localhost -U "$db_user" -d "$db_name" -c "SELECT 1;" &>/dev/null; then
        log "SUCCESS" "Подключение к базе данных работает"
    else
        log "ERROR" "Не удается подключиться к базе данных MAS"
        
        # Проверяем права пользователя
        log "INFO" "Проверка и исправление прав пользователя на базу данных..."
        
        # Даем полные права на базу данных
        if sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $db_name TO \"$db_user\";" 2>/dev/null; then
            log "INFO" "Права на базу данных предоставлены"
        fi
        
        # Даем права на схему public если база уже существует
        if sudo -u postgres psql -d "$db_name" -c "GRANT ALL ON SCHEMA public TO \"$db_user\";" 2>/dev/null; then
            log "INFO" "Права на схему public предоставлены"
        fi
        
        # Повторная проверка подключения
        if PGPASSWORD="$db_password" psql -h localhost -U "$db_user" -d "$db_name" -c "SELECT 1;" &>/dev/null; then
            log "SUCCESS" "Подключение к базе данных теперь работает"
        else
            log "ERROR" "Подключение к базе данных все еще не работает"
            
            # Дополнительная диагностика
            log "DEBUG" "Дополнительная диагностика подключения:"
            log "DEBUG" "  Пользователь: $db_user"
            log "DEBUG" "  База данных: $db_name"
            log "DEBUG" "  Хост: localhost"
            
            # Проверяем, может ли пользователь вообще подключиться к PostgreSQL
            if PGPASSWORD="$db_password" psql -h localhost -U "$db_user" -d postgres -c "SELECT 1;" &>/dev/null; then
                log "DEBUG" "Пользователь может подключиться к PostgreSQL"
            else
                log "DEBUG" "Пользователь НЕ может подключиться к PostgreSQL"
            fi
            
            return 1
        fi
    fi
    
    return 0
}

# Инициализация базы данных MAS (исправленная версия)
initialize_mas_database() {
    log "INFO" "Инициализация базы данных MAS..."
    
    # Проверяем, что пользователь matrix-synapse существует в системе
    if ! id "$MAS_USER" &>/dev/null; then
        log "ERROR" "Системный пользователь $MAS_USER не существует"
        log "ERROR" "Пользователь должен был быть создан на этапе генерации конфигурации"
        return 1
    fi
    
    # КРИТИЧЕСКИ ВАЖНО: Создаем рабочую директорию с правильными правами
    log "INFO" "Создание рабочей директории MAS..."
    local mas_work_dir="/var/lib/mas"
    mkdir -p "$mas_work_dir"
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir"
    
    # Создаем безопасный .env файл (очищенный от проблемных переменных)
    log "INFO" "Создание безопасного .env файла..."
    cat > "$mas_work_dir/.env" << EOF
# MAS Environment Variables - БЕЗОПАСНАЯ ВЕРСИЯ
# $(date '+%Y-%m-%d %H:%M:%S')

# Только безопасные переменные окружения
RUST_LOG=info

# НЕ указываем DATABASE_URL - пусть читает из config.yaml!
# НЕ указываем MAS_CONFIG - используем --config флаг!
EOF
    
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir/.env"
    chmod 600 "$mas_work_dir/.env"
    
    log "SUCCESS" "Рабочая директория и .env файл созданы"
    
    # Выполняем диагностику и исправление проблем БД
    if ! fix_mas_database_issues; then
        log "ERROR" "Не удалось исправить проблемы с базой данных"
        return 1
    fi
    
    # КРИТИЧЕСКИ ВАЖНО: Переходим в рабочую директорию перед выполнением команд MAS
    log "INFO" "Переход в рабочую директорию MAS: $mas_work_dir"
    cd "$mas_work_dir" || {
        log "ERROR" "Не удалось перейти в рабочую директорию $mas_work_dir"
        return 1
    }
    
    # ВАЖНО: Очищаем переменные окружения перед запуском
    log "INFO" "Очистка проблемных переменных окружения..."
    unset DATABASE_URL
    unset MAS_CONFIG
    
    # Проверяем конфигурацию перед миграцией
    log "INFO" "Проверка конфигурации перед миграцией..."
    log "DEBUG" "Рабочая директория: $(pwd)"
    log "DEBUG" "Конфигурационный файл: $MAS_CONFIG_FILE"
    
    # Показываем URI из конфигурации для диагностики
    local config_uri=$(grep -A 1 "^database:" "$MAS_CONFIG_FILE" | grep "uri:" | sed 's/.*uri: *//' | tr -d '"' 2>/dev/null)
    if [ -n "$config_uri" ]; then
        # Скрываем пароль в логах
        local safe_uri=$(echo "$config_uri" | sed 's/:[^:]*@/:***@/')
        log "DEBUG" "URI в конфигурации: $safe_uri"
    else
        log "ERROR" "URI не найден в конфигурации!"
        return 1
    fi
    
    # Выполняем миграции базы данных с очищенным окружением
    log "INFO" "Выполнение миграций базы данных MAS..."
    if sudo -u "$MAS_USER" env -i RUST_LOG=info DATABASE_URL="" /usr/local/bin/mas database migrate --config "$MAS_CONFIG_FILE"; then
        log "SUCCESS" "Миграции базы данных MAS выполнены"
    else
        log "ERROR" "Ошибка выполнения миграций базы данных MAS"
        
        # Дополнительная диагностика
        log "INFO" "Дополнительная диагностика..."
        
        # Показываем содержимое конфигурации (без паролей)
        log "DEBUG" "Конфигурация базы данных в MAS config.yaml:"
        grep -A 2 "^database:" "$MAS_CONFIG_FILE" 2>/dev/null | sed 's/password[^"]*"[^"]*"/password:***/' || log "ERROR" "Секция database не найдена"
        
        # Проверяем права доступа к файлам
        log "DEBUG" "Права доступа к файлам:"
        if [ -f "$MAS_CONFIG_FILE" ]; then
            local file_perms=$(ls -la "$MAS_CONFIG_FILE" 2>/dev/null)
            log "DEBUG" "Config.yaml: $file_perms"
        else
            log "ERROR" "Конфигурационный файл недоступен: $MAS_CONFIG_FILE"
        fi
        
        if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
            local db_file_perms=$(ls -la "$CONFIG_DIR/mas_database.conf" 2>/dev/null)
            log "DEBUG" "Database config: $db_file_perms"
        else
            log "ERROR" "Файл конфигурации БД недоступен: $CONFIG_DIR/mas_database.conf"
        fi
        
        # Проверяем валидность конфигурации
        log "DEBUG" "Проверка валидности конфигурации MAS..."
        if sudo -u "$MAS_USER" env -i RUST_LOG=info /usr/local/bin/mas config check --config "$MAS_CONFIG_FILE" 2>&1 | head -10; then
            log "DEBUG" "Конфигурация прошла проверку"
        else
            log "ERROR" "Конфигурация не прошла проверку"
        fi
        
        # Проверяем подключение к базе данных вручную
        log "DEBUG" "Проверка подключения к базе данных вручную..."
        if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
            local db_password=$(grep "MAS_DB_PASSWORD=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
            local db_name=$(grep "MAS_DB_NAME=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
            
            if [ -n "$db_password" ] && [ -n "$db_name" ]; then
                if PGPASSWORD="$db_password" psql -h localhost -U synapse_user -d "$db_name" -c "SELECT version();" 2>/dev/null | head -1; then
                    log "SUCCESS" "Подключение к PostgreSQL работает"
                else
                    log "ERROR" "Проблема с подключением к PostgreSQL"
                fi
            fi
        fi
        
        return 1
    fi
    
    # Синхронизируем конфигурацию с базой данных
    log "INFO" "Синхронизация конфигурации с базой данных..."
    if sudo -u "$MAS_USER" env -i RUST_LOG=info DATABASE_URL="" /usr/local/bin/mas config sync --config "$MAS_CONFIG_FILE"; then
        log "SUCCESS" "Конфигурация MAS синхронизирована с базой данных"
    else
        log "WARN" "Ошибка синхронизации конфигурации MAS (но миграции выполнены успешно)"
        # Не возвращаем ошибку, так как основная задача (миграции) выполнена
    fi
    
    # Возвращаемся в исходную директорию
    cd - >/dev/null || true
    
    return 0
}

# Основная функция установки MAS
install_matrix_authentication_service() {
    print_header "УСТАНОВКА MATRIX AUTHENTICATION SERVICE" "$GREEN"
    
    # Показываем информацию о режиме установки
    safe_echo "${BOLD}${CYAN}Режим установки для ${SERVER_TYPE:-неопределенного типа сервера}:${NC}"
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            safe_echo "• Домашний сервер/Proxmox режим"
            safe_echo "• MAS порт: $MAS_PORT_PROXMOX (избегает конфликтов)"
            safe_echo "• Bind адрес: $BIND_ADDRESS"
            safe_echo "• Требуется настройка reverse proxy на хосте"
            ;;
        *)
            safe_echo "• Облачный хостинг режим"
            safe_echo "• MAS порт: $MAS_PORT_HOSTING (стандартный)"
            safe_echo "• Bind адрес: $BIND_ADDRESS"
            safe_echo "• Отдельный поддомен auth.domain.com"
            ;;
    esac
    echo
    
    # ПроверяемDependencies
    if ! check_mas_dependencies; then
        return 1
    fi
    
    # Получаем домен сервера
    if [ ! -f "$CONFIG_DIR/domain" ]; then
        log "ERROR" "Домен сервера не настроен. Запустите сначала основную установку Matrix."
        return 1
    fi
    
    local matrix_domain=$(cat "$CONFIG_DIR/domain")
    log "INFO" "Домен Matrix сервера: $matrix_domain"
    
    # Определяем и проверяем порт MAS
    local default_port=$(determine_mas_port)
    local mas_port=$(check_mas_port "$default_port")
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Не удалось найти свободный порт для MAS"
        return 1
    fi
    
    log "INFO" "Использование порта $mas_port для MAS"
    
    # Генерируем секретный ключ для MAS
    local mas_secret=$(openssl rand -hex 32)
    
    # Настраиваем базу данных для MAS
    if ! setup_mas_database; then
        return 1
    fi
    
    # Получаем URI базы данных
    local db_uri=$(grep "MAS_DB_URI=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    
    # Скачиваем и устанавливаем MAS
    if ! download_and_install_mas; then
        return 1
    fi
    
    # Генерируем конфигурацию MAS
    if ! generate_mas_config "$mas_port" "$matrix_domain" "$mas_secret" "$db_uri"; then
        return 1
    fi
    
    # Создаем systemd сервис
    if ! create_mas_systemd_service; then
        return 1
    fi
    
    # Инициализируем базу данных MAS
    if ! initialize_mas_database; then
        return 1
    fi
    
    # Настраиваем интеграцию с Synapse
    if ! configure_synapse_mas_integration "$mas_port" "$mas_secret"; then
        return 1
    fi
    
    # Сохраняем информацию о конфигурации MAS
    {
        echo "# MAS Configuration Info"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "MAS_PORT=\"$mas_port\""
        echo "MAS_SECRET=\"$mas_secret\""
        echo "MAS_SERVER_TYPE=\"${SERVER_TYPE:-hosting}\""
        echo "MAS_BIND_ADDRESS=\"$BIND_ADDRESS:$mas_port\""
        echo "MAS_DOMAIN=\"$matrix_domain\""
        case "${SERVER_TYPE:-hosting}" in
            "proxmox"|"home_server"|"openvz"|"docker")
                echo "MAS_PUBLIC_BASE=\"https://$matrix_domain\""
                echo "MAS_MODE=\"reverse_proxy\""
                ;;
            *)
                echo "MAS_PUBLIC_BASE=\"https://auth.$matrix_domain\""
                echo "MAS_MODE=\"direct\""
                ;;
        esac
    } > "$CONFIG_DIR/mas.conf"
    
    # Запускаем сервис MAS
    log "INFO" "Запуск Matrix Authentication Service..."
    if systemctl start matrix-auth-service; then
        log "SUCCESS" "Matrix Authentication Service запущен"
        
        # Ждем запуска
        sleep 5
        
        # Проверяем статус
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "MAS работает корректно"
            
            # Проверяем доступность API
            local health_url="http://localhost:$mas_port/health"
            if curl -s -f "$health_url" >/dev/null 2>&1; then
                log "SUCCESS" "MAS API доступен на порту $mas_port"
            else
                log "WARN" "MAS API пока недоступен (возможно, еще инициализируется)"
            fi
            
            # Перезагружаем Synapse для применения конфигурации MAS
            log "INFO" "Перезапуск Synapse для применения конфигурации MAS..."
            if systemctl restart matrix-synapse; then
                log "SUCCESS" "Synapse перезапущен с поддержкой MAS"
                
                print_header "УСТАНОВКА MAS ЗАВЕРШЕНА УСПЕШНО" "$GREEN"
                
                safe_echo "${GREEN}🎉 Matrix Authentication Service успешно установлен!${NC}"
                echo
                safe_echo "${BOLD}${BLUE}Конфигурация для ${SERVER_TYPE:-hosting}:${NC}"
                safe_echo "• ✅ MAS сервер запущен на порту $mas_port"
                safe_echo "• ✅ Bind адрес: $BIND_ADDRESS:$mas_port"
                safe_echo "• ✅ База данных: $MAS_DB_NAME"
                safe_echo "• ✅ Synapse настроен для работы с MAS (MSC3861)"
                safe_echo "• ✅ Мобильные приложения Element X теперь поддерживаются"
                safe_echo "• ✅ Современная OAuth2/OIDC аутентификация включена"
                echo
                safe_echo "${BOLD}${BLUE}Проверка работы:${NC}"
                safe_echo "• Статус MAS: ${CYAN}systemctl status matrix-auth-service${NC}"
                safe_echo "• Логи MAS: ${CYAN}journalctl -u matrix-auth-service -f${NC}"
                safe_echo "• Веб-интерфейс: ${CYAN}http://localhost:$mas_port${NC}"
                safe_echo "• Health check: ${CYAN}curl http://localhost:$mas_port/health${NC}"
                safe_echo "• Диагностика: ${CYAN}mas doctor --config $MAS_CONFIG_FILE${NC}"
                echo
                safe_echo "${BOLD}${BLUE}Следующие шаги:${NC}"
                case "${SERVER_TYPE:-hosting}" in
                    "proxmox"|"home_server"|"openvz"|"docker")
                        safe_echo "• ${YELLOW}Настройте reverse proxy на хосте для MAS${NC}"
                        safe_echo "• ${YELLOW}Добавьте маршрутизацию для /_matrix/client/*/login${NC}"
                        safe_echo "• ${YELLOW}Добавьте маршрутизацию для /_matrix/client/*/logout${NC}"
                        safe_echo "• ${YELLOW}Добавьте маршрутизацию для /_matrix/client/*/refresh${NC}"
                        safe_echo "• ${YELLOW}MAS будет доступен по домену: https://$matrix_domain${NC}"
                        ;;
                    *)
                        safe_echo "• ${YELLOW}Настройте DNS для auth.$matrix_domain${NC}"
                        safe_echo "• ${YELLOW}Настройте SSL сертификат для MAS${NC}"
                        safe_echo "• ${YELLOW}MAS будет доступен по адресу: https://auth.$matrix_domain${NC}"
                        ;;
                esac
                echo
                safe_echo "${BOLD}${BLUE}Регистрация пользователей теперь происходит через:${NC}"
                safe_echo "• Element X (мобильное приложение) ✅"
                safe_echo "• Element Web с OAuth2 ✅"
                safe_echo "• Другие современные Matrix клиенты ✅"
                safe_echo "• Веб-интерфейс MAS для управления аккаунтами ✅"
                
            else
                log "ERROR" "Ошибка перезапуска Synapse"
                return 1
            fi
        else
            log "ERROR" "MAS не запустился корректно"
            log "INFO" "Проверьте логи: journalctl -u matrix-auth-service -n 20"
            return 1
        fi
    else
        log "ERROR" "Ошибка запуска Matrix Authentication Service"
        return 1
    fi
    
    return 0
}

# Главная функция установки MAS
main() {
    # Проверяем, что PostgreSQL установлен и запущен
    if ! command -v psql &>/dev/null; then
        log "ERROR" "PostgreSQL не установлен"
        exit 1
    fi
    
    if ! systemctl is-active --quiet postgresql; then
        log "ERROR" "PostgreSQL не запущен"
        exit 1
    fi
    
    # Проверяем, что Synapse установлен
    if ! command -v synctl &>/dev/null; then
        log "ERROR" "Matrix Synapse не установлен"
        exit 1
    fi
    
    # Создаем необходимые директории
    mkdir -p "$CONFIG_DIR"
    
    # Запускаем только установку
    install_matrix_authentication_service
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi