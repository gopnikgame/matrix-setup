#!/bin/bash

# Matrix Authentication Service (MAS) - Модуль диагностики и восстановления
# Версия: 1.1.0

# Определение директории скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключение общей библиотеки
if [ -f "${SCRIPT_DIR}/../../common/common_lib.sh" ]; then
    source "${SCRIPT_DIR}/../../common/common_lib.sh"
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
MAS_DB_NAME="mas_db"

# Проверка root прав
check_root

# Загружаем тип сервера
load_server_type

# Проверка зависимости yq
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

# Определение порта MAS
determine_mas_port() {
    local mas_port_hosting="8080"
    local mas_port_proxmox="8082"
    
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            echo "$mas_port_proxmox"
            ;;
        *)
            echo "$mas_port_hosting"
            ;;
    esac
}

# Проверка критически важных файлов MAS
check_mas_files() {
    print_header "ПРОВЕРКА ФАЙЛОВ MAS" "$CYAN"
    
    local mas_share_dir="/usr/local/share/mas-cli"
    local policy_path="$mas_share_dir/policy.wasm"
    local assets_path="$mas_share_dir/assets"
    local templates_path="$mas_share_dir/templates"
    local translations_path="$mas_share_dir/translations"
    local manifest_path="$mas_share_dir/manifest.json"
    
    local all_ok=true
    
    log "INFO" "Проверка файлов MAS share..."
    
    if [ ! -f "$policy_path" ]; then
        log "ERROR" "❌ Критический файл policy.wasm отсутствует: $policy_path"
        all_ok=false
    else
        log "SUCCESS" "✅ Файл политики найден: $policy_path"
    fi
    
    if [ ! -d "$assets_path" ]; then
        log "WARN" "⚠️  Assets отсутствуют: $assets_path"
        all_ok=false
    else
        log "SUCCESS" "✅ Assets найдены: $assets_path"
    fi
    
    if [ ! -d "$templates_path" ]; then
        log "WARN" "⚠️  Templates отсутствуют: $templates_path"
        all_ok=false
    else
        log "SUCCESS" "✅ Templates найдены: $templates_path"
    fi
    
    if [ ! -d "$translations_path" ]; then
        log "WARN" "⚠️  Translations отсутствуют: $translations_path"
        all_ok=false
    else
        log "SUCCESS" "✅ Translations найдены: $translations_path"
    fi
    
    if [ ! -f "$manifest_path" ]; then
        log "WARN" "⚠️  Manifest отсутствует: $manifest_path"
        all_ok=false
    else
        log "SUCCESS" "✅ Manifest найден: $manifest_path"
    fi
    
    # Проверяем бинарный файл
    if [ ! -f "/usr/local/bin/mas" ]; then
        log "ERROR" "❌ Бинарный файл MAS отсутствует: /usr/local/bin/mas"
        all_ok=false
    else
        log "SUCCESS" "✅ Бинарный файл MAS найден: /usr/local/bin/mas"
    fi
    
    # Проверяем конфигурационные файлы
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "❌ Конфигурационный файл MAS отсутствует: $MAS_CONFIG_FILE"
        all_ok=false
    else
        log "SUCCESS" "✅ Конфигурационный файл найден: $MAS_CONFIG_FILE"
    fi
    
    if [ "$all_ok" = true ]; then
        log "SUCCESS" "Все критически важные файлы MAS присутствуют"
        return 0
    else
        log "ERROR" "Обнаружены проблемы с файлами MAS"
        return 1
    fi
}

