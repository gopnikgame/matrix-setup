#!/bin/bash

# Matrix Authentication Service (MAS) Setup Module
# Matrix Setup & Management Tool v3.0
# Модуль установки и настройки Matrix Authentication Service

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
    
    log "INFO" "Проверка доступности порта $port для MAS..."
    check_port "$port"
    local port_status=$?
    
    if [ $port_status -eq 1 ]; then
        log "WARN" "Порт $port занят, поиск альтернативного..."
        
        for alt_port in "${alternative_ports[@]}"; do
            check_port "$alt_port"
            if [ $? -eq 0 ]; then
                log "SUCCESS" "Найден свободный порт: $alt_port"
                echo "$alt_port"
                return 0
            fi
        done
        
        log "ERROR" "Не удалось найти свободный порт для MAS"
        return 1
    elif [ $port_status -eq 0 ]; then
        log "SUCCESS" "Порт $port свободен"
        echo "$port"
        return 0
    else
        log "WARN" "Не удалось проверить порт (lsof не установлен), продолжаем с портом $port"
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
            log "ERROR" "Не удалось установить зависимости"
            return 1
        fi
        
        log "SUCCESS" "Зависимости установлены"
    fi
    
    return 0
}

# Проверка статуса PostgreSQL и создание базы данных для MAS
setup_mas_database() {
    log "INFO" "Настройка базы данных для MAS..."
    
    # Проверяем, что PostgreSQL запущен
    if ! systemctl is-active --quiet postgresql; then
        log "ERROR" "PostgreSQL не запущен"
        return 1
    fi
    
    # Получаем пароль пользователя synapse_user
    local db_password=""
    if [ -f "$CONFIG_DIR/database.conf" ]; then
        db_password=$(grep "DB_PASSWORD=" "$CONFIG_DIR/database.conf" | cut -d'=' -f2 | tr -d '"')
    fi
    
    if [ -z "$db_password" ]; then
        log "ERROR" "Не найден пароль базы данных в $CONFIG_DIR/database.conf"
        return 1
    fi
    
    # Проверяем, существует ли база данных MAS
    local db_exists=$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -w "$MAS_DB_NAME" | wc -l)
    
    if [ "$db_exists" -eq 0 ]; then
        log "INFO" "Создание базы данных $MAS_DB_NAME..."
        
        if ! sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse_user "$MAS_DB_NAME"; then
            log "ERROR" "Не удалось создать базу данных $MAS_DB_NAME"
            return 1
        fi
        
        log "SUCCESS" "База данных $MAS_DB_NAME создана"
    else
        log "INFO" "База данных $MAS_DB_NAME уже существует"
    fi
    
    # Сохраняем информацию о базе данных
    {
        echo "MAS_DB_NAME=\"$MAS_DB_NAME\""
        echo "MAS_DB_USER=\"synapse_user\""
        echo "MAS_DB_PASSWORD=\"$db_password\""
        echo "MAS_DB_URI=\"postgresql://synapse_user:$db_password@localhost/$MAS_DB_NAME\""
    } > "$CONFIG_DIR/mas_database.conf"
    
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

# Генерация конфигурации MAS
generate_mas_config() {
    local mas_port="$1"
    local matrix_domain="$2"
    local mas_secret="$3"
    local db_uri="$4"
    
    log "INFO" "Генерация конфигурации MAS..."
    
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
    
    # Пытаемся сгенерировать конфигурацию с помощью mas config generate
    log "INFO" "Генерация базовой конфигурации MAS..."
    
    local base_config_generated=false
    if mas config generate > /tmp/mas_base_config.yaml 2>/dev/null; then
        base_config_generated=true
        log "SUCCESS" "Базовая конфигурация сгенерирована командой 'mas config generate'"
    else
        log "WARN" "Не удалось использовать 'mas config generate', создаем конфигурацию вручную"
    fi
    
    # Создаем финальную конфигурацию
    cat > "$MAS_CONFIG_FILE" <<EOF
# Matrix Authentication Service Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Type: ${SERVER_TYPE:-hosting}
# Port: $mas_port

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
$(openssl genpkey -algorithm RSA -bits 2048 -pkcs8 | sed 's/^/        /')

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

    # Если базовая конфигурация была сгенерирована, используем её секреты
    if [ "$base_config_generated" = true ]; then
        log "INFO" "Использование секретов из сгенерированной конфигурации..."
        
        # Извлекаем секрет шифрования
        local encryption_secret=$(grep -A 10 "^secrets:" /tmp/mas_base_config.yaml | grep "encryption:" | cut -d'"' -f2)
        if [ -n "$encryption_secret" ]; then
            sed -i "s/encryption: \".*\"/encryption: \"$encryption_secret\"/" "$MAS_CONFIG_FILE"
        fi
        
        # Извлекаем ключи
        if grep -q "keys:" /tmp/mas_base_config.yaml; then
            # Заменяем секцию keys полностью
            sed -i '/^  keys:/,$d' "$MAS_CONFIG_FILE"
            echo "  keys:" >> "$MAS_CONFIG_FILE"
            sed -n '/^  keys:/,/^[^ ]/p' /tmp/mas_base_config.yaml | sed '1d;$d' >> "$MAS_CONFIG_FILE"
        fi
        
        rm -f /tmp/mas_base_config.yaml
    fi
    
    # Устанавливаем права доступа
    chown -R "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_DIR"
    chown -R "$MAS_USER:$MAS_GROUP" /var/lib/mas
    chmod 600 "$MAS_CONFIG_FILE"
    
    log "SUCCESS" "Конфигурация MAS создана"
    return 0
}

# Создание systemd сервиса для MAS
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
ExecStart=/usr/local/bin/mas server --config $MAS_CONFIG_FILE
Restart=always
RestartSec=10
Environment=RUST_LOG=info

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

    # Перезагружаем systemd и включаем сервис
    systemctl daemon-reload
    systemctl enable matrix-auth-service
    
    log "SUCCESS" "Systemd сервис создан и включен"
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

