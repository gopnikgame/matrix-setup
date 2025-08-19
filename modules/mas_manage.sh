#!/bin/bash

# Matrix Authentication Service (MAS) Management Module

# Определение директории скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключение общей библиотеки
if [ -f "${SCRIPT_DIR}/../common/common_lib.sh" ]; then
    source "${SCRIPT_DIR}/../common/common_lib.sh"
else
    echo "ОШИБКА: Не найдена общая библиотека common_lib.sh"
    exit 1
fi

# Подключение всех подмодулей MAS
log "DEBUG" "Подключение подмодулей MAS..."

# Подключение модуля удаления MAS
if [ -f "${SCRIPT_DIR}/mas_sub_modules/mas_removing.sh" ]; then
    source "${SCRIPT_DIR}/mas_sub_modules/mas_removing.sh"
    log "DEBUG" "Модуль mas_removing.sh подключен"
else
    log "WARN" "Модуль mas_removing.sh не найден"
fi

# Подключение модуля диагностики и восстановления
if [ -f "${SCRIPT_DIR}/mas_sub_modules/mas_diagnosis_and_recovery.sh" ]; then
    source "${SCRIPT_DIR}/mas_sub_modules/mas_diagnosis_and_recovery.sh"
    log "DEBUG" "Модуль mas_diagnosis_and_recovery.sh подключен"
else
    log "WARN" "Модуль mas_diagnosis_and_recovery.sh не найден"
fi

# Подключение модуля управления регистрацией
if [ -f "${SCRIPT_DIR}/mas_sub_modules/mas_manage_mas_registration.sh" ]; then
    source "${SCRIPT_DIR}/mas_sub_modules/mas_manage_mas_registration.sh"
    log "DEBUG" "Модуль mas_manage_mas_registration.sh подключен"
else
    log "WARN" "Модуль mas_manage_mas_registration.sh не найден"
fi

# Подключение модуля управления SSO провайдерами
if [ -f "${SCRIPT_DIR}/mas_sub_modules/mas_manage_sso.sh" ]; then
    source "${SCRIPT_DIR}/mas_sub_modules/mas_manage_sso.sh"
    log "DEBUG" "Модуль mas_manage_sso.sh подключен"
else
    log "WARN" "Модуль mas_manage_sso.sh не найден"
fi

# Подключение модуля управления CAPTCHA
if [ -f "${SCRIPT_DIR}/mas_sub_modules/mas_manage_captcha.sh" ]; then
    source "${SCRIPT_DIR}/mas_sub_modules/mas_manage_captcha.sh"
    log "DEBUG" "Модуль mas_manage_captcha.sh подключен"
else
    log "WARN" "Модуль mas_manage_captcha.sh не найден"
fi

# Подключение модуля управления заблокированными именами пользователей
if [ -f "${SCRIPT_DIR}/mas_sub_modules/mas_manage_ban_usernames.sh" ]; then
    source "${SCRIPT_DIR}/mas_sub_modules/mas_manage_ban_usernames.sh"
    log "DEBUG" "Модуль mas_manage_ban_usernames.sh подключен"
else
    log "WARN" "Модуль mas_manage_ban_usernames.sh не найден"
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

