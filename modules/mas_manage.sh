#!/bin/bash

# Matrix Authentication Service (MAS) Management Module
# Все функции управления MAS, перенесённые из registration_mas.sh

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
MAS_USER="matrix-synapse"
MAS_GROUP="matrix-synapse"
MAS_PORT_HOSTING="8080"
MAS_PORT_PROXMOX="8082"
MAS_DB_NAME="mas_db"

# Проверка root прав
check_root

# Загружаем тип сервера
load_server_type

# --- Управляющие функции MAS ---

# Проверка статуса MAS
check_mas_status() {
    print_header "СТАТУС MATRIX AUTHENTICATION SERVICE" "$CYAN"

    # Проверяем статус службы matrix-auth-service
    if systemctl is-active --quiet matrix-auth-service; then
        log "SUCCESS" "MAS служба запущена"
        
        # Показываем статус
        systemctl status matrix-auth-service --no-pager -l
        
        # Проверяем порт MAS
        local mas_port=""
        if [ -f "$CONFIG_DIR/mas.conf" ]; then
            mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
        fi
        
        if [ -n "$mas_port" ]; then
            if ss -tlnp | grep -q ":$mas_port "; then
                log "SUCCESS" "MAS слушает на порту $mas_port"
            else
                log "WARN" "MAS НЕ слушает на порту $mas_port"
            fi
            
            # Проверяем доступность API
            local health_url="http://localhost:$mas_port/health"
            if curl -s -f --connect-timeout 3 "$health_url" >/dev/null 2>&1; then
                log "SUCCESS" "MAS API доступен"
            else
                log "WARN" "MAS API недоступен"
            fi
        else
            log "WARN" "Порт MAS не определен"
        fi
    else
        log "ERROR" "MAS служба не запущена"
        
        # Проверяем, установлен ли MAS
        if command -v mas >/dev/null 2>&1; then
            log "INFO" "MAS установлен, но служба не запущена"
        else
            log "ERROR" "MAS не установлен"
        fi
    fi
    
    # Проверяем конфигурационные файлы
    if [ -f "$MAS_CONFIG_FILE" ]; then
        log "SUCCESS" "Конфигурационный файл MAS найден"
    else
        log "ERROR" "Конфигурационный файл MAS не найден: $MAS_CONFIG_FILE"
    fi
    
    if [ -f "$SYNAPSE_MAS_CONFIG" ]; then
        log "SUCCESS" "Интеграция Synapse с MAS настроена"
    else
        log "WARN" "Интеграция Synapse с MAS не настроена"
    fi
}

# Удаление MAS
uninstall_mas() {
    print_header "УДАЛЕНИЕ MATRIX AUTHENTICATION SERVICE" "$RED"

    if ! ask_confirmation "Вы действительно хотите удалить Matrix Authentication Service?"; then
        log "INFO" "Удаление отменено"
        return 0
    fi

    log "INFO" "Удаление MAS..."

    # Остановка службы MAS
    if systemctl is-active --quiet matrix-auth-service; then
        log "INFO" "Остановка службы matrix-auth-service..."
        systemctl stop matrix-auth-service
    fi

    # Отключение автозапуска
    if systemctl is-enabled --quiet matrix-auth-service 2>/dev/null; then
        log "INFO" "Отключение автозапуска matrix-auth-service..."
        systemctl disable matrix-auth-service
    fi

    # Удаление systemd сервиса
    if [ -f "/etc/systemd/system/matrix-auth-service.service" ]; then
        log "INFO" "Удаление systemd сервиса..."
        rm -f /etc/systemd/system/matrix-auth-service.service
        systemctl daemon-reload
    fi

    # Удаление бинарного файла MAS
    if [ -f "/usr/local/bin/mas" ]; then
        log "INFO" "Удаление бинарного файла MAS..."
        rm -f /usr/local/bin/mas
    fi

    # Удаление конфигурационных файлов MAS
    if [ -d "$MAS_CONFIG_DIR" ]; then
        log "INFO" "Удаление конфигурации MAS..."
        rm -rf "$MAS_CONFIG_DIR"
    fi

    # Удаление интеграции с Synapse
    if [ -f "$SYNAPSE_MAS_CONFIG" ]; then
        log "INFO" "Удаление интеграции с Synapse..."
        rm -f "$SYNAPSE_MAS_CONFIG"
        
        # Перезапуск Synapse для применения изменений
        if systemctl is-active --quiet matrix-synapse; then
            log "INFO" "Перезапуск Synapse..."
            systemctl restart matrix-synapse
        fi
    fi

    # Удаление данных MAS
    if [ -d "/var/lib/mas" ]; then
        log "INFO" "Удаление данных MAS..."
        rm -rf /var/lib/mas
    fi

    # Удаление конфигурационных файлов установщика
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        rm -f "$CONFIG_DIR/mas.conf"
    fi
    
    if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
        rm -f "$CONFIG_DIR/mas_database.conf"
    fi

    # Удаление базы данных MAS (опционально)
    if ask_confirmation "Удалить также базу данных MAS ($MAS_DB_NAME)?"; then
        if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$MAS_DB_NAME"; then
            log "INFO" "Удаление базы данных $MAS_DB_NAME..."
            sudo -u postgres dropdb "$MAS_DB_NAME"
        fi
    fi

    log "SUCCESS" "MAS успешно удалён"
}