# Инициализация базы данных MAS
initialize_mas_database() {
    log "INFO" "Инициализация базы данных MAS..."
    
    # Выполняем миграции базы данных
    if sudo -u "$MAS_USER" mas database migrate --config "$MAS_CONFIG_FILE"; then
        log "SUCCESS" "Миграции базы данных MAS выполнены"
    else
        log "ERROR" "Ошибка выполнения миграций базы данных MAS"
        return 1
    fi
    
    # Синхронизируем конфигурацию с базой данных
    if sudo -u "$MAS_USER" mas config sync --config "$MAS_CONFIG_FILE"; then
        log "SUCCESS" "Конфигурация MAS синхронизирована с базой данных"
    else
        log "ERROR" "Ошибка синхронизации конфигурации MAS"
        return 1
    fi
    
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
    
    # Проверяем зависимости
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
            
            # Перезапускаем Synapse для применения конфигурации MAS
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

# Проверка статуса MAS
check_mas_status() {
    print_header "СТАТУС MATRIX AUTHENTICATION SERVICE" "$CYAN"
    
    # Проверяем, установлен ли MAS
    if ! command -v mas >/dev/null 2>&1; then
        safe_echo "${RED}❌ Matrix Authentication Service не установлен${NC}"
        safe_echo "${BLUE}💡 Используйте опцию установки MAS${NC}"
        return 1
    fi
    
    # Показываем версию MAS
    local mas_version=$(mas --version 2>/dev/null | head -1)
    safe_echo "${BLUE}ℹ️  Версия MAS: ${mas_version:-неизвестна}${NC}"
    
    # Показываем информацию о сервере
    safe_echo "${BOLD}${CYAN}Конфигурация сервера:${NC}"
    safe_echo "├─ Тип сервера: ${SERVER_TYPE:-неопределен}"
    safe_echo "├─ Bind адрес: ${BIND_ADDRESS:-неопределен}"
    
    # Загружаем сохраненную конфигурацию MAS
    local mas_port=""
    local mas_mode=""
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
        mas_mode=$(grep "MAS_MODE=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
        safe_echo "└─ Настроенный порт MAS: ${mas_port:-неизвестен}"
    else
        safe_echo "└─ Конфигурация MAS не найдена"
    fi
    
    echo
    
    # Проверяем файлы конфигурации
    safe_echo "${BOLD}${CYAN}Конфигурационные файлы:${NC}"
    
    if [ -f "$MAS_CONFIG_FILE" ]; then
        safe_echo "${GREEN}✅ Конфигурация MAS: $MAS_CONFIG_FILE${NC}"
    else
        safe_echo "${RED}❌ Конфигурация MAS не найдена${NC}"
    fi
    
    if [ -f "$SYNAPSE_MAS_CONFIG" ]; then
        safe_echo "${GREEN}✅ Интеграция Synapse-MAS: $SYNAPSE_MAS_CONFIG${NC}"
        
        # Проверяем, включен ли MAS в конфигурации Synapse
        if grep -q "msc3861:" "$SYNAPSE_MAS_CONFIG"; then
            local mas_enabled=$(grep -A 1 "msc3861:" "$SYNAPSE_MAS_CONFIG" | grep "enabled:" | awk '{print $2}')
            if [ "$mas_enabled" = "true" ]; then
                safe_echo "${GREEN}✅ MSC3861 интеграция включена${NC}"
            else
                safe_echo "${RED}❌ MSC3861 интеграция отключена${NC}"
            fi
        fi
    else
        safe_echo "${RED}❌ Интеграция Synapse-MAS не настроена${NC}"
    fi
    
    echo
    
    # Проверяем статус службы MAS
    safe_echo "${BOLD}${CYAN}Статус службы:${NC}"
    
    if systemctl is-active --quiet matrix-auth-service 2>/dev/null; then
        safe_echo "${GREEN}✅ Сервис matrix-auth-service запущен${NC}"
        
        # Проверяем доступность API MAS
        if [ -n "$mas_port" ]; then
            local health_url="http://localhost:$mas_port/health"
            if curl -s -f "$health_url" >/dev/null 2>&1; then
                safe_echo "${GREEN}✅ MAS API доступен на порту $mas_port${NC}"
            else
                safe_echo "${YELLOW}⚠️  MAS API недоступен (возможно, запускается)${NC}"
            fi
        fi
        
        # Показываем использование портов
        if command -v ss >/dev/null 2>&1; then
            local listening_ports=$(ss -tlnp | grep mas | grep LISTEN | awk '{print $4}' | cut -d: -f2 | sort -u)
            if [ -n "$listening_ports" ]; then
                safe_echo "${BLUE}ℹ️  MAS слушает порты: ${listening_ports}${NC}"
            fi
        fi
        
    elif systemctl is-enabled --quiet matrix-auth-service 2>/dev/null; then
        safe_echo "${YELLOW}⚠️  Сервис настроен, но не запущен${NC}"
        safe_echo "${BLUE}💡 Запустите: systemctl start matrix-auth-service${NC}"
    else
        safe_echo "${RED}❌ Сервис matrix-auth-service не настроен${NC}"
    fi
    
    echo
    
    # Проверяем базу данных
    safe_echo "${BOLD}${CYAN}База данных:${NC}"
    
    if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
        local db_name=$(grep "MAS_DB_NAME=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
        
        if [ -n "$db_name" ]; then
            local db_exists=$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -w "$db_name" | wc -l)
            if [ "$db_exists" -gt 0 ]; then
                safe_echo "${GREEN}✅ База данных $db_name существует${NC}"
            else
                safe_echo "${RED}❌ База данных $db_name не найдена${NC}"
            fi
        fi
    else
        safe_echo "${RED}❌ Конфигурация базы данных не найдена${NC}"
    fi
    
    echo
    
    # Показываем рекомендации
    safe_echo "${BOLD}${YELLOW}Рекомендации для ${SERVER_TYPE:-неопределенного типа сервера}:${NC}"
    
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            safe_echo "• ${CYAN}Настройте reverse proxy на хосте для доступа к MAS${NC}"
            safe_echo "• ${CYAN}Добавьте маршруты для compatibility endpoints${NC}"
            safe_echo "• ${CYAN}Убедитесь, что MAS доступен изнутри VM${NC}"
            ;;
        *)
            safe_echo "• ${CYAN}Настройте DNS для поддомена auth.$domain${NC}"
            safe_echo "• ${CYAN}Настройте SSL сертификат для MAS${NC}"
            safe_echo "• ${CYAN}Убедитесь, что порт $mas_port доступен извне${NC}"
            ;;
    esac
    
    # Показываем диагностическую информацию
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        echo
        safe_echo "${BOLD}${BLUE}Сохраненная конфигурация MAS:${NC}"
        while IFS= read -r line; do
            if [[ "$line" =~ ^[A-Z_]+=.* ]]; then
                safe_echo "• $line"
            fi
        done < "$CONFIG_DIR/mas.conf"
    fi
    
    return 0
}

# Удаление MAS
uninstall_mas() {
    print_header "УДАЛЕНИЕ MATRIX AUTHENTICATION SERVICE" "$RED"
    
    log "WARN" "Это действие полностью удалит MAS и все его данные"
    
    if ! ask_confirmation "Вы уверены, что хотите удалить MAS?"; then
        log "INFO" "Операция отменена пользователем"
        return 0
    fi
    
    # Останавливаем и отключаем сервис
    if systemctl is-active --quiet matrix-auth-service; then
        log "INFO" "Остановка сервиса matrix-auth-service..."
        systemctl stop matrix-auth-service
    fi
    
    if systemctl is-enabled --quiet matrix-auth-service; then
        log "INFO" "Отключение сервиса matrix-auth-service..."
        systemctl disable matrix-auth-service
    fi
    
    # Удаляем systemd сервис
    if [ -f "/etc/systemd/system/matrix-auth-service.service" ]; then
        rm -f /etc/systemd/system/matrix-auth-service.service
        systemctl daemon-reload
        log "INFO" "Systemd сервис удален"
    fi
    
    # Удаляем бинарный файл
    if [ -f "/usr/local/bin/mas" ]; then
        rm -f /usr/local/bin/mas
        log "INFO" "Бинарный файл MAS удален"
    fi
    
    # Удаляем конфигурацию
    if [ -d "$MAS_CONFIG_DIR" ]; then
        rm -rf "$MAS_CONFIG_DIR"
        log "INFO" "Конфигурация MAS удалена"
    fi
    
    if [ -f "$SYNAPSE_MAS_CONFIG" ]; then
        rm -f "$SYNAPSE_MAS_CONFIG"
        log "INFO" "Интеграция Synapse-MAS удалена"
    fi
    
    # Удаляем данные
    if [ -d "/var/lib/mas" ]; then
        rm -rf /var/lib/mas
        log "INFO" "Данные MAS удалены"
    fi
    
    # Удаляем дополнительные файлы
    if [ -d "/usr/local/share/mas-cli" ]; then
        rm -rf /usr/local/share/mas-cli
        log "INFO" "Дополнительные файлы MAS удалены"
    fi
    
    # Удаляем базу данных
    if ask_confirmation "Удалить базу данных MAS ($MAS_DB_NAME)?"; then
        if sudo -u postgres dropdb "$MAS_DB_NAME" 2>/dev/null; then
            log "SUCCESS" "База данных MAS удалена"
        else
            log "WARN" "Не удалось удалить базу данных MAS (возможно, уже удалена)"
        fi
    fi
    
    # Удаляем конфигурационные файлы проекта
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        rm -f "$CONFIG_DIR/mas.conf"
    fi
    
    if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
        rm -f "$CONFIG_DIR/mas_database.conf"
    fi
    
    # Перезапускаем Synapse для применения изменений
    if ask_confirmation "Перезапустить Synapse для применения изменений?"; then
        if systemctl restart matrix-synapse; then
            log "SUCCESS" "Synapse перезапущен"
        else
            log "WARN" "Ошибка перезапуска Synapse"
        fi
    fi
    
    log "SUCCESS" "Matrix Authentication Service успешно удален"
    return 0
}

# Диагностика MAS
diagnose_mas() {
    print_header "ДИАГНОСТИКА MATRIX AUTHENTICATION SERVICE" "$BLUE"
    
    log "INFO" "Выполнение диагностики MAS..."
    
    # Проверяем установку MAS
    if command -v mas >/dev/null 2>&1; then
        safe_echo "${GREEN}✅ MAS CLI установлен${NC}"
        
        # Запускаем встроенную диагностику MAS
        if [ -f "$MAS_CONFIG_FILE" ]; then
            safe_echo "${BLUE}🔍 Запуск встроенной диагностики MAS...${NC}"
            echo
            
            if sudo -u "$MAS_USER" mas doctor --config "$MAS_CONFIG_FILE"; then
                safe_echo "${GREEN}✅ Диагностика MAS завершена${NC}"
            else
                safe_echo "${YELLOW}⚠️  Диагностика MAS выявила проблемы${NC}"
            fi
        else
            safe_echo "${RED}❌ Конфигурация MAS не найдена для диагностики${NC}"
        fi
    else
        safe_echo "${RED}❌ MAS CLI не установлен${NC}"
    fi
    
    echo
    
    # Дополнительные проверки
    safe_echo "${BOLD}${BLUE}Дополнительные проверки:${NC}"
    
    # Проверяем сеть
    local mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    if [ -n "$mas_port" ]; then
        if ss -tlnp | grep ":$mas_port" >/dev/null; then
            safe_echo "${GREEN}✅ Порт $mas_port прослушивается${NC}"
        else
            safe_echo "${RED}❌ Порт $mas_port не прослушивается${NC}"
        fi
        
        if curl -s -f "http://localhost:$mas_port/health" >/dev/null 2>&1; then
            safe_echo "${GREEN}✅ Health endpoint отвечает${NC}"
        else
            safe_echo "${RED}❌ Health endpoint недоступен${NC}"
        fi
    fi
    
    # Проверяем логи
    safe_echo "${BLUE}🔍 Последние записи из логов MAS:${NC}"
    journalctl -u matrix-auth-service -n 10 --no-pager -q || safe_echo "${YELLOW}Логи недоступны${NC}"
    
    return 0
}

# Функция получения статуса открытой регистрации MAS
get_mas_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "disabled"
        return
    fi
    
    local status=$(grep "password_registration_enabled:" "$MAS_CONFIG_FILE" | awk '{print $2}')
    if [ "$status" = "true" ]; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Функция получения статуса регистрации по токенам
get_mas_token_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "disabled"
        return
    fi
    
    if grep -q "registration_token_required:" "$MAS_CONFIG_FILE"; then
        local status=$(grep "registration_token_required:" "$MAS_CONFIG_FILE" | awk '{print $2}')
        if [ "$status" = "true" ]; then
            echo "enabled"
        else
            echo "disabled"
        fi
    else
        echo "disabled"
    fi
}