# Функция для безопасного управления файлом конфигурации
safe_config_edit() {
    local config_file="$1"
    local operation="$2" # "start" или "end"
    
    case "$operation" in
        "start")
            log "INFO" "Подготовка к безопасному редактированию $config_file..."
            
            # Останавливаем MAS если запущен
            if systemctl is-active --quiet matrix-auth-service 2>/dev/null; then
                log "INFO" "Останавливаю matrix-auth-service для безопасного редактирования..."
                if ! systemctl stop matrix-auth-service; then
                    log "ERROR" "Не удалось остановить matrix-auth-service"
                    return 1
                fi
                # Сохраняем информацию о том, что сервис был запущен
                echo "true" > "/tmp/mas_was_running"
            else
                echo "false" > "/tmp/mas_was_running"
            fi
            
            # Проверяем и снимаем иммутабельность файла
            if command -v lsattr >/dev/null 2>&1; then
                local file_attrs=$(lsattr "$config_file" 2>/dev/null | cut -d' ' -f1)
                echo "$file_attrs" > "/tmp/mas_config_attrs"
                
                if [[ "$file_attrs" == *"i"* ]]; then
                    log "INFO" "Снимаю флаг иммутабельности с $config_file..."
                    if ! chattr -i "$config_file" 2>/dev/null; then
                        log "WARN" "Не удалось снять флаг иммутабельности"
                    fi
                fi
            else
                echo "" > "/tmp/mas_config_attrs"
            fi
            
            # Сохраняем текущие права доступа
            if [ -f "$config_file" ]; then
                stat -c "%a %U:%G" "$config_file" > "/tmp/mas_config_perms" 2>/dev/null || \
                ls -la "$config_file" | awk '{print $1, $3":"$4}' > "/tmp/mas_config_perms"
            fi
            
            # Проверяем права доступа к директории конфигурации
            local config_dir=$(dirname "$config_file")
            if [ -d "$config_dir" ]; then
                stat -c "%a %U:%G" "$config_dir" > "/tmp/mas_config_dir_perms" 2>/dev/null || \
                ls -lad "$config_dir" | awk '{print $1, $3":"$4}' > "/tmp/mas_config_dir_perms"
                
                # Временно делаем директорию доступной для записи
                if [ ! -w "$config_dir" ]; then
                    log "INFO" "Временно изменяю права доступа к директории $config_dir..."
                    chmod 755 "$config_dir" 2>/dev/null || true
                fi
            fi
            
            # Делаем файл доступным для записи
            if [ -f "$config_file" ] && [ ! -w "$config_file" ]; then
                log "INFO" "Временно изменяю права доступа к файлу $config_file..."
                chmod 644 "$config_file" 2>/dev/null || true
            fi
            
            # Проверяем доступность временной директории
            local temp_dir_parent=$(dirname "$(mktemp -u)")
            if [ ! -w "$temp_dir_parent" ]; then
                log "WARN" "Временная директория $temp_dir_parent не доступна для записи"
                # Попробуем использовать альтернативные директории
                for alt_temp in "/var/tmp" "/opt/matrix-install/tmp" "/home/$(whoami)"; do
                    if [ -w "$alt_temp" ]; then
                        export TMPDIR="$alt_temp"
                        log "INFO" "Использую альтернативную временную директорию: $alt_temp"
                        break
                    fi
                done
            fi
            
            log "SUCCESS" "Подготовка к редактированию завершена"
            return 0
            ;;
            
        "end")
            log "INFO" "Восстановление после редактирования $config_file..."
            
            # Восстанавливаем права доступа к файлу
            if [ -f "/tmp/mas_config_perms" ]; then
                local saved_perms=$(cat "/tmp/mas_config_perms" 2>/dev/null)
                if [ -n "$saved_perms" ]; then
                    local file_mode=$(echo "$saved_perms" | cut -d' ' -f1)
                    local file_owner=$(echo "$saved_perms" | cut -d' ' -f2)
                    
                    if [[ "$file_mode" =~ ^[0-7]{3,4}$ ]]; then
                        log "INFO" "Восстанавливаю права доступа файла: $file_mode"
                        chmod "$file_mode" "$config_file" 2>/dev/null || true
                    fi
                    
                    if [[ "$file_owner" =~ ^[^:]+:[^:]+$ ]]; then
                        log "INFO" "Восстанавливаю владельца файла: $file_owner"
                        chown "$file_owner" "$config_file" 2>/dev/null || true
                    fi
                fi
                rm -f "/tmp/mas_config_perms"
            fi
            
            # Восстанавливаем права доступа к директории
            if [ -f "/tmp/mas_config_dir_perms" ]; then
                local config_dir=$(dirname "$config_file")
                local saved_dir_perms=$(cat "/tmp/mas_config_dir_perms" 2>/dev/null)
                if [ -n "$saved_dir_perms" ]; then
                    local dir_mode=$(echo "$saved_dir_perms" | cut -d' ' -f1)
                    local dir_owner=$(echo "$saved_dir_perms" | cut -d' ' -f2)
                    
                    if [[ "$dir_mode" =~ ^[0-7]{3,4}$ ]]; then
                        log "INFO" "Восстанавливаю права доступа директории: $dir_mode"
                        chmod "$dir_mode" "$config_dir" 2>/dev/null || true
                    fi
                    
                    if [[ "$dir_owner" =~ ^[^:]+:[^:]+$ ]]; then
                        log "INFO" "Восстанавливаю владельца директории: $dir_owner"
                        chown "$dir_owner" "$config_dir" 2>/dev/null || true
                    fi
                fi
                rm -f "/tmp/mas_config_dir_perms"
            fi
            
            # Восстанавливаем флаг иммутабельности
            if [ -f "/tmp/mas_config_attrs" ]; then
                local saved_attrs=$(cat "/tmp/mas_config_attrs" 2>/dev/null)
                if [[ "$saved_attrs" == *"i"* ]] && command -v chattr >/dev/null 2>&1; then
                    log "INFO" "Восстанавливаю флаг иммутабельности..."
                    chattr +i "$config_file" 2>/dev/null || true
                fi
                rm -f "/tmp/mas_config_attrs"
            fi
            
            # Запускаем MAS если он был запущен ранее
            if [ -f "/tmp/mas_was_running" ]; then
                local was_running=$(cat "/tmp/mas_was_running" 2>/dev/null)
                if [ "$was_running" = "true" ]; then
                    log "INFO" "Запускаю matrix-auth-service..."
                    if systemctl start matrix-auth-service; then
                        log "SUCCESS" "matrix-auth-service запущен"
                        # Ждем небольшую паузу для полного запуска
                        sleep 3
                        if systemctl is-active --quiet matrix-auth-service; then
                            log "SUCCESS" "matrix-auth-service успешно работает"
                        else
                            log "WARN" "matrix-auth-service запущен, но статус неопределен"
                        fi
                    else
                        log "ERROR" "Ошибка запуска matrix-auth-service"
                        log "INFO" "Проверьте логи: journalctl -u matrix-auth-service -n 20"
                    fi
                fi
                rm -f "/tmp/mas_was_running"
            fi
            
            log "SUCCESS" "Восстановление завершено"
            return 0
            ;;
            
        *)
            log "ERROR" "Неизвестная операция: $operation"
            return 1
            ;;
    esac
}