# Функция для исправления поврежденной конфигурации MAS
fix_mas_config_corruption() {
    print_header "ИСПРАВЛЕНИЕ ПОВРЕЖДЕННОЙ КОНФИГУРАЦИИ MAS" "$YELLOW"
    
    log "INFO" "Проверка конфигурации MAS на наличие повреждений..."
    
    # Проверяем наличие файлов
    if [ ! -f "$CONFIG_DIR/mas_database.conf" ]; then
        log "ERROR" "Файл конфигурации базы данных не найден: $CONFIG_DIR/mas_database.conf"
        log "ERROR" "Невозможно восстановить конфигурацию без этого файла"
        return 1
    fi
    
    if [ ! -f "$CONFIG_DIR/mas.conf" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $CONFIG_DIR/mas.conf"
        log "ERROR" "Невозможно восстановить конфигурацию без этого файла"
        return 1
    fi
    
    # Проверяем секцию database в конфигурации MAS
    local has_database_section=false
    local correct_uri=false
    
    if [ -f "$MAS_CONFIG_FILE" ]; then
        if grep -q "^database:" "$MAS_CONFIG_FILE"; then
            has_database_section=true
            
            # Проверяем корректность URI
            local db_uri=$(grep "MAS_DB_URI=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
            if grep -q "$db_uri" "$MAS_CONFIG_FILE"; then
                correct_uri=true
                log "SUCCESS" "Конфигурация MAS корректна"
                return 0
            else
                log "WARN" "Неверный URI базы данных в конфигурации MAS"
            fi
        else
            log "ERROR" "Секция database отсутствует в конфигурации MAS"
        fi
    else
        log "ERROR" "Конфигурационный файл MAS не найден"
    fi
    
    if ! $has_database_section || ! $correct_uri; then
        log "WARN" "Обнаружены проблемы в конфигурации MAS"
        
        if ask_confirmation "Восстановить конфигурацию MAS?"; then
            # Загружаем сохраненные параметры
            local db_uri=$(grep "MAS_DB_URI=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
            local mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
            local mas_secret=$(grep "MAS_SECRET=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
            local matrix_domain=$(grep "MAS_DOMAIN=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
            
            if [ -z "$db_uri" ] || [ -z "$mas_port" ] || [ -z "$mas_secret" ] || [ -z "$matrix_domain" ]; then
                log "ERROR" "Не удалось загрузить сохраненные параметры конфигурации"
                return 1
            fi
            
            log "INFO" "Восстановление конфигурации MAS..."
            log "DEBUG" "Используемые параметры:"
            log "DEBUG" "  Порт: $mas_port"
            log "DEBUG" "  Домен: $matrix_domain"
            log "DEBUG" "  URI БД: $db_uri"
            
            # Создаем резервную копию поврежденной конфигурации
            if [ -f "$MAS_CONFIG_FILE" ]; then
                cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.corrupted.$(date +%s)"
                log "INFO" "Резервная копия поврежденной конфигурации создана"
            fi
            
            # Определяем публичную базу и issuer в зависимости от типа сервера
            local mas_public_base
            local mas_issuer
            
            case "${SERVER_TYPE:-hosting}" in
                "proxmox"|"home_server"|"openvz"|"docker")
                    mas_public_base="https://$matrix_domain"
                    mas_issuer="https://$matrix_domain"
                    ;;
                *)
                    mas_public_base="https://auth.$matrix_domain"
                    mas_issuer="https://auth.$matrix_domain"
                    ;;
            esac
            
            # Создаем новую корректную конфигурацию
            cat > "$MAS_CONFIG_FILE" <<EOF
# Matrix Authentication Service Configuration
# Restored: $(date '+%Y-%m-%d %H:%M:%S')
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

            # Устанавливаем права доступа
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
            chmod 600 "$MAS_CONFIG_FILE"
            
            log "SUCCESS" "Конфигурация MAS восстановлена"
            
            # Перезапускаем сервис
            log "INFO" "Перезапуск MAS для применения изменений..."
            
            if systemctl restart matrix-auth-service; then
                log "SUCCESS" "MAS успешно перезапущен с восстановленной конфигурацией"
                
                # Проверяем работоспособность
                sleep 3
                if systemctl is-active --quiet matrix-auth-service; then
                    log "SUCCESS" "MAS работает корректно"
                    
                    # Проверяем API
                    local health_url="http://localhost:$mas_port/health"
                    if curl -s -f --connect-timeout 5 "$health_url" >/dev/null 2>&1; then
                        log "SUCCESS" "MAS API доступен"
                    else
                        log "WARN" "MAS API пока недоступен (возможно, еще инициализируется)"
                    fi
                else
                    log "ERROR" "MAS не запустился после восстановления конфигурации"
                    log "INFO" "Проверьте логи: journalctl -u matrix-auth-service -n 20"
                    return 1
                fi
            else
                log "ERROR" "Ошибка перезапуска MAS"
                return 1
            fi
        else
            log "INFO" "Восстановление конфигурации отменено"
            return 0
        fi
    fi
    
    return 0
}

# Диагностика MAS
diagnose_mas() {
    print_header "ДИАГНОСТИКА MATRIX AUTHENTICATION SERVICE" "$BLUE"

    log "INFO" "Диагностика MAS..."

    # Проверка состояния службы MAS
    log "INFO" "Проверка службы matrix-auth-service..."
    systemctl status matrix-auth-service --no-pager -l || log "ERROR" "Служба matrix-auth-service недоступна"

    # Проверка логов MAS
    log "INFO" "Последние логи matrix-auth-service:"
    journalctl -u matrix-auth-service --no-pager -n 20 || log "ERROR" "Не удалось получить логи"

    # Проверка конфигурационных файлов MAS
    if [ -f "$MAS_CONFIG_FILE" ]; then
        log "INFO" "Проверка конфигурации MAS..."
        
        # Проверяем секцию database
        if ! grep -q "^database:" "$MAS_CONFIG_FILE"; then
            log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: Секция database отсутствует в конфигурации MAS!"
            log "ERROR" "Это может быть причиной ошибки подключения к базе данных"
            
            if ask_confirmation "Попытаться исправить поврежденную конфигурацию?"; then
                fix_mas_config_corruption
                return
            fi
        else
            log "SUCCESS" "Секция database найдена в конфигурации"
        fi
        
        if command -v mas >/dev/null 2>&1; then
            if mas doctor --config "$MAS_CONFIG_FILE"; then
                log "SUCCESS" "Конфигурация MAS корректна"
            else
                log "ERROR" "Обнаружены проблемы в конфигурации MAS"
            fi
        else
            log "WARN" "Команда 'mas' не найдена, пропускаем проверку конфигурации"
        fi
    else
        log "ERROR" "Конфигурационный файл MAS не найден: $MAS_CONFIG_FILE"
    fi

    # Проверка интеграции с Synapse
    if [ -f "$SYNAPSE_MAS_CONFIG" ]; then
        log "SUCCESS" "Файл интеграции Synapse найден"
        
        # Проверяем, что Synapse запущен
        if systemctl is-active --quiet matrix-synapse; then
            log "SUCCESS" "Matrix Synapse запущен"
        else
            log "ERROR" "Matrix Synapse не запущен"
        fi
    else
        log "ERROR" "Файл интеграции Synapse не найден: $SYNAPSE_MAS_CONFIG"
    fi

    # Проверка доступности API MAS
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        local mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
        
        if [ -n "$mas_port" ]; then
            log "INFO" "Проверка API MAS на порту $mas_port..."
            local health_url="http://localhost:$mas_port/health"
            
            if curl -s -f --connect-timeout 3 "$health_url" >/dev/null 2>&1; then
                log "SUCCESS" "MAS API доступен"
            else
                log "ERROR" "MAS API недоступен"
            fi
        fi
    fi

    log "INFO" "Диагностика завершена"
}

# Проверка наличия yq
check_yq_dependency() {
    if ! command -v yq &>/dev/null; then
        log "WARN" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией MAS."
        if ask_confirmation "Установить yq автоматически?"; then
            log "INFO" "Установка yq..."
            if command -v snap &>/dev/null; then
                if snap install yq; then
                    log "SUCCESS" "yq установлен через snap"
                    return 0
                fi
            fi
            log "INFO" "Установка yq через GitHub releases..."
            local arch=$(uname -m)
            local yq_binary=""
            case "$arch" in
                x86_64) yq_binary="yq_linux_amd64" ;;
                aarch64|arm64) yq_binary="yq_linux_arm64" ;;
                *) log "ERROR" "Неподдерживаемая архитектура для yq: $arch"; return 1 ;;
            esac
            local yq_url="https://github.com/mikefarah/yq/releases/latest/download/$yq_binary"
            if download_file "$yq_url" "/tmp/yq" && chmod +x /tmp/yq && mv /tmp/yq /usr/local/bin/yq; then
                log "SUCCESS" "yq установлен через GitHub releases"
                return 0
            else
                log "ERROR" "Не удалось установить yq"
                return 1
            fi
        else
            log "ERROR" "yq необходим для управления конфигурацией MAS"
            log "INFO" "Установите вручную: snap install yq или apt install yq"
            return 1
        fi
    fi
    return 0
}