# Функция для изменения параметра в YAML файле
set_mas_config_value() {
    local key="$1"
    local value="$2"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    log "INFO" "Установка $key: $value"
    
    if ! sed -i "s/^\(\s*$key:\s*\).*/\1$value/" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось изменить $key в $MAS_CONFIG_FILE"
        return 1
    fi
    
    log "INFO" "Перезапуск MAS для применения изменений..."
    if systemctl restart matrix-auth-service; then
        log "SUCCESS" "Параметр $key успешно изменен на '$value'"
        sleep 3 # Даем время сервису перезапуститься
    else
        log "ERROR" "Ошибка перезапуска matrix-auth-service"
        return 1
    fi
    
    return 0
}

# Генерация токена регистрации
generate_registration_token() {
    print_header "ГЕНЕРАЦИЯ ТОКЕНА РЕГИСТРАЦИИ" "$CYAN"
    
    read -p "$(safe_echo "${YELLOW}Введите лимит использований (оставьте пустым для безлимитного): ${NC}")" usage_limit
    read -p "$(safe_echo "${YELLOW}Введите срок действия в секундах (оставьте пустым для бессрочного): ${NC}")" expires_in
    
    local cmd="sudo -u \"$MAS_USER\" mas manage issue-user-registration-token --config \"$MAS_CONFIG_FILE\""
    
    if [ -n "$usage_limit" ]; then
        cmd+=" --usage-limit $usage_limit"
    fi
    
    if [ -n "$expires_in" ]; then
        cmd+=" --expires-in $expires_in"
    fi
    
    log "INFO" "Выполнение команды: $cmd"
    
    local output
    if output=$(eval "$cmd"); then
        log "SUCCESS" "Токен успешно создан"
        safe_echo "${GREEN}${output}${NC}"
    else
        log "ERROR" "Не удалось создать токен"
        safe_echo "${RED}${output}${NC}"
    fi
    
    read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
}