# Функция инициализации секции account в конфигурации MAS (УЛУЧШЕННАЯ ВЕРСИЯ)
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
    
    # Подготавливаем безопасное редактирование
    if ! safe_config_edit "$MAS_CONFIG_FILE" "start"; then
        log "ERROR" "Не удалось подготовить файл для редактирования"
        return 1
    fi
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_account_init"
    
    log "INFO" "Добавление секции account в конфигурацию MAS..."
    
    # Метод 1: Используем yq eval -i напрямую (in-place editing)
    log "INFO" "Попытка добавления секции account с помощью yq eval -i..."
    
    local config_success=false
    
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
            local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_account_init_* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                cp "$latest_backup" "$MAS_CONFIG_FILE"
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            config_success=false
        else
            config_success=true
        fi
        
    else
        # Метод 2: Альтернативный способ - создание нового файла
        log "WARN" "yq eval -i не сработал, используем альтернативный метод..."
        
        # Создаем временную директорию с учетом возможных проблем с правами
        local temp_dir=""
        local temp_base_dirs=("/tmp" "/var/tmp" "/opt/matrix-install" "/home/$(whoami)")
        
        for base_dir in "${temp_base_dirs[@]}"; do
            if [ -w "$base_dir" ]; then
                temp_dir=$(mktemp -d "${base_dir}/mas_config_XXXXXX" 2>/dev/null)
                if [ -d "$temp_dir" ]; then
                    break
                fi
            fi
        done
        
        if [ ! -d "$temp_dir" ]; then
            log "ERROR" "Не удалось создать временную директорию"
            safe_config_edit "$MAS_CONFIG_FILE" "end"
            return 1
        fi
        
        local temp_file="$temp_dir/config.yaml"
        
        # Копируем оригинальный файл
        if ! cp "$MAS_CONFIG_FILE" "$temp_file"; then
            log "ERROR" "Не удалось скопировать конфигурацию во временный файл"
            rm -rf "$temp_dir"
            safe_config_edit "$MAS_CONFIG_FILE" "end"
            return 1
        fi
        
        # Используем yq для создания нового файла с добавленной секцией
        if yq eval '.account = {
            "password_registration_enabled": false,
            "registration_token_required": false,
            "email_change_allowed": true,
            "displayname_change_allowed": true,
            "password_change_allowed": true,
            "password_recovery_enabled": false,
            "account_deactivation_allowed": false
        }' "$temp_file" > "${temp_file}.new" 2>/dev/null; then
            
            # Проверяем валидность YAML
            if command -v python3 >/dev/null 2>&1; then
                if python3 -c "import yaml; yaml.safe_load(open('${temp_file}.new'))" 2>/dev/null; then
                    # Заменяем оригинальный файл
                    if mv "${temp_file}.new" "$MAS_CONFIG_FILE"; then
                        log "SUCCESS" "Секция account добавлена альтернативным методом"
                        config_success=true
                    else
                        log "ERROR" "Не удалось заменить оригинальный файл"
                        config_success=false
                    fi
                else
                    log "ERROR" "YAML поврежден после добавления секции account альтернативным методом"
                    config_success=false
                fi
            else
                # Если Python недоступен, просто заменяем файл
                if mv "${temp_file}.new" "$MAS_CONFIG_FILE"; then
                    log "SUCCESS" "Секция account добавлена альтернативным методом (без проверки YAML)"
                    config_success=true
                else
                    log "ERROR" "Не удалось заменить оригинальный файл"
                    config_success=false
                fi
            fi
        else
            log "ERROR" "Альтернативный метод создания конфигурации не сработал"
            config_success=false
        fi
        
        # Удаляем временную директорию
        rm -rf "$temp_dir"
    fi
    
    # Если конфигурация не удалась, восстанавливаем из бэкапа
    if [ "$config_success" = false ]; then
        log "ERROR" "Все методы добавления секции account не сработали"
        local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_account_init_* 2>/dev/null | head -1)
        if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
            cp "$latest_backup" "$MAS_CONFIG_FILE"
            log "INFO" "Конфигурация восстановлена из резервной копии"
        fi
        safe_config_edit "$MAS_CONFIG_FILE" "end"
        return 1
    fi
    
    # Финальная проверка целостности конфигурации
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "YAML поврежден после добавления секции account!"
            log "ERROR" "Восстанавливаю из резервной копии..."
            local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_account_init_* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                cp "$latest_backup" "$MAS_CONFIG_FILE"
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            safe_config_edit "$MAS_CONFIG_FILE" "end"
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
        safe_config_edit "$MAS_CONFIG_FILE" "end"
        return 1
    fi
    
    # Завершаем безопасное редактирование (восстанавливаем права и запускаем сервис)
    safe_config_edit "$MAS_CONFIG_FILE" "end"
    
    return 0
}