# Диагностика MAS
diagnose_mas() {
    print_header "ДИАГНОСТИКА MATRIX AUTHENTICATION SERVICE" "$BLUE"

    log "INFO" "Запуск комплексной диагностики MAS..."

    # Проверка критических файлов MAS
    log "INFO" "Проверка файлов MAS..."
    if ! check_mas_files; then
        log "ERROR" "Обнаружены проблемы с файлами MAS"
    fi

    echo
    # Проверка состояния службы MAS
    log "INFO" "Проверка службы matrix-auth-service..."
    if systemctl is-active --quiet matrix-auth-service; then
        log "SUCCESS" "Служба matrix-auth-service запущена"
        
        # Показываем краткий статус
        local status_output=$(systemctl status matrix-auth-service --no-pager -l --lines=10)
        safe_echo "${BOLD}Статус службы:${NC}"
        echo "$status_output"
    else
        log "ERROR" "Служба matrix-auth-service не запущена"
        
        # Пытаемся получить информацию о проблеме
        log "INFO" "Попытка получения информации об ошибке..."
        systemctl status matrix-auth-service --no-pager -l --lines=10 || log "WARN" "Не удалось получить статус службы"
    fi

    echo
    # Проверка логов MAS
    log "INFO" "Анализ логов matrix-auth-service..."
    if command -v journalctl >/dev/null 2>&1; then
        safe_echo "${BOLD}Последние логи matrix-auth-service:${NC}"
        journalctl -u matrix-auth-service --no-pager -n 15 --since "10 minutes ago" || log "WARN" "Не удалось получить логи"
    else
        log "WARN" "journalctl недоступен"
    fi

    echo
    # Проверка конфигурационных файлов MAS
    if [ -f "$MAS_CONFIG_FILE" ]; then
        log "INFO" "Проверка конфигурации MAS..."
        
        # Проверяем права доступа
        local file_owner=$(stat -c '%U:%G' "$MAS_CONFIG_FILE" 2>/dev/null)
        local file_perms=$(stat -c '%a' "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ "$file_owner" = "$MAS_USER:$MAS_GROUP" ]; then
            log "SUCCESS" "Владелец файла конфигурации корректен: $file_owner"
        else
            log "WARN" "Неправильный владелец файла конфигурации: $file_owner (ожидается: $MAS_USER:$MAS_GROUP)"
        fi
        
        if [ "$file_perms" = "600" ]; then
            log "SUCCESS" "Права доступа к файлу конфигурации корректы: $file_perms"
        else
            log "WARN" "Неправильные права доступа к файлу конфигурации: $file_perms (ожидается: 600)"
        fi
        
        # Проверяем YAML синтаксис
        if command -v python3 >/dev/null 2>&1; then
            if python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                log "SUCCESS" "YAML синтаксис конфигурации корректен"
            else
                log "ERROR" "Ошибка в YAML синтаксе конфигурации MAS"
            fi
        else
            log "WARN" "Python3 недоступен для проверки YAML синтаксиса"
        fi
        
        # Проверка ключевых секций конфигурации
        if check_yq_dependency; then
            log "INFO" "Проверка секций конфигурации..."
            local required_sections=("http" "database" "matrix" "secrets")
            for section in "${required_sections[@]}"; do
                if yq eval ".$section" "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
                    log "SUCCESS" "Секция $section: ✅"
                else
                    log "ERROR" "Секция $section: ❌ ОТСУТСТВУЕТ"
                fi
            done
            
            # Проверка секции policy
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
            if sudo -u "$MAS_USER" mas doctor --config "$MAS_CONFIG_FILE" 2>/dev/null; then
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

    echo
    # Проверка интеграции с Synapse
    log "INFO" "Проверка интеграции с Synapse..."
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

    echo
    # Проверка доступности API MAS
    log "INFO" "Проверка доступности API MAS..."
    local mas_port=$(determine_mas_port)
    
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        local config_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
        if [ -n "$config_port" ]; then
            mas_port="$config_port"
        fi
    fi
    
    if [ -n "$mas_port" ]; then
        log "INFO" "Проверка API MAS на порту $mas_port..."
        
        # Проверяем, что порт слушается
        if ss -tlnp | grep -q ":$mas_port "; then
            log "SUCCESS" "MAS слушает на порту $mas_port"
            
            # Проверяем доступность health endpoint
            local health_url="http://localhost:$mas_port/health"
            if curl -s -f --connect-timeout 3 "$health_url" >/dev/null 2>&1; then
                log "SUCCESS" "MAS API доступен (health endpoint)"
                
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
        else
            log "ERROR" "MAS НЕ слушает на порту $mas_port"
        fi
    else
        log "WARN" "Порт MAS не определен"
    fi

    echo
    # Проверка сетевых подключений
    log "INFO" "Проверка сетевых подключений..."
    if command -v ss >/dev/null 2>&1; then
        safe_echo "${BOLD}Активные сетевые подключения MAS:${NC}"
        ss -tlnp | grep -E "(8080|8082)" || log "INFO" "MAS порты не найдены среди активных подключений"
    fi

    echo
    # Проверка логов на ошибки
    log "INFO" "Поиск критических ошибок в логах..."
    if command -v journalctl >/dev/null 2>&1; then
        local error_count=$(journalctl -u matrix-auth-service --since "1 hour ago" | grep -i error | wc -l)
        local warn_count=$(journalctl -u matrix-auth-service --since "1 hour ago" | grep -i warn | wc -l)
        
        if [ "$error_count" -gt 0 ]; then
            log "WARN" "Найдено $error_count ошибок в логах за последний час"
        else
            log "SUCCESS" "Критических ошибок в логах не найдено"
        fi
        
        if [ "$warn_count" -gt 0 ]; then
            log "INFO" "Найдено $warn_count предупреждений в логах за последний час"
        fi
    fi

    echo
    log "SUCCESS" "Диагностика завершена"
    
    # Общие рекомендации
    safe_echo "${BOLD}${YELLOW}Рекомендации по результатам диагностики:${NC}"
    safe_echo "• Если обнаружены проблемы с файлами - используйте 'Восстановить MAS'"
    safe_echo "• При ошибках конфигурации - используйте 'Исправить конфигурацию MAS'"
    safe_echo "• Для детального анализа логов: journalctl -u matrix-auth-service -f"
    safe_echo "• Для проверки конфигурации: mas doctor --config $MAS_CONFIG_FILE"
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
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_fix"
    
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
        if yq eval -i '.account = {
            "password_registration_enabled": false,
            "registration_token_required": false,
            "email_change_allowed": true,
            "displayname_change_allowed": true,
            "password_change_allowed": true,
            "password_recovery_enabled": false,
            "account_deactivation_allowed": false
        }' "$MAS_CONFIG_FILE"; then
            log "SUCCESS" "Секция account добавлена"
        else
            log "ERROR" "Не удалось добавить секцию account"
            return 1
        fi
    else
        local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$account_content" = "null" ] || [ -z "$account_content" ]; then
            log "WARN" "Секция account пуста, инициализирую..."
            if yq eval -i '.account = {
                "password_registration_enabled": false,
                "registration_token_required": false,
                "email_change_allowed": true,
                "displayname_change_allowed": true,
                "password_change_allowed": true,
                "password_recovery_enabled": false,
                "account_deactivation_allowed": false
            }' "$MAS_CONFIG_FILE"; then
                log "SUCCESS" "Секция account инициализирована"
            else
                log "ERROR" "Не удалось инициализировать секцию account"
                return 1
            fi
        else
            log "SUCCESS" "Секция account корректна"
        fi
    fi
    
    # Устанавливаем правильные права после изменений
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    # Проверяем работу MAS doctor если доступен
    if command -v mas >/dev/null 2>&1; then
        log "INFO" "Запуск диагностики MAS doctor..."
        if sudo -u "$MAS_USER" mas doctor --config "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
            log "SUCCESS" "Конфигурация MAS прошла проверку mas doctor"
        else
            log "WARN" "MAS doctor обнаружил проблемы в конфигурации"
            log "INFO" "Запустите 'sudo -u $MAS_USER mas doctor --config $MAS_CONFIG_FILE' для подробностей"
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
                
                # Создаем резервную копию существующих файлов
                if [ -d "$mas_install_dir" ]; then
                    backup_file "$mas_install_dir" "mas_share_old"
                fi
                
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
    if check_yq_dependency; then
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
    fi
    
    # Исправляем проблемы конфигурации
    log "INFO" "Исправление проблем конфигурации..."
    if ! fix_mas_config_issues; then
        log "WARN" "Некоторые проблемы конфигурации не удалось исправить автоматически"
    fi
    
    # Проверка состояния службы
    if ! systemctl is-active --quiet matrix-auth-service; then
        log "INFO" "Служба MAS не запущена, попытка запуска..."
        if restart_service "matrix-auth-service"; then
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