# Просмотр существующих токенов
view_registration_tokens() {
    print_header "СУЩЕСТВУЮЩИЕ ТОКЕНЫ РЕГИСТРАЦИИ" "$CYAN"
    
    log "INFO" "Получение списка токенов из базы данных $MAS_DB_NAME..."
    
    local query="SELECT token, max_uses, uses, TO_CHAR(expires_at, 'YYYY-MM-DD HH24:MI:SS') as expires_at, TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at FROM user_registration_tokens;"
    
    local tokens
    tokens=$(sudo -u postgres psql -d "$MAS_DB_NAME" -c "$query" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Не удалось получить доступ к базе данных или таблице токенов"
        safe_echo "${RED}Не удалось получить список токенов. Проверьте логи.${NC}"
        return 1
    fi
    
    if [[ -z "$tokens" || $(echo "$tokens" | wc -l) -le 2 ]]; then
        safe_echo "${YELLOW}Активных токенов регистрации不 найдено.${NC}"
    else
        safe_echo "${BOLD}${BLUE}Список токенов:${NC}"
        echo "$tokens"
    fi
    
    read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
}

# Меню управления SSO-провайдерами
manage_sso_providers() {
    print_header "УПРАВЛЕНИЕ ВНЕШНИМИ ПРОВАЙДЕРАМИ (SSO)" "$BLUE"

    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
        return 1
    fi

    if ! command -v yq &> /dev/null; then
        log "ERROR" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией."
        log "INFO" "Пожалуйста, установите 'yq' (например, 'sudo apt install yq' или 'sudo snap install yq')"
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
        return 1
    fi

    # Функция для синхронизации и перезапуска MAS
    sync_and_restart_mas() {
        log "INFO" "Синхронизация конфигурации MAS с базой данных..."
        if ! sudo -u "$MAS_USER" mas config sync --config "$MAS_CONFIG_FILE" --prune; then
            log "ERROR" "Ошибка синхронизации конфигурации MAS"
            return 1
        fi

        log "INFO" "Перезапуск MAS для применения изменений..."
        if systemctl restart matrix-auth-service; then
            log "SUCCESS" "Настройки SSO успешно обновлены"
            sleep 3
        else
            log "ERROR" "Ошибка перезапуска matrix-auth-service"
            return 1
        fi
    }

    # Функция для генерации ULID
    generate_ulid() {
        # Простой способ генерации псевдо-ULID, достаточный для уникальности в данном контексте
        local timestamp=$(printf '%x' $(date +%s))
        local random_part=$(openssl rand -hex 10)
        echo "$(echo "$timestamp$random_part" | tr '[:lower:]' '[:upper:]')"
    }

    # Функция добавления провайдера
    add_sso_provider() {
        local provider_name="$1"
        local human_name="$2"
        local brand_name="$3"
        local issuer="$4"
        local scope="$5"
        local extra_config="$6"

        print_header "НАСТРОЙКА $human_name SSO" "$CYAN"
        
        case $provider_name in
            "google")
                safe_echo "1. Перейдите в Google API Console: ${UNDERLINE}https://console.developers.google.com/apis/credentials${NC}"
                safe_echo "2. Нажмите 'CREATE CREDENTIALS' -> 'OAuth client ID'."
                safe_echo "3. Выберите 'Web application'."
                safe_echo "4. В 'Authorized redirect URIs' добавьте URI вашего MAS. Он будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Скопируйте 'Client ID' и 'Client Secret'."
                ;;
            "github")
                safe_echo "1. Перейдите в 'Developer settings' вашего GitHub профиля: ${UNDERLINE}https://github.com/settings/developers${NC}"
                safe_echo "2. Выберите 'OAuth Apps' -> 'New OAuth App'."
                safe_echo "3. 'Homepage URL': URL вашего MAS (например, https://auth.your-domain.com)."
                safe_echo "4. 'Authorization callback URL': URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Скопируйте 'Client ID' и сгенерируйте 'Client Secret'."
                ;;
            "gitlab")
                safe_echo "1. Перейдите в 'Applications' в настройках вашего профиля GitLab: ${UNDERLINE}https://gitlab.com/-/profile/applications${NC}"
                safe_echo "2. Создайте новое приложение."
                safe_echo "3. В 'Redirect URI' укажите URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "4. Включите скоупы: 'openid', 'profile', 'email'."
                safe_echo "5. Сохраните и скопируйте 'Application ID' (это Client ID) и 'Secret'."
                ;;
            "discord")
                safe_echo "1. Перейдите на Discord Developer Portal: ${UNDERLINE}https://discord.com/developers/applications${NC}"
                safe_echo "2. Создайте новое приложение."
                safe_echo "3. Перейдите во вкладку 'OAuth2'."
                safe_echo "4. В 'Redirects' добавьте URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Сохраните изменения и скопируйте 'Client ID' и 'Client Secret'."
                ;;
        esac
        echo

        read -p "$(safe_echo "${YELLOW}Введите Client ID: ${NC}")" client_id
        read -p "$(safe_echo "${YELLOW}Введите Client Secret: ${NC}")" client_secret

        if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
            log "ERROR" "Client ID и Client Secret не могут быть пустыми."
            read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
            return
        fi

        local ulid=$(generate_ulid)
        local mas_public_base=$(yq eval '.http.public_base' "$MAS_CONFIG_FILE")
        local redirect_uri="${mas_public_base}upstream/callback/${ulid}"
        
        safe_echo "${BOLD}${BLUE}Ваш Redirect URI для настройки в $human_name:${NC}"
        safe_echo "${CYAN}$redirect_uri${NC}"
        echo

        if ! ask_confirmation "Продолжить добавление провайдера?"; then
            return
        fi

        local provider_yaml
        provider_yaml=$(cat <<EOF
{
  "id": "$ulid",
  "human_name": "$human_name",
  "brand_name": "$brand_name",
  "client_id": "$client_id",
  "client_secret": "$client_secret",
  "scope": "$scope"
}
EOF
)
        # Добавляем специфичные для провайдера поля
        provider_yaml=$(echo "$provider_yaml" | yq eval '. as $item | '"$extra_config"' | $item * .' -)

        # Добавляем провайдер в конфиг
        yq eval -i '.upstream_oauth2.providers += [load_str("-")]' "$MAS_CONFIG_FILE" -- - "$provider_yaml"
        
        sync_and_restart_mas
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
    }

    # Функция удаления провайдера
    remove_sso_provider() {
        print_header "УДАЛЕНИЕ SSO ПРОВАЙДЕРА" "$RED"
        local providers=$(yq eval '.upstream_oauth2.providers[] | .id + " " + .human_name' "$MAS_CONFIG_FILE")
        if [ -z "$providers" ]; then
            safe_echo "${YELLOW}Нет настроенных SSO провайдеров для удаления.${NC}"
            read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
            return
        fi

        safe_echo "Список настроенных провайдеров:"
        echo "$providers"
        echo
        read -p "Введите ID провайдера для удаления: " id_to_remove

        if [ -z "$id_to_remove" ]; then
            log "WARN" "ID не указан."
            return
        fi

        if ask_confirmation "Вы уверены, что хотите удалить провайдера с ID $id_to_remove?"; then
            yq eval -i 'del(.upstream_oauth2.providers[] | select(.id == "'"$id_to_remove"'"))' "$MAS_CONFIG_FILE"
            sync_and_restart_mas
        fi
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
    }

    while true; do
        print_header "УПРАВЛЕНИЕ SSO" "$BLUE"
        
        safe_echo "${BOLD}${CYAN}Текущие SSO провайдеры:${NC}"
        local current_providers=$(yq eval -o=json '.upstream_oauth2.providers' "$MAS_CONFIG_FILE")
        if [ -z "$current_providers" ] || [ "$current_providers" = "null" ] || [ "$current_providers" = "[]" ]; then
            safe_echo "${YELLOW}SSO провайдеры не настроены.${NC}"
        else
            echo "$current_providers" | yq eval -P '.[] | .human_name + " (ID: " + .id + ")"' -
        fi
        echo

        safe_echo "${BOLD}${CYAN}Доступные опции:${NC}"
        safe_echo "${GREEN}1.${NC} ➕ Добавить Google"
        safe_echo "${GREEN}2.${NC} ➕ Добавить GitHub"
        safe_echo "${GREEN}3.${NC} ➕ Добавить GitLab"
        safe_echo "${GREEN}4.${NC} ➕ Добавить Discord"
        safe_echo "${GREEN}5.${NC} 🗑️  Удалить провайдера"
        safe_echo "${GREEN}6.${NC} ↩️  Вернуться в главное меню"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию [1-6]: ${NC}")" choice

        case $choice in
            1)
                add_sso_provider "google" "Google" "google" "" "openid profile email" \
                '.issuer = "https://accounts.google.com" | .token_endpoint_auth_method = "client_secret_post"'
                ;;
            2)
                add_sso_provider "github" "GitHub" "github" "" "read:user" \
                '.discovery_mode = "disabled" | .fetch_userinfo = true | .token_endpoint_auth_method = "client_secret_post" | .authorization_endpoint = "https://github.com/login/oauth/authorize" | .token_endpoint = "https://github.com/login/oauth/access_token" | .userinfo_endpoint = "https://api.github.com/user" | .claims_imports.subject.template = "{{ userinfo_claims.id }}"'
                ;;
            3)
                add_sso_provider "gitlab" "GitLab" "gitlab" "" "openid profile email" \
                '.issuer = "https://gitlab.com" | .token_endpoint_auth_method = "client_secret_post"'
                ;;
            4)
                add_sso_provider "discord" "Discord" "discord" "" "identify email" \
                '.discovery_mode = "disabled" | .fetch_userinfo = true | .token_endpoint_auth_method = "client_secret_post" | .authorization_endpoint = "https://discord.com/oauth2/authorize" | .token_endpoint = "https://discord.com/api/oauth2/token" | .userinfo_endpoint = "https://discord.com/api/users/@me"'
                ;;
            5)
                remove_sso_provider
                ;;
            6)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Попробуйте снова"
                sleep 1
                ;;
        esac
    done
}