# Получение статуса открытой регистрации MAS
get_mas_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local status=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$status" = "true" ]; then
        echo "enabled"
    elif [ "$status" = "false" ]; then
        echo "disabled" 
    else
        echo "unknown"
    fi
}

# Получение статуса регистрации по токенам
get_mas_token_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local status=$(yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$status" = "true" ]; then
        echo "enabled"
    elif [ "$status" = "false" ]; then
        echo "disabled"
    else
        echo "unknown"
    fi
}

# Получение статуса CAPTCHA
get_mas_captcha_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local service=$(yq eval '.captcha.service' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$service" = "null" ] || [ "$service" = "~" ] || [ -z "$service" ]; then
        echo "disabled"
    else
        echo "$service"
    fi
}

# Изменение параметра в YAML файле
set_mas_config_value() {
    local key="$1"
    local value="$2"
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    if ! check_yq_dependency; then
        return 1
    fi
    log "INFO" "Изменение настройки $key на $value..."
    local full_path=""
    case "$key" in
        "password_registration_enabled"|"registration_token_required"|"email_change_allowed"|"displayname_change_allowed"|"password_change_allowed"|"password_recovery_enabled"|"account_deactivation_allowed")
            full_path=".account.$key"
            ;;
        "captcha_service")
            full_path=".captcha.service"
            ;;
        "captcha_site_key")
            full_path=".captcha.site_key"
            ;;
        "captcha_secret_key")
            full_path=".captcha.secret_key"
            ;;
        *)
            log "ERROR" "Неизвестный параметр конфигурации: $key"
            return 1
            ;;
    esac
    
    # Создаем резервную копию
    cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
    
    if ! yq eval -i "$full_path = $value" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось изменить $key в $MAS_CONFIG_FILE"
        return 1
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    log "INFO" "Перезапуск MAS для применения изменений..."
    if systemctl restart matrix-auth-service; then
        log "SUCCESS" "Настройка $key успешно изменена на $value"
    else
        log "ERROR" "Ошибка перезапуска matrix-auth-service"
        return 1
    fi
    return 0
}

# Установка CAPTCHA конфигурации
set_mas_captcha_config() {
    local service="$1"
    local site_key="$2"
    local secret_key="$3"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    if ! check_yq_dependency; then
        return 1
    fi
    
    log "INFO" "Настройка CAPTCHA сервиса $service..."
    
    # Создаем резервную копию
    cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
    
    # Устанавливаем сервис
    if [ "$service" = "disabled" ]; then
        yq eval -i '.captcha.service = null' "$MAS_CONFIG_FILE"
        yq eval -i 'del(.captcha.site_key)' "$MAS_CONFIG_FILE"
        yq eval -i 'del(.captcha.secret_key)' "$MAS_CONFIG_FILE"
    else
        yq eval -i '.captcha.service = "'"$service"'"' "$MAS_CONFIG_FILE"
        yq eval -i '.captcha.site_key = "'"$site_key"'"' "$MAS_CONFIG_FILE"
        yq eval -i '.captcha.secret_key = "'"$secret_key"'"' "$MAS_CONFIG_FILE"
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    log "INFO" "Перезапуск MAS для применения изменений..."
    if systemctl restart matrix-auth-service; then
        log "SUCCESS" "CAPTCHA конфигурация успешно обновлена"
    else
        log "ERROR" "Ошибка перезапуска matrix-auth-service"
        return 1
    fi
    
    return 0
}