# Изменение параметра в YAML файле (УЛУЧШЕННАЯ ВЕРСИЯ)
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
    
    # Подготавливаем безопасное редактирование
    if ! safe_config_edit "$MAS_CONFIG_FILE" "start"; then
        log "ERROR" "Не удалось подготовить файл для редактирования"
        return 1
    fi
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_change"
    
    local config_success=false
    
    # Применяем изменение с помощью yq eval -i
    log "INFO" "Применение изменения $full_path = $value..."
    
    if yq eval -i "$full_path = $value" "$MAS_CONFIG_FILE" 2>/dev/null; then
        log "SUCCESS" "Изменение применено с помощью yq eval -i"
        config_success=true
    else
        log "ERROR" "Не удалось изменить $key в $MAS_CONFIG_FILE с помощью yq eval -i"
        
        # Альтернативный метод: создаем новый файл с изменениями
        log "WARN" "Пробуем альтернативный метод изменения конфигурации..."
        
        # Создаем временную директорию с учетом возможных проблем с правами
        local temp_dir=""
        local temp_base_dirs=("/tmp" "/var/tmp" "/opt/matrix-install" "/home/$(whoami)")
        
        for base_dir in "${temp_base_dirs[@]}"; do
            if [ -w "$base_dir" ]; then
                temp_dir=$(mktemp -d "${base_dir}/mas_config_update_XXXXXX" 2>/dev/null)
                if [ -d "$temp_dir" ]; then
                    break
                fi
            fi
        done
        
        if [ ! -d "$temp_dir" ]; then
            log "ERROR" "Не удалось создать временную директорию"
            safe_config_edit "$MAS_CONFIG_FILE" "end"
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
                        config_success=true
                    else
                        log "ERROR" "Не удалось заменить оригинальный файл"
                        config_success=false
                    fi
                else
                    log "ERROR" "YAML поврежден после изменений альтернативным методом"
                    config_success=false
                fi
            else
                # Если Python недоступен, просто заменяем файл
                if mv "$temp_file" "$MAS_CONFIG_FILE"; then
                    log "SUCCESS" "Изменение применено альтернативным методом (без проверки YAML)"
                    config_success=true
                else
                    log "ERROR" "Не удалось заменить оригинальный файл"
                    config_success=false
                fi
            fi
        else
            log "ERROR" "Альтернативный метод также не сработал"
            config_success=false
        fi
        
        # Очищаем временную директорию
        rm -rf "$temp_dir"
    fi
    
    # Если изменение не удалось, восстанавливаем из бэкапа
    if [ "$config_success" = false ]; then
        log "ERROR" "Не удалось применить изменения к конфигурации"
        local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_change_* 2>/dev/null | head -1)
        if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
            cp "$latest_backup" "$MAS_CONFIG_FILE"
            log "INFO" "Конфигурация восстановлена из резервной копии"
        fi
        safe_config_edit "$MAS_CONFIG_FILE" "end"
        return 1
    fi
    
    # Проверяем валидность YAML после изменений
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "YAML файл поврежден после изменений, восстанавливаю резервную копию..."
            local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_change_* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                cp "$latest_backup" "$MAS_CONFIG_FILE"
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            safe_config_edit "$MAS_CONFIG_FILE" "end"
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
    
    # Завершаем безопасное редактирование (восстанавливаем права и запускаем сервис)
    safe_config_edit "$MAS_CONFIG_FILE" "end"
    
    # Проверяем, что MAS запустился и работает корректно
    if systemctl is-active --quiet matrix-auth-service; then
        log "SUCCESS" "Настройка $key успешно изменена на $value"
        
        # Проверяем API если доступен
        local mas_port=""
        if [ -f "$CONFIG_DIR/mas.conf" ]; then
            mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
        fi
        
        if [ -n "$mas_port" ]; then
            local health_url="http://localhost:$mas_port/health"
            if curl -s -f --connect-timeout 5 "$health_url" >/dev/null 2>&1; then
                log "SUCCESS" "MAS API доступен - настройки применены успешно"
            else
                log "WARN" "MAS запущен, но API пока недоступен"
            fi
        fi
    else
        log "ERROR" "MAS не запустился после изменения конфигурации"
        log "INFO" "Проверьте логи: journalctl -u matrix-auth-service -n 20"
        return 1
    fi
    
    return 0
}