# Меню управления CAPTCHA
manage_captcha_settings() {
    print_header "УПРАВЛЕНИЕ CAPTCHA" "$BLUE"

    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
        return 1
    fi

    # Проверяем наличие yq
    if ! command -v yq &> /dev/null; then
        log "ERROR" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией."
        log "INFO" "Пожалуйста, установите 'yq' (например, 'sudo apt install yq' или 'sudo snap install yq')"
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
        return 1
    fi

    # Функция для записи настроек CAPTCHA
    write_captcha_settings() {
        local service="$1"
        local site_key="$2"
        local secret_key="$3"

        log "INFO" "Обновление конфигурации CAPTCHA..."
        
        if [ "$service" = "null" ]; then
            # Отключение CAPTCHA
            if ! yq eval -i '.captcha.service = null | .captcha |= (del(.site_key) | del(.secret_key))' "$MAS_CONFIG_FILE"; then
                log "ERROR" "Не удалось отключить CAPTCHA в $MAS_CONFIG_FILE"
                return 1
            fi
        else
            # Включение CAPTCHA
            if ! yq eval -i '.captcha.service = "'"$service"'" | .captcha.site_key = "'"$site_key"'" | .captcha.secret_key = "'"$secret_key"'"' "$MAS_CONFIG_FILE"; then
                log "ERROR" "Не удалось записать настройки CAPTCHA в $MAS_CONFIG_FILE"
                return 1
            fi
        fi

        log "INFO" "Перезапуск MAS для применения изменений..."
        if systemctl restart matrix-auth-service; then
            log "SUCCESS" "Настройки CAPTCHA успешно обновлены"
            sleep 3
        else
            log "ERROR" "Ошибка перезапуска matrix-auth-service"
            return 1
        fi
    }

    while true; do
        print_header "УПРАВЛЕНИЕ CAPTCHA" "$BLUE"
        
        local service=$(yq eval '.captcha.service' "$MAS_CONFIG_FILE")
        local site_key=$(yq eval '.captcha.site_key' "$MAS_CONFIG_FILE")

        safe_echo -n "Текущий статус CAPTCHA: "
        if [ -z "$service" ] || [ "$service" = "null" ]; then
            safe_echo "${RED}ОТКЛЮЧЕНО${NC}"
        elif [ "$service" = "recaptcha_v2" ]; then
            safe_echo "${GREEN}Google reCAPTCHA v2 (Включено)${NC}"
            safe_echo "  Site Key: $site_key"
        elif [ "$service" = "cloudflare_turnstile" ]; then
            safe_echo "${GREEN}Cloudflare Turnstile (Включено)${NC}"
            safe_echo "  Site Key: $site_key"
        else
            safe_echo "${YELLOW}Неизвестный сервис ($service)${NC}"
        fi
        echo

        safe_echo "${BOLD}${CYAN}Доступные опции:${NC}"
        safe_echo "${GREEN}1.${NC} ⚙️  Настроить Google reCAPTCHA v2"
        safe_echo "${GREEN}2.${NC} ⚙️  Настроить Cloudflare Turnstile"
        safe_echo "${GREEN}3.${NC} ❌ Отключить CAPTCHA"
        safe_echo "${GREEN}4.${NC} ↩️  Вернуться в меню MAS"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию [1-4]: ${NC}")" choice

        case $choice in
            1)
                print_header "НАСТРОЙКА GOOGLE RECAPTCHA V2" "$CYAN"
                safe_echo "Для настройки вам понадобятся 'Site Key' и 'Secret Key'."
                safe_echo "1. Перейдите в консоль администратора Google reCAPTCHA:"
                safe_echo "   ${UNDERLINE}https://www.google.com/recaptcha/admin/create${NC}"
                safe_echo "2. Зарегистрируйте новый сайт:"
                safe_echo "   - ${BOLD}Label:${NC} Придумайте любое имя, например, 'Matrix Server'."
                safe_echo "   - ${BOLD}reCAPTCHA type:${NC} Выберите 'reCAPTCHA v2' и подтип '\"I'm not a robot\" Checkbox'."
                safe_echo "   - ${BOLD}Domains:${NC} Укажите домен, на котором будет доступен MAS."
                safe_echo "     - Если у вас MAS на поддомене: ${CYAN}auth.your-domain.com${NC}"
                safe_echo "     - Если MAS доступен на основном домене: ${CYAN}your-domain.com${NC}"
                safe_echo "3. Примите условия использования и нажмите 'Submit'."
                safe_echo "4. Скопируйте 'Site Key' и 'Secret Key'."
                echo
                read -p "$(safe_echo "${YELLOW}Введите Site Key: ${NC}")" new_site_key
                read -p "$(safe_echo "${YELLOW}Введите Secret Key: ${NC}")" new_secret_key

                if [ -n "$new_site_key" ] && [ -n "$new_secret_key" ]; then
                    write_captcha_settings "recaptcha_v2" "$new_site_key" "$new_secret_key"
                else
                    log "WARN" "Site Key и Secret Key не могут быть пустыми."
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            2)
                print_header "НАСТРОЙКА CLOUDFLARE TURNSTILE" "$CYAN"
                safe_echo "Для настройки вам понадобятся 'Site Key' и 'Secret Key'."
                safe_echo "1. Войдите в свою панель управления Cloudflare."
                safe_echo "2. В меню слева выберите 'Turnstile'."
                safe_echo "3. Нажмите 'Add site':"
                safe_echo "   - ${BOLD}Site name:${NC} Придумайте любое имя, например, 'Matrix Server'."
                safe_echo "   - ${BOLD}Domain:${NC} Укажите домен, на котором будет доступен MAS."
                safe_echo "     - Если у вас MAS на поддомене: ${CYAN}auth.your-domain.com${NC}"
                safe_echo "     - Если MAS доступен на основном домене: ${CYAN}your-domain.com${NC}"
                safe_echo "   - ${BOLD}Widget Mode:${NC} Выберите 'Managed'."
                safe_echo "4. Нажмите 'Create'."
                safe_echo "5. Скопируйте 'Site Key' и 'Secret Key' в поля ниже."
                echo
                read -p "$(safe_echo "${YELLOW}Введите Site Key: ${NC}")" new_site_key
                read -p "$(safe_echo "${YELLOW}Введите Secret Key: ${NC}")" new_secret_key

                if [ -n "$new_site_key" ] && [ -n "$new_secret_key" ]; then
                    write_captcha_settings "cloudflare_turnstile" "$new_site_key" "$new_secret_key"
                else
                    log "WARN" "Site Key и Secret Key не могут быть пустыми."
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            3)
                if ask_confirmation "Вы уверены, что хотите отключить CAPTCHA?"; then
                    write_captcha_settings "null" "" ""
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            4)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Попробуйте снова"
                sleep 1
                ;;
        esac
    done
}