# Управление настройками CAPTCHA
manage_captcha_settings() {
    print_header "УПРАВЛЕНИЕ НАСТРОЙКАМИ CAPTCHA" "$BLUE"

    # Проверка наличия yq
    if ! check_yq_dependency; then
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    while true; do
        # Показываем текущий статус
        local current_status=$(get_mas_captcha_status)
        
        safe_echo "Текущий статус CAPTCHA:"
        case "$current_status" in
            "disabled"|"null") safe_echo "• CAPTCHA: ${RED}ОТКЛЮЧЕНА${NC}" ;;
            "recaptcha_v2") safe_echo "• CAPTCHA: ${GREEN}Google reCAPTCHA v2${NC}" ;;
            "cloudflare_turnstile") safe_echo "• CAPTCHA: ${GREEN}Cloudflare Turnstile${NC}" ;;
            "hcaptcha") safe_echo "• CAPTCHA: ${GREEN}hCaptcha${NC}" ;;
            *) safe_echo "• CAPTCHA: ${YELLOW}$current_status${NC}" ;;
        esac
        
        echo
        safe_echo "Доступные провайдеры CAPTCHA:"
        safe_echo "1. Отключить CAPTCHA"
        safe_echo "2. Настроить Google reCAPTCHA v2"
        safe_echo "3. Настроить Cloudflare Turnstile"
        safe_echo "4. Настроить hCaptcha"
        safe_echo "5. Назад"

        read -p "Выберите действие [1-5]: " action

        case $action in
            1)
                log "INFO" "Отключение CAPTCHA..."
                set_mas_captcha_config "disabled" "" ""
                ;;
            2)
                print_header "НАСТРОЙКА GOOGLE reCAPTCHA v2" "$CYAN"
                safe_echo "Для настройки Google reCAPTCHA v2:"
                safe_echo "1. Перейдите на https://www.google.com/recaptcha/admin"
                safe_echo "2. Создайте новый сайт с типом 'reCAPTCHA v2'"
                safe_echo "3. Добавьте ваш домен в список разрешенных доменов"
                safe_echo "4. Скопируйте 'Site Key' и 'Secret Key'"
                echo
                read -p "Введите Site Key: " site_key
                read -p "Введите Secret Key: " secret_key
                
                if [ -n "$site_key" ] && [ -n "$secret_key" ]; then
                    set_mas_captcha_config "recaptcha_v2" "$site_key" "$secret_key"
                else
                    log "ERROR" "Site Key и Secret Key не могут быть пустыми"
                fi
                ;;
            3)
                print_header "НАСТРОЙКА CLOUDFLARE TURNSTILE" "$CYAN"
                safe_echo "Для настройки Cloudflare Turnstile:"
                safe_echo "1. Перейдите в Cloudflare Dashboard → Turnstile"
                safe_echo "2. Создайте новый сайт"
                safe_echo "3. Добавьте ваш домен"
                safe_echo "4. Скопируйте 'Site Key' и 'Secret Key'"
                echo
                read -p "Введите Site Key: " site_key
                read -p "Введите Secret Key: " secret_key
                
                if [ -n "$site_key" ] && [ -n "$secret_key" ]; then
                    set_mas_captcha_config "cloudflare_turnstile" "$site_key" "$secret_key"
                else
                    log "ERROR" "Site Key и Secret Key не могут быть пустыми"
                fi
                ;;
            4)
                print_header "НАСТРОЙКА hCAPTCHA" "$CYAN"
                safe_echo "Для настройки hCaptcha:"
                safe_echo "1. Перейдите на https://dashboard.hcaptcha.com/"
                safe_echo "2. Создайте новый сайт"
                safe_echo "3. Добавьте ваш домен"
                safe_echo "4. Скопируйте 'Site Key' и 'Secret Key'"
                echo
                read -p "Введите Site Key: " site_key
                read -p "Введите Secret Key: " secret_key
                
                if [ -n "$site_key" ] && [ -n "$secret_key" ]; then
                    set_mas_captcha_config "hcaptcha" "$site_key" "$secret_key"
                else
                    log "ERROR" "Site Key и Secret Key не могут быть пустыми"
                fi
                ;;
            5)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
    done
}

