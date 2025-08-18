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

    # Удаление файлов MAS share
    if [ -d "/usr/local/share/mas-cli" ]; then
        log "INFO" "Удаление файлов MAS share..."
        rm -rf /usr/local/share/mas-cli
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

    # Опционально удаляем пользователя matrix-synapse
    if ask_confirmation "Удалить также системного пользователя matrix-synapse?"; then
        if id "$MAS_USER" &>/dev/null; then
            userdel "$MAS_USER" 2>/dev/null
            log "INFO" "Пользователь $MAS_USER удален"
        fi
    fi

    log "SUCCESS" "MAS успешно удалён"
}

# Проверка критически важных файлов MAS
check_mas_files() {
    local mas_share_dir="/usr/local/share/mas-cli"
    local policy_path="$mas_share_dir/policy.wasm"
    local assets_path="$mas_share_dir/assets"
    local templates_path="$mas_share_dir/templates"
    local translations_path="$mas_share_dir/translations"
    local manifest_path="$mas_share_dir/manifest.json"
    
    log "INFO" "Проверка файлов MAS share..."
    
    if [ ! -f "$policy_path" ]; then
        log "ERROR" "❌ Критический файл policy.wasm отсутствует: $policy_path"
        return 1
    else
        log "SUCCESS" "✅ Файл политики найден: $policy_path"
    fi
    
    if [ ! -d "$assets_path" ]; then
        log "WARN" "⚠️  Assets отсутствуют: $assets_path"
    else
        log "SUCCESS" "✅ Assets найдены: $assets_path"
    fi
    
    if [ ! -d "$templates_path" ]; then
        log "WARN" "⚠️  Templates отсутствуют: $templates_path"
    else
        log "SUCCESS" "✅ Templates найдены: $templates_path"
    fi
    
    if [ ! -d "$translations_path" ]; then
        log "WARN" "⚠️  Translations отсутствуют: $translations_path"
    else
        log "SUCCESS" "✅ Translations найдены: $translations_path"
    fi
    
    if [ ! -f "$manifest_path" ]; then
        log "WARN" "⚠️  Manifest отсутствует: $manifest_path"
    else
        log "SUCCESS" "✅ Manifest найден: $manifest_path"
    fi
    
    return 0
}

# Диагностика MAS
diagnose_mas() {
    print_header "ДИАГНОСТИКА MATRIX AUTHENTICATION SERVICE" "$BLUE"

    log "INFO" "Диагностика MAS..."

    # Проверка критических файлов MAS
    log "INFO" "Проверка файлов MAS..."
    if ! check_mas_files; then
        log "ERROR" "Обнаружены проблемы с файлами MAS"
    fi

    # Проверка состояния службы MAS
    log "INFO" "Проверка службы matrix-auth-service..."
    systemctl status matrix-auth-service --no-pager -l || log "ERROR" "Служба matrix-auth-service недоступна"

    # Проверка логов MAS
    log "INFO" "Последние логи matrix-auth-service:"
    journalctl -u matrix-auth-service --no-pager -n 20 || log "ERROR" "Не удалось получить логи"

    # Проверка конфигурационных файлов MAS
    if [ -f "$MAS_CONFIG_FILE" ]; then
        log "INFO" "Проверка конфигурации MAS..."
        
        # Проверка ключевых секций конфигурации
        log "INFO" "Проверка секций конфигурации..."
        local required_sections=("http" "database" "matrix" "secrets")
        for section in "${required_sections[@]}"; do
            if yq eval ".$section" "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
                log "SUCCESS" "Секция $section: ✅"
            else
                log "ERROR" "Секция $section: ❌ ОТСУТСТВУЕТ"
            fi
        done
        
        # Проверка секции policy (может отсутствовать, если используется встроенная политика)
        if yq eval ".policy" "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
            log "SUCCESS" "Секция policy: ✅"
            
            # Проверяем правильность путей в policy секции
            local policy_wasm=$(yq eval '.policy.wasm_module' "$MAS_CONFIG_FILE" 2>/dev/null)
            if [ -n "$policy_wasm" ] && [ "$policy_wasm" != "null" ]; then
                if [ -f "$policy_wasm" ]; then
                    log "SUCCESS" "Policy файл найден: $policy_wasm"
                else
                    log "ERROR" "Policy файл отсутствует: $policy_wasm"
                fi
            fi
        else
            log "INFO" "Секция policy отсутствует (используется встроенная политика)"
        fi
        
        # Проверка секции templates
        if yq eval ".templates" "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
            log "SUCCESS" "Секция templates: ✅"
            
            # Проверяем правильность путей в templates секции
            local templates_path=$(yq eval '.templates.path' "$MAS_CONFIG_FILE" 2>/dev/null)
            if [ -n "$templates_path" ] && [ "$templates_path" != "null" ]; then
                if [ -d "$templates_path" ]; then
                    log "SUCCESS" "Templates директория найдена: $templates_path"
                else
                    log "ERROR" "Templates директория отсутствует: $templates_path"
                fi
            fi
            
            local manifest_path=$(yq eval '.templates.assets_manifest' "$MAS_CONFIG_FILE" 2>/dev/null)
            if [ -n "$manifest_path" ] && [ "$manifest_path" != "null" ]; then
                if [ -f "$manifest_path" ]; then
                    log "SUCCESS" "Assets manifest найден: $manifest_path"
                else
                    log "ERROR" "Assets manifest отсутствует: $manifest_path"
                fi
            fi
        else
            log "WARN" "Секция templates отсутствует"
        fi
        
        # Проверка подключения к базе данных mas_db
        log "INFO" "Проверка подключения к базе данных MAS..."
        if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
            local db_user=$(grep "MAS_DB_USER=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"' 2>/dev/null)
            local db_password=$(grep "MAS_DB_PASSWORD=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"' 2>/dev/null)
            local db_name=$(grep "MAS_DB_NAME=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"' 2>/dev/null)
            
            if [ -n "$db_user" ] && [ -n "$db_password" ] && [ -n "$db_name" ]; then
                if PGPASSWORD="$db_password" psql -h localhost -U "$db_user" -d "$db_name" -c "SELECT 1;" >/dev/null 2>&1; then
                    log "SUCCESS" "Подключение к базе данных MAS работает"
                else
                    log "ERROR" "Не удается подключиться к базе данных MAS"
                fi
            else
                log "WARN" "Неполная информация о базе данных в mas_database.conf"
            fi
        else
            log "WARN" "Файл mas_database.conf не найден"
        fi
        
        # Проверка MAS doctor если команда доступна
        if command -v mas >/dev/null 2>&1; then
            log "INFO" "Запуск mas doctor для проверки конфигурации..."
            if mas doctor --config "$MAS_CONFIG_FILE"; then
                log "SUCCESS" "Конфигурация MAS прошла проверку mas doctor"
            else
                log "ERROR" "Конфигурация MAS имеет проблемы согласно mas doctor"
            fi
        else
            log "WARN" "Команда 'mas' не найдена, пропускаем проверку mas doctor"
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
                
                # Дополнительная проверка OIDC discovery
                local discovery_url="http://localhost:$mas_port/.well-known/openid-configuration"
                if curl -s -f --connect-timeout 3 "$discovery_url" >/dev/null 2>&1; then
                    log "SUCCESS" "OIDC discovery endpoint доступен"
                else
                    log "WARN" "OIDC discovery endpoint недоступен"
                fi
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

# Просмотр секции account конфигурации MAS (ИСПРАВЛЕННАЯ ВЕРСИЯ)
view_mas_account_config() {
    print_header "КОНФИГУРАЦИЯ СЕКЦИИ ACCOUNT В MAS" "$CYAN"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    if ! check_yq_dependency; then
        return 1
    fi
    
    safe_echo "${BOLD}Текущая конфигурация секции account:${NC}"
    echo
    
    # Проверяем наличие секции account
    if ! yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        safe_echo "${RED}Секция account отсутствует в конфигурации MAS${NC}"
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Используйте пункты меню выше для включения настроек регистрации"
        safe_echo "• Секция account будет создана автоматически при первом изменении"
        return 1
    fi
    
    local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$account_content" = "null" ] || [ -z "$account_content" ]; then
        safe_echo "${RED}Секция account пуста или повреждена${NC}"
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Попробуйте переинициализировать секцию через пункт '1. Включить открытую регистрацию'"
        return 1
    fi
    
    # Показываем основные параметры регистрации
    safe_echo "${CYAN}🔐 Настройки регистрации:${NC}"
    
    local password_reg=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$password_reg" = "true" ]; then
        safe_echo "  • password_registration_enabled: ${GREEN}true${NC} (открытая регистрация включена)"
    elif [ "$password_reg" = "false" ]; then
        safe_echo "  • password_registration_enabled: ${RED}false${NC} (открытая регистрация отключена)"
    else
        safe_echo "  • password_registration_enabled: ${YELLOW}$password_reg${NC}"
    fi
    
    local token_req=$(yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$token_req" = "true" ]; then
        safe_echo "  • registration_token_required: ${GREEN}true${NC} (требуется токен регистрации)"
    elif [ "$token_req" = "false" ]; then
        safe_echo "  • registration_token_required: ${RED}false${NC} (токен регистрации не требуется)"
    else
        safe_echo "  • registration_token_required: ${YELLOW}$token_req${NC}"
    fi
    
    echo
    safe_echo "${CYAN}👤 Настройки управления аккаунтами:${NC}"
    
    # Остальные параметры account
    local email_change=$(yq eval '.account.email_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • email_change_allowed: ${BLUE}$email_change${NC}"
    
    local display_change=$(yq eval '.account.displayname_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • displayname_change_allowed: ${BLUE}$display_change${NC}"
    
    local password_change=$(yq eval '.account.password_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • password_change_allowed: ${BLUE}$password_change${NC}"
    
    local password_recovery=$(yq eval '.account.password_recovery_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • password_recovery_enabled: ${BLUE}$password_recovery${NC}"
    
    local account_deactivation=$(yq eval '.account.account_deactivation_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • account_deactivation_allowed: ${BLUE}$account_deactivation${NC}"
    
    echo
    safe_echo "${CYAN}📄 Полная секция account (YAML):${NC}"
    echo "────────────────────────────────────────────────────────────"
    
    # Показываем полную секцию account в YAML формате с правильной обработкой ошибок
    if yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null; then
        log "DEBUG" "Секция account успешно отображена"
    else
        safe_echo "${RED}Ошибка чтения секции account${NC}"
        safe_echo "Возможные причины:"
        safe_echo "• Поврежденный YAML синтаксис"
        safe_echo "• Проблемы с правами доступа к файлу"
        safe_echo "• Неполная установка yq"
    fi
    
    echo "────────────────────────────────────────────────────────────"
    
    echo
    safe_echo "${YELLOW}📝 Примечание:${NC}"
    safe_echo "• Изменения этих параметров требуют перезапуска MAS"
    safe_echo "• Файл конфигурации: $MAS_CONFIG_FILE"
    safe_echo "• Для изменения используйте пункты меню выше"
    echo
    safe_echo "${BLUE}ℹ️  Дополнительная информация:${NC}"
    safe_echo "• Проверить статус MAS: systemctl status matrix-auth-service"
    safe_echo "• Логи MAS: journalctl -u matrix-auth-service -n 20"
    safe_echo "• Диагностика MAS: mas doctor --config $MAS_CONFIG_FILE"
}

# Функция инициализации секции account в конфигурации MAS (ПОЛНОСТЬЮ ИСПРАВЛЕННАЯ ВЕРСИЯ)
initialize_mas_account_section() {
    log "INFO" "Инициализация секции account в конфигурации MAS..."
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    if ! check_yq_dependency; then
        return 1
    fi
    
    # Проверяем, есть ли уже секция account
    if yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$account_content" != "null" ] && [ -n "$account_content" ]; then
            log "INFO" "Секция account уже существует"
            return 0
        fi
    fi
    
    # Проверяем права доступа к файлу конфигурации
    if [ ! -w "$MAS_CONFIG_FILE" ]; then
        log "WARN" "Файл конфигурации MAS не доступен для записи, исправляю права доступа..."
        if ! chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Не удалось изменить владельца файла $MAS_CONFIG_FILE"
            return 1
        fi
        if ! chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Не удалось изменить права доступа к файлу $MAS_CONFIG_FILE"
            return 1
        fi
        log "SUCCESS" "Права доступа к файлу конфигурации исправлены"
    fi
    
    # Создаем резервную копию
    if ! cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"; then
        log "ERROR" "Не удалось создать резервную копию файла конфигурации"
        return 1
    fi
    
    log "INFO" "Добавление секции account в конфигурацию MAS..."
    
    # ИСПРАВЛЕНО: Используем безопасный метод добавления секции без временных файлов
    # Метод 1: Используем yq eval -i напрямую (in-place editing)
    log "INFO" "Попытка добавления секции account с помощью yq eval -i..."
    
    if yq eval -i '.account = {
        "password_registration_enabled": false,
        "registration_token_required": false,
        "email_change_allowed": true,
        "displayname_change_allowed": true,
        "password_change_allowed": true,
        "password_recovery_enabled": false,
        "account_deactivation_allowed": false
    }' "$MAS_CONFIG_FILE" 2>/dev/null; then
        
        log "SUCCESS" "Секция account добавлена с помощью yq eval -i"
        
        # Проверяем, что остальные секции остались на месте
        local required_sections=("http" "database" "matrix" "secrets")
        local missing_sections=()
        
        for section in "${required_sections[@]}"; do
            if ! yq eval ".$section" "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
                missing_sections+=("$section")
            fi
        done
        
        if [ ${#missing_sections[@]} -gt 0 ]; then
            log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: После добавления account исчезли секции: ${missing_sections[*]}"
            log "ERROR" "Восстанавливаем из резервной копии..."
            local latest_backup=$(ls -t "$MAS_CONFIG_FILE.backup"* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                cp "$latest_backup" "$MAS_CONFIG_FILE"
                chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null || true
                chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || true
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            return 1
        fi
        
    else
        # Метод 2: Альтернативный способ - добавление в конец файла
        log "WARN" "yq eval -i не сработал, используем альтернативный метод..."
        
        # Создаем временную директорию для безопасной работы
        local temp_dir=$(mktemp -d -t mas_config_XXXXXX)
        if [ ! -d "$temp_dir" ]; then
            log "ERROR" "Не удалось создать временную директорию"
            return 1
        fi
        
        local temp_file="$temp_dir/config.yaml"
        
        # Копируем оригинальный файл
        if ! cp "$MAS_CONFIG_FILE" "$temp_file"; then
            log "ERROR" "Не удалось скопировать конфигурацию во временный файл"
            rm -rf "$temp_dir"
            return 1
        fi
        
        # Проверяем, что в конце файла есть пустая строка
        if [ -s "$temp_file" ] && [ "$(tail -c1 "$temp_file" | wc -l)" -eq 0 ]; then
            echo "" >> "$temp_file"
        fi
        
        # Добавляем секцию account в конец файла
        cat >> "$temp_file" << 'EOF'

# Account management settings (added automatically)
account:
  password_registration_enabled: false
  registration_token_required: false
  email_change_allowed: true
  displayname_change_allowed: true
  password_change_allowed: true
  password_recovery_enabled: false
  account_deactivation_allowed: false
EOF
        
        # Проверяем валидность YAML
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$temp_file'))" 2>/dev/null; then
                log "ERROR" "YAML поврежден после добавления секции account через альтернативный метод"
                rm -rf "$temp_dir"
                return 1
            fi
        fi
        
        # Заменяем оригинальный файл
        if ! mv "$temp_file" "$MAS_CONFIG_FILE"; then
            log "ERROR" "Не удалось записать изменения в $MAS_CONFIG_FILE"
            rm -rf "$temp_dir"
            return 1
        fi
        
        # Удаляем временную директорию
        rm -rf "$temp_dir"
        
        log "SUCCESS" "Секция account добавлена альтернативным методом"
    fi
    
    # Устанавливаем правильные права доступа
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || true
    
    # Финальная проверка целостности конфигурации
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "YAML поврежден после добавления секции account!"
            log "ERROR" "Восстанавливаю из резервной копии..."
            local latest_backup=$(ls -t "$MAS_CONFIG_FILE.backup"* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                cp "$latest_backup" "$MAS_CONFIG_FILE"
                chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null || true
                chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || true
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            return 1
        fi
    fi
    
    # Проверяем, что секция account действительно добавлена
    if yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        local account_check=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$account_check" = "false" ]; then
            log "SUCCESS" "Секция account успешно добавлена и проверена"
        else
            log "WARN" "Секция account добавлена, но содержимое неожиданное"
        fi
    else
        log "ERROR" "Секция account не была добавлена"
        return 1
    fi
    
    return 0
}

# Изменение параметра в YAML файле (ИСПРАВЛЕННАЯ ВЕРСИЯ)
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
    
    # Проверяем права доступа к файлу
    if [ ! -w "$MAS_CONFIG_FILE" ]; then
        log "WARN" "Файл конфигурации MAS не доступен для записи, исправляю права доступа..."
        # Пытаемся исправить права доступа
        if ! chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Не удалось изменить владельца файла $MAS_CONFIG_FILE"
            return 1
        fi
        if ! chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Не удалось изменить права доступа к файлу $MAS_CONFIG_FILE"
            return 1
        fi
        log "SUCCESS" "Права доступа к файлу конфигурации исправлены"
    fi
    
    log "INFO" "Изменение настройки $key на $value..."
    local full_path=""
    case "$key" in
        "password_registration_enabled"|"registration_token_required"|"email_change_allowed"|"displayname_change_allowed"|"password_change_allowed"|"password_recovery_enabled"|"account_deactivation_allowed")
            full_path=".account.$key"
            
            # Проверяем наличие секции account и инициализируем при необходимости
            if ! yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
                log "WARN" "Секция account отсутствует, инициализирую..."
                if ! initialize_mas_account_section; then
                    log "ERROR" "Не удалось инициализировать секцию account"
                    return 1
                fi
            fi
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
    if ! cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)" 2>/dev/null; then
        log "ERROR" "Не удалось создать резервную копию файла конфигурации"
        return 1
    fi
    
    # ИСПРАВЛЕНО: Используем yq eval -i напрямую для безопасного изменения
    log "INFO" "Применение изменения $full_path = $value..."
    
    if yq eval -i "$full_path = $value" "$MAS_CONFIG_FILE" 2>/dev/null; then
        log "SUCCESS" "Изменение применено с помощью yq eval -i"
    else
        log "ERROR" "Не удалось изменить $key в $MAS_CONFIG_FILE с помощью yq eval -i"
        
        # Альтернативный метод: создаем новый файл с изменениями
        log "WARN" "Пробуем альтернативный метод изменения конфигурации..."
        
        # Создаем временную директорию
        local temp_dir=$(mktemp -d -t mas_config_update_XXXXXX)
        if [ ! -d "$temp_dir" ]; then
            log "ERROR" "Не удалось создать временную директорию"
            return 1
        fi
        
        local temp_file="$temp_dir/config.yaml"
        
        # Используем yq для создания нового файла с изменениями
        if yq eval "$full_path = $value" "$MAS_CONFIG_FILE" > "$temp_file" 2>/dev/null; then
            # Проверяем валидность YAML
            if command -v python3 >/dev/null 2>&1; then
                if python3 -c "import yaml; yaml.safe_load(open('$temp_file'))" 2>/dev/null; then
                    # Заменяем оригинальный файл
                    if mv "$temp_file" "$MAS_CONFIG_FILE"; then
                        log "SUCCESS" "Изменение применено альтернативным методом"
                    else
                        log "ERROR" "Не удалось заменить оригинальный файл"
                        rm -rf "$temp_dir"
                        return 1
                    fi
                else
                    log "ERROR" "YAML поврежден после изменений альтернативным методом"
                    rm -rf "$temp_dir"
                    return 1
                fi
            else
                # Если Python недоступен, просто заменяем файл
                if mv "$temp_file" "$MAS_CONFIG_FILE"; then
                    log "SUCCESS" "Изменение применено альтернативным методом (без проверки YAML)"
                else
                    log "ERROR" "Не удалось заменить оригинальный файл"
                    rm -rf "$temp_dir"
                    return 1
                fi
            fi
        else
            log "ERROR" "Альтернативный метод также не сработал"
            rm -rf "$temp_dir"
            return 1
        fi
        
        # Очищаем временную директорию
        rm -rf "$temp_dir"
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || true
    
    # Проверяем валидность YAML после изменений
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "YAML файл поврежден после изменений, восстанавливаю резервную копию..."
            local latest_backup=$(ls -t "$MAS_CONFIG_FILE.backup"* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                cp "$latest_backup" "$MAS_CONFIG_FILE"
                chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null || true
                chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || true
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            return 1
        fi
    fi
    
    # Проверяем, что изменение действительно применилось
    local current_value=$(yq eval "$full_path" "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$current_value" = "$value" ]; then
        log "SUCCESS" "Изменение $key -> $value успешно применено и проверено"
    else
        log "WARN" "Изменение применено, но текущее значение ($current_value) не соответствует ожидаемому ($value)"
    fi
    
    log "INFO" "Перезапуск MAS для применения изменений..."
    if systemctl restart matrix-auth-service; then
        # Ждем небольшую паузу для запуска службы
        sleep 2
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "Настройка $key успешно изменена на $value"
        else
            log "ERROR" "MAS не запустился после изменения конфигурации"
            log "INFO" "Проверьте логи: journalctl -u matrix-auth-service -n 20"
            return 1
        fi
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
            "disabled") safe_echo "• Токены регистрации: ${RED}НЕ ТРЕБУЕТСЯ${NC}" ;;
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

    # Функция для инициализации структуры upstream_oauth2
    init_upstream_oauth2_structure() {
        log "INFO" "Инициализация структуры upstream_oauth2..."
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Инициализируем структуру upstream_oauth2 если не существует
        if ! yq eval -i '.upstream_oauth2 //= {}' "$MAS_CONFIG_FILE"; then
            log "ERROR" "Не удалось инициализировать секцию upstream_oauth2"
            return 1
        fi
        
        if ! yq eval -i '.upstream_oauth2.providers //= []' "$MAS_CONFIG_FILE"; then
            log "ERROR" "Не удалось инициализировать массив providers"
            return 1
        fi
        
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        log "SUCCESS" "Структура upstream_oauth2 инициализирована"
        return 0
    }

    # Функция для проверки существования секции upstream_oauth2
    check_upstream_oauth2_structure() {
        local upstream_section=$(yq eval '.upstream_oauth2' "$MAS_CONFIG_FILE" 2>/dev/null)
        local providers_section=$(yq eval '.upstream_oauth2.providers' "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ "$upstream_section" = "null" ] || [ "$providers_section" = "null" ]; then
            log "WARN" "Секция upstream_oauth2 отсутствует или неполная, инициализирую..."
            if ! init_upstream_oauth2_structure; then
                return 1
            fi
        fi
        return 0
    }

    # Функция для валидации JSON провайдера
    validate_provider_json() {
        local provider_json="$1"
        
        # Проверяем базовый JSON синтаксис
        if ! echo "$provider_json" | jq . >/dev/null 2>&1; then
            log "ERROR" "Неверный JSON синтаксис провайдера"
            return 1
        fi
        
        # Проверяем обязательные поля
        local required_fields=("id" "client_id" "client_secret" "scope")
        for field in "${required_fields[@]}"; do
            local value=$(echo "$provider_json" | jq -r ".$field" 2>/dev/null)
            if [ -z "$value" ] || [ "$value" = "null" ]; then
                log "ERROR" "Отсутствует обязательное поле: $field"
                return 1
            fi
        done
        
        # Проверяем формат ULID для ID
        local provider_id=$(echo "$provider_json" | jq -r '.id')
        if ! echo "$provider_id" | grep -qE '^[0-9A-Z]{26}$'; then
            log "ERROR" "ID провайдера должен быть валидным ULID (26 символов A-Z0-9)"
            return 1
        fi
        
        log "SUCCESS" "JSON провайдера прошел валидацию"
        return 0
    }

    # Функция для проверки существования провайдера
    check_provider_exists() {
        local provider_id="$1"
        
        local existing_provider=$(yq eval ".upstream_oauth2.providers[] | select(.id == \"$provider_id\")" "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ -n "$existing_provider" ] && [ "$existing_provider" != "null" ]; then
            return 0  # Провайдер существует
        else
            return 1  # Провайдер не существует
        fi
    }

    # Функция для синхронизации и перезапуска MAS
    sync_and_restart_mas() {
        log "INFO" "Синхронизация конфигурации MAS с базой данных..."
        
        # Проверяем YAML синтаксис перед синхронизацией
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                log "ERROR" "Ошибка в YAML синтаксе конфигурации после изменений!"
                log "ERROR" "Восстанавливаю резервную копию..."
                local latest_backup=$(ls -t "$MAS_CONFIG_FILE.backup"* 2>/dev/null | head -1)
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    cp "$latest_backup" "$MAS_CONFIG_FILE"
                    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null || true
                    chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || true
                    log "INFO" "Резервная копия восстановлена"
                fi
                return 1
            fi
        fi
        
        # Выполняем синхронизацию с базой данных
        if ! sudo -u "$MAS_USER" mas config sync --config "$MAS_CONFIG_FILE" --prune 2>/dev/null; then
            log "ERROR" "Ошибка синхронизации конфигурации MAS с базой данных"
            log "INFO" "Возможные причины: MAS не запущен, проблемы с БД, неверная конфигурация"
            
            # Пытаемся синхронизацию без --prune
            log "INFO" "Попытка синхронизации без --prune..."
            if ! sudo -u "$MAS_USER" mas config sync --config "$MAS_CONFIG_FILE" 2>/dev/null; then
                log "ERROR" "Синхронизация не удалась даже без --prune"
                return 1
            else
                log "WARN" "Синхронизация выполнена без --prune (старые провайдеры не удалены)"
            fi
        fi
        
        log "INFO" "Перезапуск MAS для применения изменений..."
        if systemctl restart matrix-auth-service; then
            # Ждем запуска службы
            sleep 3
            if systemctl is_active --quiet matrix-auth-service; then
                log "SUCCESS" "MAS успешно перезапущен"
                
                # Проверяем API
                local mas_port=""
                if [ -f "$CONFIG_DIR/mas.conf" ]; then
                    mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
                fi
                
                if [ -n "$mas_port" ]; then
                    local health_url="http://localhost:$mas_port/health"
                    if curl -s -f --connect-timeout 5 "$health_url" >/dev/null 2>&1; then
                        log "SUCCESS" "MAS API доступен - настройки SSO применены успешно"
                    else
                        log "WARN" "MAS запущен, но API пока недоступен (может требовать время на инициализацию)"
                    fi
                fi
                
                sleep 2
            else
                log "ERROR" "MAS не запустился после изменений"
                return 1
            fi
        else
            log "ERROR" "Ошибка перезапуска matrix-auth-service"
            return 1
        fi
        
        return 0
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

        print_header "НАСТРОЙКА $human_name SSO" "$CYAN"
        
        # Проверяем и инициализируем структуру upstream_oauth2
        if ! check_upstream_oauth2_structure; then
            log "ERROR" "Не удалось инициализировать структуру upstream_oauth2"
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
        
        # Показываем инструкции для настройки провайдителя
        case $provider_name in
            "google")
                safe_echo "Для настройки Google OAuth 2.0:"
                safe_echo "1. Перейдите в Google API Console: https://console.developers.google.com/apis/credentials"
                safe_echo "2. Нажмите 'CREATE CREDENTIALS' → 'OAuth client ID'"
                safe_echo "3. Выберите 'Web application'"
                safe_echo "4. В 'Authorized redirect URIs' добавьте URI вашего MAS (будет показан ниже)"
                safe_echo "5. Скопируйте 'Client ID' и 'Client Secret'"
                ;;
            "github")
                safe_echo "Для настройки GitHub OAuth:"
                safe_echo "1. Перейдите в Developer settings: https://github.com/settings/developers"
                safe_echo "2. Выберите 'OAuth Apps' → 'New OAuth App'"
                safe_echo "3. 'Homepage URL': URL вашего MAS"
                safe_echo "4. 'Authorization callback URL': URL для коллбэка (будет показан ниже)"
                safe_echo "5. Скопируйте 'Client ID' и сгенерируйте 'Client Secret'"
                ;;
            "gitlab")
                safe_echo "Для настройки GitLab OAuth:"
                safe_echo "1. Перейдите в Applications: https://gitlab.com/-/profile/applications"
                safe_echo "2. Создайте новое приложение"
                safe_echo "3. В 'Redirect URI' укажите URL для коллбэка (будет показан ниже)"
                safe_echo "4. Включите скоупы: 'openid', 'profile', 'email'"
                safe_echo "5. Сохраните и скопируйте 'Application ID' и 'Secret'"
                ;;
            "discord")
                safe_echo "Для настройки Discord OAuth:"
                safe_echo "1. Перейдите на Discord Developer Portal: https://discord.com/developers/applications"
                safe_echo "2. Создайте новое приложение"
                safe_echo "3. Перейдите во вкладку 'OAuth2'"
                safe_echo "4. В 'Redirects' добавьте URL для коллбэка (будет показан ниже)"
                safe_echo "5. Скопируйте 'Client ID' и 'Client Secret'"
                ;;
        esac
        
        echo
        read -p "Введите Client ID: " client_id
        read -p "Введите Client Secret: " client_secret
        
        # Валидация введенных данных
        if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
            log "ERROR" "Client ID и Client Secret не могут быть пустыми"
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
        
        # Генерируем уникальный ULID для провайдера
        local ulid=$(generate_ulid)
        
        # Проверяем, что такой ID еще не используется
        while check_provider_exists "$ulid"; do
            log "WARN" "ID $ulid уже используется, генерирую новый..."
            ulid=$(generate_ulid)
        done
        
        # Получаем public_base из конфигурации MAS
        local mas_public_base=$(yq eval '.http.public_base' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ -z "$mas_public_base" ] || [ "$mas_public_base" = "null" ]; then
            log "ERROR" "Не удается получить http.public_base из конфигурации MAS"
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
        
        # Формируем redirect URI
        local redirect_uri="${mas_public_base}/upstream/callback/${ulid}"
        
        safe_echo
        safe_echo "${BOLD}${GREEN}Ваш Redirect URI для настройки в $human_name:${NC}"
        safe_echo "${CYAN}$redirect_uri${NC}"
        safe_echo
        safe_echo "Скопируйте этот URI и добавьте его в настройки вашего OAuth приложения."
        echo
        
        if ! ask_confirmation "Вы добавили Redirect URI в настройки провайдителя и готовы продолжить?"; then
            log "INFO" "Настройка провайдителя отменена"
            return 0
        fi
        
        # Создаем JSON объект провайдера
        local provider_json=$(cat <<EOF
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
        
        # Добавляем дополнительную конфигурацию если есть
        if [ -n "$extra_config" ]; then
            log "INFO" "Применение дополнительной конфигурации для $provider_name..."
            provider_json=$(echo "$provider_json" | yq eval '. as $item | '"$extra_config"' | $item * .' - 2>/dev/null)
            if [ $? -ne 0 ]; then
                log "ERROR" "Ошибка применения дополнительной конфигурации"
                read -p "Нажмите Enter для продолжения..."
                return 1
            fi
        fi
        
        # Валидируем JSON провайдера
        if ! validate_provider_json "$provider_json"; then
            log "ERROR" "Провайдер не прошел валидацию"
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
        
        log "INFO" "Добавление провайдера $human_name в конфигурацию..."
        
        # Добавляем провайдера в конфигурацию
        if ! yq eval -i '.upstream_oauth2.providers += ['"$provider_json"']' "$MAS_CONFIG_FILE"; then
            log "ERROR" "Не удалось добавить провайдера в конфигурацию"
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
        
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        # Синхронизируем и перезапускаем MAS
        if sync_and_restart_mas; then
            log "SUCCESS" "Провайдер $human_name успешно добавлен!"
            safe_echo
            safe_echo "${BOLD}${GREEN}Настройка завершена:${NC}"
            safe_echo "• ID провайдера: ${CYAN}$ulid${NC}"
            safe_echo "• Redirect URI: ${CYAN}$redirect_uri${NC}"
            safe_echo "• Провайдер доступен для аутентификации пользователей"
        else
            log "ERROR" "Ошибка при применении настроек провайдителя"
        fi
        
        read -p "Нажмите Enter для продолжения..."
    }

    # Функция удаления провайдера
    remove_sso_provider() {
        print_header "УДАЛЕНИЕ SSO-ПРОВАЙДЕРА" "$RED"
        
        # Проверяем существование структуры upstream_oauth2
        if ! check_upstream_oauth2_structure; then
            safe_echo "Секция upstream_oauth2 отсутствует или повреждена."
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
        
        # Получаем список провайдеров
        local providers_list=$(yq eval '.upstream_oauth2.providers[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ -z "$providers_list" ] || [ "$providers_list" = "null" ]; then
            safe_echo "Нет настроенных SSO-провайдеров для удаления."
            read -p "Нажмите Enter для продолжения..."
            return 0
        fi
        
        # Показываем список провайдеров в удобном формате
        safe_echo "Список настроенных провайдеров:"
        echo
        
        local counter=1
        yq eval '.upstream_oauth2.providers[]' "$MAS_CONFIG_FILE" 2>/dev/null | while IFS= read -r provider; do
            if [ -n "$provider" ] && [ "$provider" != "null" ]; then
                local id=$(echo "$provider" | yq eval '.id' -)
                local name=$(echo "$provider" | yq eval '.human_name' -)
                local brand=$(echo "$provider" | yq eval '.brand_name' -)
                
                if [ -n "$id" ] && [ "$id" != "null" ]; then
                    printf "%d. %s (%s) - ID: %s\n" "$counter" "$name" "$brand" "$id"
                    counter=$((counter + 1))
                fi
            fi
        done
        
        echo
        read -p "Введите ID провайдера для удаления: " id_to_remove
        
        if [ -z "$id_to_remove" ]; then
            log "WARN" "ID не указан"
            return 0
        fi
        
        # Проверяем, что провайдер существует
        if ! check_provider_exists "$id_to_remove"; then
            log "ERROR" "Провайдер с ID '$id_to_remove' не найден"
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
        
        # Получаем информацию о провайдере для подтверждения
        local provider_info=$(yq eval ".upstream_oauth2.providers[] | select(.id == \"$id_to_remove\")" "$MAS_CONFIG_FILE" 2>/dev/null)
        local provider_name=$(echo "$provider_info" | yq eval '.human_name' -)
        
        safe_echo
        safe_echo "Информация о провайдере для удаления:"
        safe_echo "• ID: ${CYAN}$id_to_remove${NC}"
        safe_echo "• Название: ${CYAN}$provider_name${NC}"
        echo
        
        if ask_confirmation "Вы уверены, что хотите удалить этого провайдера?"; then
            log "INFO" "Удаление провайдера $provider_name (ID: $id_to_remove)..."
            
            # Создаем резервную копию
            cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
            
            # Удаляем провайдера
            if ! yq eval -i 'del(.upstream_oauth2.providers[] | select(.id == "'"$id_to_remove"'"))' "$MAS_CONFIG_FILE"; then
                log "ERROR" "Не удалось удалить провайдера из конфигурации"
                read -p "Нажмите Enter для продолжения..."
                return 1
            fi
            
            # Устанавливаем права
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
            chmod 600 "$MAS_CONFIG_FILE"
            
            # Синхронизируем и перезапускаем MAS
            if sync_and_restart_mas; then
                log "SUCCESS" "Провайдер $provider_name успешно удален"
            else
                log "ERROR" "Ошибка при применении изменений"
            fi
        else
            log "INFO" "Удаление провайдера отменено"
        fi
        
        read -p "Нажмите Enter для продолжения..."
    }

    # Главное меню управления SSO
    while true; do
        print_header "УПРАВЛЕНИЕ SSO" "$BLUE"
        
        # Проверяем и инициализируем структуру при каждом входе в меню
        if ! check_upstream_oauth2_structure; then
            log "ERROR" "Не удалось инициализировать структуру upstream_oauth2"
            read -p "Нажмите Enter для возврата..."
            return 1
        fi
        
        safe_echo "Текущие SSO-провайдеры:"
        
        # Показываем текущие провайдеры
        local current_providers=$(yq eval '.upstream_oauth2.providers' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ -z "$current_providers" ] || [ "$current_providers" = "null" ] || [ "$current_providers" = "[]" ]; then
            safe_echo "${YELLOW}SSO-провайдеры не настроены.${NC}"
        else
            local provider_count=$(yq eval '.upstream_oauth2.providers | length' "$MAS_CONFIG_FILE" 2>/dev/null)
            safe_echo "${GREEN}Настроено провайдеров: $provider_count${NC}"
            echo
            
            # Показываем список провайдеров
            yq eval '.upstream_oauth2.providers[]' "$MAS_CONFIG_FILE" 2>/dev/null | while IFS= read -r provider; do
                if [ -n "$provider" ] && [ "$provider" != "null" ]; then
                    local name=$(echo "$provider" | yq eval '.human_name' - 2>/dev/null)
                    local id=$(echo "$provider" | yq eval '.id' - 2>/dev/null)
                    local brand=$(echo "$provider" | yq eval '.brand_name' - 2>/dev/null)
                    
                    if [ -n "$name" ] && [ "$name" != "null" ]; then
                        safe_echo "• ${CYAN}$name${NC} ($brand) - ID: $id"
                    fi
                fi
            done
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
                add_sso_provider "google" "Google" "google" "https://accounts.google.com" "openid profile email" '.issuer = "https://accounts.google.com" | .token_endpoint_auth_method = "client_secret_post"'
                ;;
            2)
                add_sso_provider "github" "GitHub" "github" "" "read:user user:email" '.discovery_mode = "disabled" | .fetch_userinfo = true | .token_endpoint_auth_method = "client_secret_post" | .authorization_endpoint = "https://github.com/login/oauth/authorize" | .token_endpoint = "https://github.com/login/oauth/access_token" | .userinfo_endpoint = "https://api.github.com/user" | .claims_imports.subject.template = "{{ userinfo_claims.id }}"'
                ;;
            3)
                add_sso_provider "gitlab" "GitLab" "gitlab" "https://gitlab.com" "openid profile email" '.issuer = "https://gitlab.com" | .token_endpoint_auth_method = "client_secret_post"'
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
        safe_echo "5. 📄 Просмотреть конфигурацию account"
        safe_echo "6. Назад"

        read -p "Выберите действие [1-6]: " action

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
                view_mas_account_config
                ;;
            6)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 6 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Функция исправления проблем с конфигурацией MAS
fix_mas_config_issues() {
    print_header "ИСПРАВЛЕНИЕ ПРОБЛЕМ КОНФИГУРАЦИИ MAS" "$YELLOW"
    
    log "INFO" "Диагностика и исправление проблем конфигурации MAS"
    
    # Проверяем существование файла конфигурации
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "INFO" "Для восстановления конфигурации используйте переустановку MAS"
        return 1
    fi
    
    # Проверяем права доступа к файлу
    log "INFO" "Проверка прав доступа к файлу конфигурации..."
    if [ ! -r "$MAS_CONFIG_FILE" ]; then
        log "WARN" "Файл конфигурации не доступен для чтения, исправляю..."
        chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || {
            log "ERROR" "Не удалось исправить права доступа"
            return 1
        }
    fi
    
    if [ ! -w "$MAS_CONFIG_FILE" ]; then
        log "WARN" "Файл конфигурации не доступен для записи, исправляю..."
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null || {
            log "ERROR" "Не удалось изменить владельца файла $MAS_CONFIG_FILE"
            return 1
        }
        chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null || {
            log "ERROR" "Не удалось изменить права доступа к файлу $MAS_CONFIG_FILE"
            return 1
        }
    fi
    
    # Проверяем YAML синтаксис
    log "INFO" "Проверка YAML синтаксиса..."
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "Обнаружены ошибки YAML синтаксиса в конфигурации MAS"
            log "INFO" "Рекомендуется пересоздать конфигурацию MAS"
            return 1
        else
            log "SUCCESS" "YAML синтаксис корректен"
        fi
    fi
    
    # Проверяем наличие критических секций
    if ! check_yq_dependency; then
        return 1
    fi
    
    local required_sections=("http" "database" "matrix" "secrets")
    local missing_sections=()
    
    for section in "${required_sections[@]}"; do
        if ! yq eval ".$section" "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
            missing_sections+=("$section")
        fi
    done
    
    if [ ${#missing_sections[@]} -gt 0 ]; then
        log "ERROR" "Отсутствуют критические секции: ${missing_sections[*]}"
        log "INFO" "Для полного восстановления конфигурации используйте переустановку"
        return 1
    else
        log "SUCCESS" "Все критические секции присутствуют"
    fi
    
    # Проверяем и исправляем секцию account
    log "INFO" "Проверка секции account..."
    if ! yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        log "WARN" "Секция account отсутствует, добавляю..."
        if initialize_mas_account_section; then
            log "SUCCESS" "Секция account добавлена"
        else
            log "ERROR" "Не удалось добавить секцию account"
            return 1
        fi
    else
        local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$account_content" = "null" ] || [ -z "$account_content" ]; then
            log "WARN" "Секция account пуста, инициализирую..."
            if initialize_mas_account_section; then
                log "SUCCESS" "Секция account инициализирована"
            else
                log "ERROR" "Не удалось инициализировать секцию account"
                return 1
            fi
        else
            log "SUCCESS" "Секция account корректна"
        fi
    fi
    
    # Проверяем работу MAS doctor если доступен
    if command -v mas >/dev/null 2>&1; then
        log "INFO" "Запуск диагностики MAS doctor..."
        if mas doctor --config "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
            log "SUCCESS" "Конфигурация MAS прошла проверку mas doctor"
        else
            log "WARN" "MAS doctor обнаружил проблемы в конфигурации"
            log "INFO" "Запустите 'mas doctor --config $MAS_CONFIG_FILE' для подробностей"
        fi
    fi
    
    log "SUCCESS" "Диагностика и исправление конфигурации завершены"
    return 0
}

# Функция восстановления MAS
repair_mas() {
    print_header "ВОССТАНОВЛЕНИЕ MATRIX AUTHENTICATION SERVICE" "$YELLOW"
    
    log "INFO" "Диагностика и восстановление MAS..."
    
    # Проверяем и восстанавливаем файлы share
    if ! check_mas_files; then
        log "WARN" "Файлы MAS повреждены или отсутствуют"
        if ask_confirmation "Переустановить файлы MAS?"; then
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
                *) log "ERROR" "Неподдерживаемая архитектура: $arch"; return 1 ;;
            esac
            
            # URL для скачивания MAS из репозитория element-hq
            local download_url="https://github.com/element-hq/matrix-authentication-service/releases/latest/download/$mas_binary"
            
            # Проверяем подключение к интернету
            if ! check_internet; then
                log "ERROR" "Отсутствует подключение к интернету"
                return 1
            fi
            
            log "INFO" "Скачивание и установка файлов MAS..."
            
            # Скачиваем MAS
            if ! download_file "$download_url" "/tmp/$mas_binary"; then
                log "ERROR" "Ошибка скачивания MAS"
                return 1
            fi
            
            # Создаем временную директорию для извлечения
            local temp_dir=$(mktemp -d)
            
            # Извлекаем архив
            if ! tar -xzf "/tmp/$mas_binary" -C "$temp_dir"; then
                log "ERROR" "Ошибка извлечения архива MAS"
                rm -rf "$temp_dir"
                return 1
            fi
            
            # Устанавливаем бинарный файл если отсутствует
            if [ -f "$temp_dir/mas-cli" ] && [ ! -f "/usr/local/bin/mas" ]; then
                chmod +x "$temp_dir/mas-cli"
                mv "$temp_dir/mas-cli" /usr/local/bin/mas
                log "SUCCESS" "Бинарный файл MAS восстановлен"
            fi
            
            # Создаем директорию установки MAS
            local mas_install_dir="/usr/local/share/mas-cli"
            mkdir -p "$mas_install_dir"
            
            # Устанавливаем ВСЕ файлы share
            if [ -d "$temp_dir/share" ]; then
                log "INFO" "Восстановление файлов MAS (assets, policy, templates, translations)..."
                
                # Копируем все содержимое share в правильное место
                cp -r "$temp_dir/share"/* "$mas_install_dir/"
                
                # Устанавливаем правильные права доступа
                chown -R root:root "$mas_install_dir"
                find "$mas_install_dir" -type f -exec chmod 644 {} \;
                find "$mas_install_dir" -type d -exec chmod 755 {} \;
                
                log "SUCCESS" "Файлы MAS восстановлены"
            else
                log "ERROR" "Директория share отсутствует в архиве MAS"
                rm -rf "$temp_dir"
                return 1
            fi
            
            # Удаляем временные файлы
            rm -f "/tmp/$mas_binary"
            rm -rf "$temp_dir"
            
            log "SUCCESS" "Файлы MAS успешно восстановлены"
        fi
    fi
    
    # Проверяем и восстанавливаем конфигурацию
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Конфигурация MAS отсутствует"
        log "INFO" "Для восстановления конфигурации используйте переустановку через install_mas.sh"
        log "INFO" "Запустите: sudo ./modules/install_mas.sh"
        return 1
    fi
    
    # Проверяем структуру конфигурации
    log "INFO" "Проверка структуры конфигурации..."
    local required_sections=("http" "database" "matrix" "secrets")
    local missing_sections=()
    
    for section in "${required_sections[@]}"; do
        if ! yq eval ".$section" "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
            missing_sections+=("$section")
        fi
    done
    
    if [ ${#missing_sections[@]} -gt 0 ]; then
        log "ERROR" "Отсутствуют критические секции конфигурации: ${missing_sections[*]}"
        log "INFO" "Для полного восстановления конфигурации используйте переустановку"
        return 1
    else
        log "SUCCESS" "Структура конфигурации корректна"
    fi
    
    # Проверка состояния службы
    if ! systemctl is-active --quiet matrix-auth-service; then
        log "INFO" "Служба MAS не запущена, попытка запуска..."
        if systemctl start matrix-auth-service; then
            log "SUCCESS" "Служба MAS запущена"
        else
            log "ERROR" "Не удалось запустить службу MAS"
            log "INFO" "Проверьте логи: journalctl -u matrix-auth-service -n 20"
            return 1
        fi
    fi
    
    # Финальная проверка
    sleep 3
    if systemctl is-active --quiet matrix-auth-service; then
        # Проверяем API
        local mas_port=$(determine_mas_port)
        local health_url="http://localhost:$mas_port/health"
        
        if curl -s -f --connect-timeout 5 "$health_url" >/dev/null 2>&1; then
            log "SUCCESS" "MAS API доступен - восстановление завершено успешно"
        else
            log "WARN" "MAS запущен, но API пока недоступен"
        fi
    else
        log "ERROR" "MAS не запустен после восстановления"
        return 1
    fi
    
    log "SUCCESS" "Восстановление MAS завершено"
    return 0
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
        safe_echo "${GREEN}4.${NC} 👥 Управление регистрацией MAS"
        safe_echo "${GREEN}5.${NC} 🔐 Управление SSO-провайдителями"
        safe_echo "${GREEN}6.${NC} 🤖 Настройки CAPTCHA"
        safe_echo "${GREEN}7.${NC} 🚫 Заблокированные имена пользователей"
        safe_echo "${GREEN}8.${NC} 🎫 Токены регистрации"
        safe_echo "${GREEN}9.${NC} 🔧 Восстановить MAS"
        safe_echo "${GREEN}10.${NC} ⚙️  Исправить конфигурацию MAS"
        safe_echo "${GREEN}11.${NC} ↩️  Назад в главное меню"

        read -p "$(safe_echo "${YELLOW}Выберите действие [1-11]: ${NC}")" action

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
                manage_mas_registration
                ;;
            5)
                manage_sso_providers
                ;;
            6)
                manage_captcha_settings
                ;;
            7)
                manage_banned_usernames
                ;;
            8)
                manage_mas_registration_tokens
                ;;
            9)
                repair_mas
                ;;
            10)
                fix_mas_config_issues
                ;;
            11)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 11 ]; then
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