# Меню управления заблокированными именами
manage_banned_usernames() {
    print_header "УПРАВЛЕНИЕ ЗАБЛОКИРОВАННЫМИ ИМЕНАМИ" "$BLUE"

    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
        return 1
    fi

    # Функция для чтения заблокированных имен из YAML
    read_banned_usernames() {
        yq eval '.policy.data.registration.banned_usernames' "$MAS_CONFIG_FILE"
    }

    # Функция для записи заблокированных имен в YAML
    write_banned_usernames() {
        local yaml_string="$1"
        if ! yq eval -i '.policy.data.registration.banned_usernames = '"$yaml_string"'' "$MAS_CONFIG_FILE"; then
            log "ERROR" "Не удалось записать данные в $MAS_CONFIG_FILE"
            return 1
        fi
        log "INFO" "Перезапуск MAS для применения изменений..."
        if systemctl restart matrix-auth-service; then
            log "SUCCESS" "Настройки заблокированных имен обновлены"
            sleep 3
        else
            log "ERROR" "Ошибка перезапуска matrix-auth-service"
            return 1
        fi
    }

    # Проверяем наличие yq
    if ! command -v yq &> /dev/null; then
        log "ERROR" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией."
        log "INFO" "Пожалуйста, установите 'yq' (например, 'sudo apt install yq' или 'sudo snap install yq')"
        read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
        return 1
    fi

    while true; do
        print_header "УПРАВЛЕНИЕ ЗАБЛОКИРОВАННЫМИ ИМЕНАМИ" "$BLUE"
        
        safe_echo "${BOLD}${CYAN}Текущие заблокированные имена:${NC}"
        local current_config=$(read_banned_usernames)
        
        if [ -z "$current_config" ] || [ "$current_config" = "null" ]; then
            safe_echo "${YELLOW}Списки заблокированных имен пусты.${NC}"
        else
            echo "$current_config" | yq eval -P -
        fi
        echo

        safe_echo "${BOLD}${CYAN}Доступные опции:${NC}"
        safe_echo "${GREEN}1.${NC} ➕ Добавить значение"
        safe_echo "${GREEN}2.${NC} 🗑️  Очистить все списки"
        safe_echo "${GREEN}3.${NC} ⚙️  Установить значения по умолчанию"
        safe_echo "${GREEN}4.${NC} ↩️  Вернуться в меню MAS"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию [1-4]: ${NC}")" choice

        case $choice in
            1)
                safe_echo "Выберите тип блокировки:"
                safe_echo "  1. literals (Точное совпадение)"
                safe_echo "  2. substrings (Вхождение подстроки)"
                safe_echo "  3. regexes (Регулярное выражение)"
                read -p "Ваш выбор [1-3]: " type_choice

                local key_to_add=""
                case $type_choice in
                    1) key_to_add="literals";;
                    2) key_to_add="substrings";;
                    3) key_to_add="regexes";;
                    *) log "ERROR" "Неверный выбор"; continue;;
                esac

                read -p "Введите значение для добавления в '$key_to_add': " value_to_add
                if [ -n "$value_to_add" ]; then
                    yq eval -i ".policy.data.registration.banned_usernames.$key_to_add += [\"$value_to_add\"]" "$MAS_CONFIG_FILE"
                    log "SUCCESS" "Значение '$value_to_add' добавлено в '$key_to_add'"
                    systemctl restart matrix-auth-service
                else
                    log "WARN" "Значение не может быть пустым"
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            2)
                if ask_confirmation "Вы уверены, что хотите очистить все списки заблокированных имен?"; then
                    write_banned_usernames "null"
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            3)
                if ask_confirmation "Вы уверены, что хотите установить значения по умолчанию?"; then
                    local default_yaml="{literals: [\"admin\", \"root\", \"test\"], substrings: [\"admin\", \"mod\"], regexes: [\"^system.*\", \".*bot\$\"]}"
                    write_banned_usernames "$default_yaml"
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            4)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Попробуйте снова"
                sleep 1
                ;;
        esac
    done
}