# Проверка доступности подмодулей
check_submodule_availability() {
    local missing_modules=()
    
    # Проверяем доступность каждого подмодуля
    if ! command -v uninstall_mas >/dev/null 2>&1; then
        missing_modules+=("mas_removing.sh")
    fi
    
    if ! command -v diagnose_mas >/dev/null 2>&1; then
        missing_modules+=("mas_diagnosis_and_recovery.sh")
    fi
    
    if ! command -v manage_mas_registration >/dev/null 2>&1; then
        missing_modules+=("mas_manage_mas_registration.sh")
    fi
    
    if ! command -v manage_sso_providers >/dev/null 2>&1; then
        missing_modules+=("mas_manage_sso.sh")
    fi
    
    if ! command -v manage_captcha_settings >/dev/null 2>&1; then
        missing_modules+=("mas_manage_captcha.sh")
    fi
    
    if ! command -v manage_banned_usernames >/dev/null 2>&1; then
        missing_modules+=("mas_manage_ban_usernames.sh")
    fi
    
    # Проверяем, что функции токенов доступны в подмодуле регистрации
    if ! command -v manage_mas_registration_tokens >/dev/null 2>&1; then
        log "WARN" "Функция manage_mas_registration_tokens недоступна"
    fi
    
    # Проверяем, что функции восстановления доступны в подмодуле диагностики
    if ! command -v repair_mas >/dev/null 2>&1; then
        log "WARN" "Функция repair_mas недоступна"
    fi
    
    if ! command -v fix_mas_config_issues >/dev/null 2>&1; then
        log "WARN" "Функция fix_mas_config_issues недоступна"
    fi
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        log "WARN" "Недоступные подмодули: ${missing_modules[*]}"
        return 1
    else
        log "SUCCESS" "Все подмодули MAS успешно подключены"
        return 0
    fi
}