# Главная функция модуля
main() {
    # Проверяем, что MAS установлен
    if ! command -v mas >/dev/null 2>&1 && [ ! -f "$MAS_CONFIG_FILE" ]; then
        print_header "MATRIX AUTHENTICATION SERVICE НЕ УСТАНОВЛЕН" "$RED"
        log "ERROR" "Matrix Authentication Service не установлен"
        log "INFO" "Установите MAS через главное меню:"
        log "INFO" "  Дополнительные компоненты → Matrix Authentication Service (MAS)"
        return 1
    fi
    
    # Меню диагностики
    while true; do
        print_header "ДИАГНОСТИКА И ВОССТАНОВЛЕНИЕ MAS" "$BLUE"
        
        safe_echo "${BOLD}Доступные действия:${NC}"
        safe_echo "1. ${CYAN}🔍 Полная диагностика MAS${NC}"
        safe_echo "2. ${YELLOW}🔧 Исправить проблемы конфигурации${NC}"
        safe_echo "3. ${GREEN}🛠️  Восстановить MAS${NC}"
        safe_echo "4. ${BLUE}📁 Проверить файлы MAS${NC}"
        safe_echo "5. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-5]: " action

        case $action in
            1)
                diagnose_mas
                ;;
            2)
                fix_mas_config_issues
                ;;
            3)
                repair_mas
                ;;
            4)
                check_mas_files
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

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