# Меню управления регистрацией MAS
manage_mas_registration() {
    while true; do
        print_header "УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ MAS" "$BLUE"
        
        local open_reg_status=$(get_mas_registration_status)
        local token_reg_status=$(get_mas_token_registration_status)
        
        safe_echo -n "Статус открытой регистрации: "
        if [ "$open_reg_status" = "enabled" ]; then
            safe_echo "${GREEN}ON (Регистрация разрешена)${NC}"
        else
            safe_echo "${RED}OFF (Регистрация запрещена)${NC}"
        fi
        
        safe_echo -n "Требование токена для регистрации: "
        if [ "$token_reg_status" = "enabled" ]; then
            safe_echo "${GREEN}ON (Токен обязателен)${NC}"
        else
            safe_echo "${RED}OFF (Токен не требуется)${NC}"
        fi
        echo
        
        safe_echo "${BOLD}${CYAN}Доступные опции:${NC}"
        safe_echo "${GREEN}1.${NC} Включить/Отключить открытую регистрацию"
        safe_echo "${GREEN}2.${NC} Включить/Отключить требование токена"
        
        if [ "$token_reg_status" = "enabled" ]; then
            safe_echo "${GREEN}3.${NC} 🔑 Сгенерировать токен регистрации"
            safe_echo "${GREEN}4.${NC} 👁️  Просмотреть токены регистрации"
        fi
        
        safe_echo "${GREEN}5.${NC} 🚫 Управление заблокированными именами"
        safe_echo "${GREEN}6.${NC} 🛡️  Управление CAPTCHA"
        safe_echo "${GREEN}7.${NC} ↩️  Вернуться в меню MAS"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию: ${NC}")" choice
        
        case $choice in
            1)
                if [ "$open_reg_status" = "enabled" ]; then
                    set_mas_config_value "password_registration_enabled" "false"
                else
                    set_mas_config_value "password_registration_enabled" "true"
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            2)
                if [ "$token_reg_status" = "enabled" ]; then
                    set_mas_config_value "registration_token_required" "false"
                else
                    set_mas_config_value "registration_token_required" "true"
                fi
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            3)
                if [ "$token_reg_status" = "enabled" ]; then
                    generate_registration_token
                else
                    log "ERROR" "Неверный выбор. Попробуйте снова"
                    sleep 1
                fi
                ;;
            4)
                if [ "$token_reg_status" = "enabled" ]; then
                    view_registration_tokens
                else
                    log "ERROR" "Неверный выбор. Попробуйте снова"
                    sleep 1
                fi
                ;;
            5)
                manage_banned_usernames
                ;;
            6)
                manage_captcha_settings
                ;;
            7)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Попробуйте снова"
                sleep 1
                ;;
        esac
    done
}