# Функция-заглушка для недоступных функций
handle_missing_function() {
    local function_name="$1"
    local module_name="$2"
    
    print_header "ФУНКЦИЯ НЕДОСТУПНА" "$RED"
    log "ERROR" "Функция '$function_name' недоступна"
    log "INFO" "Требуется подмодуль: $module_name"
    log "INFO" "Убедитесь, что файл $module_name существует в директории mas_sub_modules/"
    echo
    read -p "Нажмите Enter для возврата в меню..."
}

# Главное меню модуля
show_main_menu() {
    # Проверяем доступность подмодулей при первом запуске
    check_submodule_availability
    
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
        safe_echo "${GREEN}3.${NC} 🔍 Диагностика и восстановление MAS"
        safe_echo "${GREEN}4.${NC} 👥 Управление регистрацией MAS"
        safe_echo "${GREEN}5.${NC} 🔐 Управление SSO-провайдерами"
        safe_echo "${GREEN}6.${NC} 🤖 Настройки CAPTCHA"
        safe_echo "${GREEN}7.${NC} 🚫 Заблокированные имена пользователей"
        safe_echo "${GREEN}8.${NC} 🎫 Токены регистрации"
        safe_echo "${GREEN}9.${NC} 🔧 Восстановить MAS"
        safe_echo "${GREEN}10.${NC} ⚙️  Исправить конфигурацию MAS"
        safe_echo "${GREEN}11.${NC} 📄 Просмотр конфигурации account"
        safe_echo "${GREEN}12.${NC} ↩️  Назад в главное меню"

        read -p "$(safe_echo "${YELLOW}Выберите действие [1-12]: ${NC}")" action

        case $action in
            1)
                check_mas_status
                ;;
            2)
                if command -v uninstall_mas >/dev/null 2>&1; then
                    uninstall_mas
                else
                    handle_missing_function "uninstall_mas" "mas_removing.sh"
                fi
                ;;
            3)
                if command -v diagnose_mas >/dev/null 2>&1; then
                    # Показываем подменю диагностики
                    while true; do
                        print_header "ДИАГНОСТИКА И ВОССТАНОВЛЕНИЕ MAS" "$BLUE"
                        safe_echo "1. ${CYAN}🔍 Полная диагностика MAS${NC}"
                        safe_echo "2. ${YELLOW}🔧 Исправить проблемы конфигурации${NC}"
                        safe_echo "3. ${GREEN}🛠️  Восстановить MAS${NC}"
                        safe_echo "4. ${BLUE}📁 Проверить файлы MAS${NC}"
                        safe_echo "5. ${WHITE}↩️  Назад${NC}"

                        read -p "Выберите действие [1-5]: " diag_action

                        case $diag_action in
                            1) diagnose_mas ;;
                            2) 
                                if command -v fix_mas_config_issues >/dev/null 2>&1; then
                                    fix_mas_config_issues
                                else
                                    handle_missing_function "fix_mas_config_issues" "mas_diagnosis_and_recovery.sh"
                                fi
                                ;;
                            3) 
                                if command -v repair_mas >/dev/null 2>&1; then
                                    repair_mas
                                else
                                    handle_missing_function "repair_mas" "mas_diagnosis_and_recovery.sh"
                                fi
                                ;;
                            4)
                                if command -v check_mas_files >/dev/null 2>&1; then
                                    check_mas_files
                                else
                                    handle_missing_function "check_mas_files" "mas_diagnosis_and_recovery.sh"
                                fi
                                ;;
                            5) break ;;
                            *) log "ERROR" "Некорректный ввод." ;;
                        esac
                        
                        if [ $diag_action -ne 5 ]; then
                            echo
                            read -p "Нажмите Enter для продолжения..."
                        fi
                    done
                else
                    handle_missing_function "diagnose_mas" "mas_diagnosis_and_recovery.sh"
                fi
                ;;
            4)
                if command -v manage_mas_registration >/dev/null 2>&1; then
                    manage_mas_registration
                else
                    handle_missing_function "manage_mas_registration" "mas_manage_mas_registration.sh"
                fi
                ;;
            5)
                if command -v manage_sso_providers >/dev/null 2>&1; then
                    manage_sso_providers
                else
                    handle_missing_function "manage_sso_providers" "mas_manage_sso.sh"
                fi
                ;;
            6)
                if command -v manage_captcha_settings >/dev/null 2>&1; then
                    manage_captcha_settings
                else
                    handle_missing_function "manage_captcha_settings" "mas_manage_captcha.sh"
                fi
                ;;
            7)
                if command -v manage_banned_usernames >/dev/null 2>&1; then
                    manage_banned_usernames
                else
                    handle_missing_function "manage_banned_usernames" "mas_manage_ban_usernames.sh"
                fi
                ;;
            8)
                if command -v manage_mas_registration_tokens >/dev/null 2>&1; then
                    manage_mas_registration_tokens
                else
                    handle_missing_function "manage_mas_registration_tokens" "mas_manage_mas_registration.sh"
                fi
                ;;
            9)
                if command -v repair_mas >/dev/null 2>&1; then
                    repair_mas
                else
                    handle_missing_function "repair_mas" "mas_diagnosis_and_recovery.sh"
                fi
                ;;
            10)
                if command -v fix_mas_config_issues >/dev/null 2>&1; then
                    fix_mas_config_issues
                else
                    handle_missing_function "fix_mas_config_issues" "mas_diagnosis_and_recovery.sh"
                fi
                ;;
            11)
                view_mas_account_config
                ;;
            12)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 12 ]; then
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