# Управление заблокированными именами пользователей
manage_banned_usernames() {
    print_header "УПРАВЛЕНИЕ ЗАБЛОКИРОВАННЫМИ ИМЕНАМИ ПОЛЬЗОВАТЕЛЕЙ" "$BLUE"

    # Проверка наличия yq
    if ! check_yq_dependency; then
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    # Функция для показа текущих заблокированных имен
    show_current_banned() {
        local banned_literals=$(yq eval '.policy.data.registration.banned_usernames.literals[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        local banned_substrings=$(yq eval '.policy.data.registration.banned_usernames.substrings[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        local banned_regexes=$(yq eval '.policy.data.registration.banned_usernames.regexes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        local banned_prefixes=$(yq eval '.policy.data.registration.banned_usernames.prefixes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        local banned_suffixes=$(yq eval '.policy.data.registration.banned_usernames.suffixes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        
        safe_echo "${BOLD}Текущие заблокированные имена:${NC}"
        
        if [ -n "$banned_literals" ] && [ "$banned_literals" != "null" ]; then
            safe_echo "${CYAN}Точные имена:${NC}"
            echo "$banned_literals" | while read -r name; do
                [ -n "$name" ] && safe_echo "  • $name"
            done
        fi
        
        if [ -n "$banned_substrings" ] && [ "$banned_substrings" != "null" ]; then
            safe_echo "${CYAN}Подстроки:${NC}"
            echo "$banned_substrings" | while read -r substring; do
                [ -n "$substring" ] && safe_echo "  • *$substring*"
            done
        fi
        
        if [ -n "$banned_regexes" ] && [ "$banned_regexes" != "null" ]; then
            safe_echo "${CYAN}Регулярные выражения:${NC}"
            echo "$banned_regexes" | while read -r regex; do
                [ -n "$regex" ] && safe_echo "  • $regex"
            done
        fi
        
        if [ -n "$banned_prefixes" ] && [ "$banned_prefixes" != "null" ]; then
            safe_echo "${CYAN}Префиксы:${NC}"
            echo "$banned_prefixes" | while read -r prefix; do
                [ -n "$prefix" ] && safe_echo "  • $prefix*"
            done
        fi
        
        if [ -n "$banned_suffixes" ] && [ "$banned_suffixes" != "null" ]; then
            safe_echo "${CYAN}Суффиксы:${NC}"
            echo "$banned_suffixes" | while read -r suffix; do
                [ -n "$suffix" ] && safe_echo "  • *$suffix"
            done
        fi
        
        if [ -z "$banned_literals$banned_substrings$banned_regexes$banned_prefixes$banned_suffixes" ] || 
           [ "$banned_literals$banned_substrings$banned_regexes$banned_prefixes$banned_suffixes" = "nullnullnullnullnull" ]; then
            safe_echo "Заблокированные имена не настроены"
        fi
    }

    # Функция для добавления заблокированного имени
    add_banned_username() {
        local type="$1"
        local type_name="$2"
        local path="$3"
        
        read -p "Введите ${type_name,,}: " username
        
        if [ -z "$username" ]; then
            log "ERROR" "Имя не может быть пустым"
            return 1
        fi
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Инициализируем структуру если не существует
        yq eval -i '.policy.data.registration.banned_usernames //= {}' "$MAS_CONFIG_FILE"
        yq eval -i ".policy.data.registration.banned_usernames.$path //= []" "$MAS_CONFIG_FILE"
        
        # Добавляем новое имя
        if yq eval -i ".policy.data.registration.banned_usernames.$path += [\"$username\"]" "$MAS_CONFIG_FILE"; then
            # Устанавливаем права
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
            chmod 600 "$MAS_CONFIG_FILE"
            
            log "INFO" "Перезапуск MAS для применения изменений..."
            if systemctl restart matrix-auth-service; then
                log "SUCCESS" "$type_name '$username' добавлен в заблокированные"
            else
                log "ERROR" "Ошибка перезапуска matrix-auth-service"
                return 1
            fi
        else
            log "ERROR" "Не удалось добавить $type_name"
            return 1
        fi
    }

    # Функция для удаления заблокированного имени
    remove_banned_username() {
        local type="$1"
        local type_name="$2"
        local path="$3"
        
        # Показываем текущие значения этого типа
        local current_items=$(yq eval ".policy.data.registration.banned_usernames.$path[]" "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ -z "$current_items" ] || [ "$current_items" = "null" ]; then
            log "WARN" "Нет заблокированных $type_name для удаления"
            return 0
        fi
        
        safe_echo "Текущие заблокированные $type_name:"
        echo "$current_items" | nl
        echo
        
        read -p "Введите $type_name для удаления: " username
        
        if [ -z "$username" ]; then
            log "ERROR" "Имя не может быть пустым"
            return 1
        fi
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Удаляем имя
        if yq eval -i "del(.policy.data.registration.banned_usernames.$path[] | select(. == \"$username\"))" "$MAS_CONFIG_FILE"; then
            # Устанавливаем права
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
            chmod 600 "$MAS_CONFIG_FILE"
            
            log "INFO" "Перезапуск MAS для применения изменений..."
            if systemctl restart matrix-auth-service; then
                log "SUCCESS" "$type_name '$username' удален из заблокированных"
            else
                log "ERROR" "Ошибка перезапуска matrix-auth-service"
                return 1
            fi
        else
            log "ERROR" "Не удалось удалить $type_name"
            return 1
        fi
    }

    # Функция для установки предустановленного набора заблокированных имен
    set_default_banned_usernames() {
        log "INFO" "Установка стандартного набора заблокированных имен..."
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Стандартный набор заблокированных имен
        local default_banned='
{
  "literals": ["admin", "root", "administrator", "system", "support", "help", "info", "mail", "postmaster", "hostmaster", "webmaster", "abuse", "noreply", "no-reply", "security", "test", "user", "guest", "api", "www", "ftp", "mx", "ns", "dns", "smtp", "pop", "imap"],
  "substrings": ["admin", "root", "system"],
  "prefixes": ["admin-", "root-", "system-", "support-", "help-"],
  "suffixes": ["-admin", "-root", "-system", "-support"],
  "regexes": ["^admin.*", "^root.*", "^system.*", ".*admin$", ".*root$"]
}'
        
        # Инициализируем структуру
        yq eval -i '.policy.data.registration.banned_usernames //= {}' "$MAS_CONFIG_FILE"
        
        # Устанавливаем стандартные значения
        echo "$default_banned" | yq eval -i '.policy.data.registration.banned_usernames = .' "$MAS_CONFIG_FILE"
        
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        log "INFO" "Перезапуск MAS для применения изменений..."
        if systemctl restart matrix-auth-service; then
            log "SUCCESS" "Стандартный набор заблокированных имен установлен"
        else
            log "ERROR" "Ошибка перезапуска matrix-auth-service"
            return 1
        fi
    }

    # Функция для полной очистки заблокированных имен
    clear_all_banned_usernames() {
        if ask_confirmation "Вы уверены, что хотите удалить ВСЕ заблокированные имена?"; then
            # Создаем резервную копию
            cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
            
            # Удаляем всю секцию
            yq eval -i 'del(.policy.data.registration.banned_usernames)' "$MAS_CONFIG_FILE"
            
            # Устанавливаем права
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
            chmod 600 "$MAS_CONFIG_FILE"
            
            log "INFO" "Перезапуск MAS для применения изменений..."
            if systemctl restart matrix-auth-service; then
                log "SUCCESS" "Все заблокированные имена удалены"
            else
                log "ERROR" "Ошибка перезапуска matrix-auth-service"
                return 1
            fi
        fi
    }

    while true; do
        show_current_banned
        
        echo
        safe_echo "Управление заблокированными именами:"
        safe_echo "1. Добавить точное имя (literals)"
        safe_echo "2. Добавить подстроку (substrings)"
        safe_echo "3. Добавить регулярное выражение (regexes)"
        safe_echo "4. Добавить префикс (prefixes)"
        safe_echo "5. Добавить суффикс (suffixes)"
        safe_echo "6. Удалить точное имя"
        safe_echo "7. Удалить подстроку"
        safe_echo "8. Удалить регулярное выражение"
        safe_echo "9. Удалить префикс"
        safe_echo "10. Удалить суффикс"
        safe_echo "11. Установить стандартный набор"
        safe_echo "12. Очистить все заблокированные имена"
        safe_echo "13. Назад"

        read -p "Выберите действие [1-13]: " action

        case $action in
            1) add_banned_username "literal" "Точное имя" "literals" ;;
            2) add_banned_username "substring" "Подстрока" "substrings" ;;
            3) add_banned_username "regex" "Регулярное выражение" "regexes" ;;
            4) add_banned_username "prefix" "Префикс" "prefixes" ;;
            5) add_banned_username "suffix" "Суффикс" "suffixes" ;;
            6) remove_banned_username "literal" "точное имя" "literals" ;;
            7) remove_banned_username "substring" "подстрока" "substrings" ;;
            8) remove_banned_username "regex" "регулярное выражение" "regexes" ;;
            9) remove_banned_username "prefix" "префикс" "prefixes" ;;
            10) remove_banned_username "suffix" "суффикс" "suffixes" ;;
            11) set_default_banned_usernames ;;
            12) clear_all_banned_usernames ;;
            13) return 0 ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 13 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Управление токенами регистрации MAS
manage_mas_registration_tokens() {
    print_header "УПРАВЛЕНИЕ ТОКЕНАМИ РЕГИСТРАЦИИ MAS" "$BLUE"

    # Функция для создания токена регистрации
    create_registration_token() {
        print_header "СОЗДАНИЕ ТОКЕНА РЕГИСТРАЦИИ" "$CYAN"
        
        # Параметры токена
        read -p "Введите кастомный токен (или оставьте пустым для автогенерации): " custom_token
        read -p "Лимит использований (или оставьте пустым для неограниченного): " usage_limit
        read -p "Срок действия в секундах (или оставьте пустым для бессрочного): " expires_in
        
        # Формируем команду
        local cmd="mas manage issue-user-registration-token --config $MAS_CONFIG_FILE"
        
        if [ -n "$custom_token" ]; then
            cmd="$cmd --token '$custom_token'"
        fi
        
        if [ -n "$usage_limit" ]; then
            cmd="$cmd --usage-limit $usage_limit"
        fi
        
        if [ -n "$expires_in" ]; then
            cmd="$cmd --expires-in $expires_in"
        fi
        
        log "INFO" "Создание токена регистрации..."
        
        # Выполняем команду как пользователь MAS
        if sudo -u "$MAS_USER" eval "$cmd"; then
            log "SUCCESS" "Токен регистрации создан"
        else
            log "ERROR" "Ошибка создания токена регистрации"
        fi
    }
    
    # Функция для показа информации о токенах
    show_registration_tokens_info() {
        print_header "ИНФОРМАЦИЯ О ТОКЕНАХ РЕГИСТРАЦИИ" "$CYAN"
        
        safe_echo "Токены регистрации позволяют контролировать регистрацию пользователей."
        safe_echo "Когда включено требование токенов (registration_token_required: true),"
        safe_echo "пользователи должны предоставить действительный токен для регистрации."
        echo
        safe_echo "${BOLD}Как использовать токены:${NC}"
        safe_echo "1. Создайте токен с помощью этого меню"
        safe_echo "2. Передайте токен пользователю"
        safe_echo "3. При регистрации пользователь вводит токен"
        safe_echo "4. После использования лимит токена уменьшается"
        echo
        safe_echo "${BOLD}Параметры токенов:${NC}"
        safe_echo "• ${CYAN}Кастомный токен${NC} - задайте свою строку (или автогенерация)"
        safe_echo "• ${CYAN}Лимит использований${NC} - сколько раз можно использовать"
        safe_echo "• ${CYAN}Срок действия${NC} - время жизни токена в секундах"
        echo
        safe_echo "${BOLD}Примеры сроков действия:${NC}"
        safe_echo "• 3600 = 1 час"
        safe_echo "• 86400 = 1 день"
        safe_echo "• 604800 = 1 неделя"
        safe_echo "• 2592000 = 1 месяц"
    }

    while true; do
        # Показываем текущий статус токенов
        local token_status=$(get_mas_token_registration_status)
        
        case "$token_status" in
            "enabled") safe_echo "• Токены регистрации: ${GREEN}ТРЕБУЮТСЯ${NC}" ;;
            "disabled") safe_echo "• Токены регистрации: ${RED}НЕ ТРЕБУЮТСЯ${NC}" ;;
            *) safe_echo "• Токены регистрации: ${YELLOW}НЕИЗВЕСТНО${NC}" ;;
        esac
        
        echo
        safe_echo "Управление токенами регистрации:"
        safe_echo "1. Включить требование токенов регистрации"
        safe_echo "2. Отключить требование токенов регистрации"
        safe_echo "3. Создать новый токен регистрации"
        safe_echo "4. Показать информацию о токенах"
        safe_echo "5. Назад"

        read -p "Выберите действие [1-5]: " action

        case $action in
            1)
                set_mas_config_value "registration_token_required" "true"
                ;;
            2)
                set_mas_config_value "registration_token_required" "false"
                ;;
            3)
                create_registration_token
                ;;
            4)
                show_registration_tokens_info
                ;;
            5)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 5 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Управление SSO провайдителями
manage_sso_providers() {
    print_header "УПРАВЛЕНИЕ ВНЕШНИМИ ПРОВАЙДЕРАМИ (SSO)" "$BLUE"

    # Проверка наличия yq
    if ! check_yq_dependency; then
        read -p "Нажмите Enter для возврата..."
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
        local timestamp=$(printf '%010x' $(date +%s))
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

        print_header "NAСТРОЙКА $human_name SSO" "$CYAN"
        case $provider_name in
            "google")
                safe_echo "1. Перейдите в Google API Console: https://console.developers.google.com/apis/credentials"
                safe_echo "2. Нажмите 'CREATE CREDENTIALS' -> 'OAuth client ID'. "
                safe_echo "3. Выберите 'Web application'."
                safe_echo "4. В 'Authorized redirect URIs' добавьте URI вашего MAS. Он будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Скопируйте 'Client ID' и 'Client Secret'."
                ;;
            "github")
                safe_echo "1. Перейдите в 'Developer settings' вашего GitHub профиля: https://github.com/settings/developers"
                safe_echo "2. Выберите 'OAuth Apps' -> 'New OAuth App'."
                safe_echo "3. 'Homepage URL': URL вашего MAS (например, https://auth.your-domain.com)."
                safe_echo "4. 'Authorization callback URL': URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Скопируйте 'Client ID' и сгенерируйте 'Client Secret'."
                ;;
            "gitlab")
                safe_echo "1. Перейдите в 'Applications' в настройках вашего профиля GitLab: https://gitlab.com/-/profile/applications"
                safe_echo "2. Создайте новое приложение."
                safe_echo "3. В 'Redirect URI' укажите URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "4. Включите скоупы: 'openid', 'profile', 'email'."
                safe_echo "5. Сохраните и скопируйте 'Application ID' (это Client ID) и 'Secret'."
                ;;
            "discord")
                safe_echo "1. Перейдите на Discord Developer Portal: https://discord.com/developers/applications"
                safe_echo "2. Создайте новое приложение."
                safe_echo "3. Перейдите во вкладку 'OAuth2'."
                safe_echo "4. В 'Redirects' добавьте URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Сохраните изменения и скопируйте 'Client ID' и 'Client Secret'."
                ;;
        esac
        echo
        read -p "Введите Client ID: " client_id
        read -p "Введите Client Secret: " client_secret
        if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
            log "ERROR" "Client ID и Client Secret не могут быть пустыми."
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        local ulid=$(generate_ulid)
        local mas_public_base=$(yq eval '.http.public_base' "$MAS_CONFIG_FILE")
        local redirect_uri="${mas_public_base}/upstream/callback/${ulid}"
        safe_echo "Ваш Redirect URI для настройки в $human_name: $redirect_uri"
        echo
        if ! ask_confirmation "Продолжить добавление провайдера?"; then
            return
        fi
        local provider_yaml=$(cat <<EOF
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
        if [ -n "$extra_config" ]; then
            provider_yaml=$(echo "$provider_yaml" | yq eval '. as $item | '"$extra_config"' | $item * .' -)
        fi
        yq eval -i '.upstream_oauth2.providers += ['"$provider_yaml"']' "$MAS_CONFIG_FILE"
        sync_and_restart_mas
        read -p "Нажмите Enter для продолжения..."
    }

    # Функция удаления провайдера
    remove_sso_provider() {
        print_header "УДАЛЕНИЕ SSO-ПРОВАЙДЕРА" "$RED"
        local providers=$(yq eval '.upstream_oauth2.providers[] | .id + " " + .human_name' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ -z "$providers" ] || [ "$providers" = "null null" ]; then
            safe_echo "Нет настроенных SSO-провайдеров для удаления."
            read -p "Нажмите Enter для продолжения..."
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
        read -p "Нажмите Enter для продолжения..."
    }

    while true; do
        print_header "УПРАВЛЕНИЕ SSO" "$BLUE"
        safe_echo "Текущие SSO-провайдеры:"
        local current_providers=$(yq eval -o=json '.upstream_oauth2.providers' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ -z "$current_providers" ] || [ "$current_providers" = "null" ] || [ "$current_providers" = "[]" ]; then
            safe_echo "SSO-провайдеры не настроены."
        else
            echo "$current_providers" | yq eval -P '.[] | .human_name + " (ID: " + .id + ")"' - 2>/dev/null || safe_echo "Ошибка отображения провайдеров"
        fi
        echo
        safe_echo "Доступные опции:"
        safe_echo "1. ➕ Добавить Google"
        safe_echo "2. ➕ Добавить GitHub"
        safe_echo "3. ➕ Добавить GitLab"
        safe_echo "4. ➕ Добавить Discord"
        safe_echo "5. 🗑️  Удалить провайдера"
        safe_echo "6. ↩️  Вернуться в главное меню"
        echo
        read -p "Выберите опцию [1-6]: " choice
        case $choice in
            1)
                add_sso_provider "google" "Google" "google" "" "openid profile email" '.issuer = "https://accounts.google.com" | .token_endpoint_auth_method = "client_secret_post"'
                ;;
            2)
                add_sso_provider "github" "GitHub" "github" "" "read:user" '.discovery_mode = "disabled" | .fetch_userinfo = true | .token_endpoint_auth_method = "client_secret_post" | .authorization_endpoint = "https://github.com/login/oauth/authorize" | .token_endpoint = "https://github.com/login/oauth/access_token" | .userinfo_endpoint = "https://api.github.com/user" | .claims_imports.subject.template = "{{ userinfo_claims.id }}"'
                ;;
            3)
                add_sso_provider "gitlab" "GitLab" "gitlab" "" "openid profile email" '.issuer = "https://gitlab.com" | .token_endpoint_auth_method = "client_secret_post"'
                ;;
            4)
                add_sso_provider "discord" "Discord" "discord" "" "identify email" '.discovery_mode = "disabled" | .fetch_userinfo = true | .token_endpoint_auth_method = "client_secret_post" | .authorization_endpoint = "https://discord.com/oauth2/authorize" | .token_endpoint = "https://discord.com/api/oauth2/token" | .userinfo_endpoint = "https://discord.com/api/users/@me"'
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

# Меню управления регистрацией MAS
manage_mas_registration() {
    print_header "УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ MATRIX AUTHENTICATION SERVICE" "$BLUE"

    if ! check_yq_dependency; then
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    while true; do
        # Показываем текущий статус
        local current_status=$(get_mas_registration_status)
        local token_status=$(get_mas_token_registration_status)
        
        safe_echo "Текущий статус регистрации:"
        case "$current_status" in
            "enabled") safe_echo "• Открытая регистрация: ${GREEN}ВКЛЮЧЕНА${NC}" ;;
            "disabled") safe_echo "• Открытая регистрация: ${RED}ОТКЛЮЧЕНА${NC}" ;;
            *) safe_echo "• Открытая регистрация: ${YELLOW}НЕИЗВЕСТНО${NC}" ;;
        esac
        
        case "$token_status" in
            "enabled") safe_echo "• Регистрация по токенам: ${GREEN}ТРЕБУЕТСЯ${NC}" ;;
            "disabled") safe_echo "• Регистрация по токенам: ${RED}НЕ ТРЕБУЕТСЯ${NC}" ;;
            *) safe_echo "• Регистрация по токенам: ${YELLOW}НЕИЗВЕСТНО${NC}" ;;
        esac
        
        echo
        safe_echo "Управление регистрацией MAS:"
        safe_echo "1. Включить открытую регистрацию"
        safe_echo "2. Выключить открытую регистрацию"
        safe_echo "3. Включить требование токенов регистрации"
        safe_echo "4. Отключить требование токенов регистрации"
        safe_echo "5. Назад"

        read -p "Выберите действие [1-5]: " action

        case $action in
            1)
                set_mas_config_value "password_registration_enabled" "true"
                ;;
            2)
                set_mas_config_value "password_registration_enabled" "false"
                ;;
            3)
                set_mas_config_value "registration_token_required" "true"
                ;;
            4)
                set_mas_config_value "registration_token_required" "false"
                ;;
            5)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
    done
}

# Главное меню модуля
show_main_menu() {
    while true; do
        print_header "MATRIX AUTHENTICATION SERVICE (MAS) - УПРАВЛЕНИЕ" "$MAGENTA"
        
        # Проверяем статус MAS
        if systemctl is-active --quiet matrix-auth-service 2>/dev/null; then
            safe_echo "${GREEN}✅ Matrix Authentication Service: АКТИВЕН${NC}"
        else
            safe_echo "${RED}❌ Matrix Authentication Service: НЕ АКТИВЕН${NC}"
        fi
        
        if [ -f "$CONFIG_DIR/mas.conf" ]; then
            local mas_mode=$(grep "MAS_MODE=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"' 2>/dev/null)
            local mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"' 2>/dev/null)
            if [ -n "$mas_mode" ]; then
                safe_echo "${BLUE}ℹ️  Режим: $mas_mode${NC}"
            fi
            if [ -n "$mas_port" ]; then
                safe_echo "${BLUE}ℹ️  Порт: $mas_port${NC}"
            fi
        fi
        
        echo
        safe_echo "Доступные действия:"
        safe_echo "${GREEN}1.${NC} 📊 Проверить статус MAS"
        safe_echo "${GREEN}2.${NC} 🗑️  Удалить MAS"
        safe_echo "${GREEN}3.${NC} 🔍 Диагностика MAS"
        safe_echo "${GREEN}4.${NC} 🔧 Исправить поврежденную конфигурацию"
        safe_echo "${GREEN}5.${NC} 👥 Управление регистрацией MAS"
        safe_echo "${GREEN}6.${NC} 🔐 Управление SSO-провайдерами"
        safe_echo "${GREEN}7.${NC} 🤖 Настройки CAPTCHA"
        safe_echo "${GREEN}8.${NC} 🚫 Заблокированные имена пользователей"
        safe_echo "${GREEN}9.${NC} 🎫 Токены регистрации"
        safe_echo "${GREEN}10.${NC} ↩️  Назад в главное меню"

        read -p "$(safe_echo "${YELLOW}Выберите действие [1-10]: ${NC}")" action

        case $action in
            1)
                check_mas_status
                ;;
            2)
                uninstall_mas
                ;;
            3)
                diagnose_mas
                ;;
            4)
                fix_mas_config_corruption
                ;;
            5)
                manage_mas_registration
                ;;
            6)
                manage_sso_providers
                ;;
            7)
                manage_captcha_settings
                ;;
            8)
                manage_banned_usernames
                ;;
            9)
                manage_mas_registration_tokens
                ;;
            10)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 10 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Главная функция управления MAS
main() {
    # Проверяем, что MAS установлен
    if ! command -v mas >/dev/null 2>&1 && [ ! -f "$MAS_CONFIG_FILE" ]; then
        print_header "MATRIX AUTHENTICATION SERVICE НЕ УСТАНОВЛЕН" "$RED"
        log "ERROR" "Matrix Authentication Service не установлен"
        log "INFO" "Установите MAS через главное меню:"
        log "INFO" "  Дополнительные компоненты → Matrix Authentication Service (MAS)"
        return 1
    fi
    
    show_main_menu
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