# Главное меню модуля
show_main_menu() {
    while true; do
        print_header "MATRIX AUTHENTICATION SERVICE (MAS)" "$MAGENTA"
        
        # Показываем краткий статус
        if command -v mas >/dev/null 2>&1; then
            if systemctl is-active --quiet matrix-auth-service 2>/dev/null; then
                safe_echo "${GREEN}🟢 MAS установлен и запущен${NC}"
            else
                safe_echo "${YELLOW}🟡 MAS установлен, но не запущен${NC}"
            fi
        else
            safe_echo "${RED}🔴 MAS не установлен${NC}"
        fi
        
        # Показываем информацию о режиме
        safe_echo "${BOLD}${CYAN}Режим сервера: ${SERVER_TYPE:-неопределен}${NC}"
        
        echo
        safe_echo "${BOLD}${CYAN}Доступные опции:${NC}"
        safe_echo "${GREEN}1.${NC} 🚀 Установить Matrix Authentication Service"
        safe_echo "${GREEN}2.${NC} 📊 Проверить статус MAS"
        safe_echo "${GREEN}3.${NC} 🚪 Управление регистрацией MAS"
        safe_echo "${GREEN}4.${NC} 🔧 Диагностика MAS"
        safe_echo "${GREEN}5.${NC} SSO Управление внешними провайдерами (SSO)"
        safe_echo "${GREEN}6.${NC} 🗑️  Удалить MAS"
        safe_echo "${GREEN}7.${NC} ↩️  Вернуться в главное меню"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию [1-7]: ${NC}")" choice
        
        case $choice in
            1)
                install_matrix_authentication_service
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            2)
                check_mas_status
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            3)
                manage_mas_registration
                ;;
            4)
                diagnose_mas
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            5)
                manage_sso_providers
                ;;
            6)
                uninstall_mas
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            7)
                log "INFO" "Возврат в главное меню"
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Попробуйте снова"
                sleep 2
                ;;
        esac
    done
}

# Главная функция модуля
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
    
    # Запускаем главное меню
    show_main_menu
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi