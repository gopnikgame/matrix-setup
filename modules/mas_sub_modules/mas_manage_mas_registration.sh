#!/bin/bash

# Matrix Authentication Service (MAS) - Модуль управления регистрацией
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
MAS_USER="matrix-synapse"
MAS_GROUP="matrix-synapse"

# Проверка root прав
check_root

# Загружаем тип сервера
load_server_type

# Проверка зависимости yq
check_yq_dependency() {
    if ! command -v yq &>/dev/null; then
        log "WARN" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией MAS."
        log "DEBUG" "Проверка альтернативных расположений yq"
        
        # Проверяем возможные альтернативные пути
        local alt_paths=("/usr/local/bin/yq" "/usr/bin/yq" "/snap/bin/yq" "/opt/bin/yq")
        for path in "${alt_paths[@]}"; do
            if [ -x "$path" ]; then
                log "INFO" "Найден yq в нестандартном расположении: $path"
                log "DEBUG" "Добавление пути $(dirname "$path") в PATH"
                export PATH="$PATH:$(dirname "$path")"
                if command -v yq &>/dev/null; then
                    log "SUCCESS" "Найден и добавлен в PATH yq из: $path"
                    return 0
                else
                    log "WARN" "yq найден в $path, но не доступен после добавления в PATH"
                fi
            fi
        done
        
        if ask_confirmation "Установить yq автоматически?"; then
            log "INFO" "Установка yq..."
            if command -v snap &>/dev/null; then
                log "INFO" "Установка yq через snap..."
                local snap_output=""
                if ! snap_output=$(snap install yq 2>&1); then
                    log "ERROR" "Не удалось установить yq через snap: $snap_output"
                    log "DEBUG" "Пробуем альтернативный метод установки"
                else
                    log "SUCCESS" "yq установлен через snap"
                    if command -v yq &>/dev/null; then
                        log "DEBUG" "yq доступен в PATH после установки через snap"
                        return 0
                    else
                        log "WARN" "yq установлен через snap, но не доступен в PATH"
                        log "DEBUG" "Проверка пути: $(which yq 2>&1 || echo "не найден")"
                        log "DEBUG" "PATH: $PATH"
                        if [ -x "/snap/bin/yq" ]; then
                            log "DEBUG" "Добавление /snap/bin в PATH"
                            export PATH="$PATH:/snap/bin"
                            if command -v yq &>/dev/null; then
                                log "SUCCESS" "yq теперь доступен в PATH"
                                return 0
                            fi
                        fi
                    fi
                fi
            fi
            
            log "INFO" "Установка yq через GitHub releases..."
            local arch=$(uname -m)
            local yq_binary=""
            case "$arch" in
                x86_64) yq_binary="yq_linux_amd64" ;;
                aarch64|arm64) yq_binary="yq_linux_arm64" ;;
                *) 
                    log "ERROR" "Неподдерживаемая архитектура для yq: $arch"
                    log "DEBUG" "Доступные архитектуры: x86_64, aarch64, arm64"
                    return 1 
                    ;;
            esac
            
            log "DEBUG" "Определена архитектура: $arch, используем бинарник: $yq_binary"
            local yq_url="https://github.com/mikefarah/yq/releases/latest/download/$yq_binary"
            log "DEBUG" "URL для загрузки: $yq_url"
            
            # Создаем временную директорию для загрузки
            local temp_dir=""
            if ! temp_dir=$(mktemp -d -t yq-install-XXXXXX 2>/dev/null); then
                log "WARN" "Не удалось создать временную директорию через mktemp"
                log "DEBUG" "Пробуем альтернативный путь"
                temp_dir="/tmp/yq-install-$(date +%s)"
                if ! mkdir -p "$temp_dir"; then
                    log "ERROR" "Не удалось создать временную директорию $temp_dir"
                    log "DEBUG" "Проверка прав доступа в /tmp: $(ls -la /tmp 2>&1)"
                    return 1
                fi
            fi
            
            log "DEBUG" "Создана временная директория: $temp_dir"
            local temp_yq="$temp_dir/yq"
            
            # Загружаем yq
            log "DEBUG" "Загрузка yq в $temp_yq..."
            local download_success=false
            
            if command -v curl &>/dev/null; then
                log "DEBUG" "Загрузка с помощью curl"
                local curl_output=""
                if curl -sSL --connect-timeout 10 "$yq_url" -o "$temp_yq" 2>/dev/null; then
                    download_success=true
                    log "DEBUG" "Загрузка через curl успешна"
                else
                    curl_output=$(curl -sSL --connect-timeout 10 "$yq_url" -o "$temp_yq" 2>&1)
                    log "ERROR" "Не удалось загрузить yq с помощью curl: $curl_output"
                fi
            fi
            
            if [ "$download_success" = "false" ] && command -v wget &>/dev/null; then
                log "DEBUG" "Загрузка с помощью wget"
                local wget_output=""
                if wget -q --timeout=10 -O "$temp_yq" "$yq_url" 2>/dev/null; then
                    download_success=true
                    log "DEBUG" "Загрузка через wget успешна"
                else
                    wget_output=$(wget -q --timeout=10 -O "$temp_yq" "$yq_url" 2>&1)
                    log "ERROR" "Не удалось загрузить yq с помощью wget: $wget_output"
                fi
            fi
            
            if [ "$download_success" = "false" ]; then
                log "ERROR" "Не удалось загрузить yq. Проверьте подключение к интернету."
                rm -rf "$temp_dir"
                return 1
            fi
            
            # Проверяем успешность загрузки
            if [ ! -s "$temp_yq" ]; then
                log "ERROR" "Загруженный файл пуст или не существует"
                log "DEBUG" "Проверка файла: $(ls -la "$temp_yq" 2>&1 || echo "файл не существует")"
                rm -rf "$temp_dir"
                return 1
            fi
            
            log "DEBUG" "Размер загруженного файла: $(stat -c %s "$temp_yq" 2>/dev/null || ls -la "$temp_yq" | awk '{print $5}') байт"
            
            # Делаем файл исполняемым
            log "DEBUG" "Установка прав на исполнение..."
            if ! chmod +x "$temp_yq"; then
                log "ERROR" "Не удалось установить права на исполнение"
                log "DEBUG" "Проверка прав доступа: $(ls -la "$temp_yq" 2>&1)"
                rm -rf "$temp_dir"
                return 1
            fi
            
            # Перемещаем файл в каталог с исполняемыми файлами
            log "DEBUG" "Перемещение yq в системный каталог..."
            local install_paths=("/usr/local/bin" "/usr/bin" "/opt/bin")
            local installed=false
            
            for install_path in "${install_paths[@]}"; do
                log "DEBUG" "Попытка установки в $install_path/yq"
                if [ -d "$install_path" ] && [ -w "$install_path" ]; then
                    if mv "$temp_yq" "$install_path/yq"; then
                        log "SUCCESS" "yq успешно установлен в $install_path/yq"
                        installed=true
                        break
                    else
                        log "WARN" "Не удалось переместить файл в $install_path/yq"
                    fi
                else
                    log "DEBUG" "Каталог $install_path не существует или нет прав на запись"
                fi
            done
            
            if [ "$installed" = "false" ]; then
                log "WARN" "Не удалось установить yq в системные каталоги, пробуем локальную установку"
                local local_bin="$HOME/bin"
                
                if [ ! -d "$local_bin" ]; then
                    log "DEBUG" "Создание каталога $local_bin"
                    if ! mkdir -p "$local_bin"; then
                        log "ERROR" "Не удалось создать каталог $local_bin"
                        rm -rf "$temp_dir"
                        return 1
                    fi
                fi
                
                if mv "$temp_yq" "$local_bin/yq"; then
                    log "SUCCESS" "yq успешно установлен в $local_bin/yq"
                    installed=true
                    
                    # Добавляем в PATH
                    export PATH="$PATH:$local_bin"
                    log "INFO" "Добавлен $local_bin в PATH"
                    
                    # Добавляем в .bashrc для постоянного эффекта
                    if [ -f "$HOME/.bashrc" ]; then
                        if ! grep -q "PATH=.*$local_bin" "$HOME/.bashrc"; then
                            log "DEBUG" "Добавление $local_bin в PATH в .bashrc"
                            echo "export PATH=\$PATH:$local_bin" >> "$HOME/.bashrc"
                            log "INFO" "Добавлено в .bashrc: export PATH=\$PATH:$local_bin"
                        fi
                    fi
                else
                    log "ERROR" "Не удалось установить yq в $local_bin"
                fi
            fi
            
            # Очищаем временную директорию
            rm -rf "$temp_dir"
            
            # Проверяем, что yq теперь доступен
            if command -v yq &>/dev/null; then
                local yq_version=$(yq --version 2>&1 || echo "неизвестно")
                log "SUCCESS" "yq успешно установлен, версия: $yq_version"
                return 0
            else
                log "ERROR" "yq установлен, но не найден в PATH"
                log "DEBUG" "PATH: $PATH"
                log "DEBUG" "Проверка наличия файла yq в различных каталогах:"
                for dir in /usr/local/bin /usr/bin /opt/bin "$HOME/bin"; do
                    log "DEBUG" "  $dir/yq: $([ -x "$dir/yq" ] && echo "существует" || echo "не существует")"
                done
                return 1
            fi
        else
            log "ERROR" "yq необходим для управления конфигурацией MAS"
            log "INFO" "Установите вручную: snap install yq или apt install yq"
            return 1
        fi
    fi
    
    local yq_version=$(yq --version 2>&1 || echo "неизвестно")
    log "DEBUG" "yq найден, версия: $yq_version"
    return 0
}

# Инициализация секции account
initialize_mas_account_section() {
    log "INFO" "Инициализация секции account в конфигурации MAS..."
    log "DEBUG" "Путь к конфигурационному файлу: $MAS_CONFIG_FILE"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "DEBUG" "Проверка директории: $(ls -la "$(dirname "$MAS_CONFIG_FILE")" 2>/dev/null || echo "Директория недоступна")"
        return 1
    fi
    
    # Проверяем, есть ли уже секция account
    log "DEBUG" "Проверка наличия секции account в файле $MAS_CONFIG_FILE"
    if yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
        log "DEBUG" "Результат проверки секции account: $(echo "$account_content" | tr -d '\n' | head -c 100)..."
        if [ "$account_content" != "null" ] && [ -n "$account_content" ]; then
            log "INFO" "Секция account уже существует"
            log "DEBUG" "Секция account содержит валидные данные, инициализация не требуется"
            return 0
        else 
            log "DEBUG" "Секция account существует, но пуста или содержит null"
        fi
    else
        log "DEBUG" "Секция account отсутствует в конфигурации, будет создана"
    fi
    
    # Проверяем права доступа к файлу перед модификацией
    local file_permissions=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $1}')
    local file_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $3":"$4}')
    log "DEBUG" "Текущие права на файл: $file_permissions, владелец: $file_owner"
    
    # Создаем резервную копию
    log "DEBUG" "Создание резервной копии файла $MAS_CONFIG_FILE перед модификацией"
    backup_file "$MAS_CONFIG_FILE" "mas_config_account_init"
    local backup_result=$?
    local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_account_init_* 2>/dev/null | head -1)
    
    if [ $backup_result -eq 0 ] && [ -f "$latest_backup" ]; then
        log "DEBUG" "Резервная копия успешно создана: $latest_backup (размер: $(stat -c %s "$latest_backup" 2>/dev/null || echo "неизвестно") байт)"
    else
        log "WARN" "Проблема при создании резервной копии (код: $backup_result)"
    fi
    
    log "INFO" "Добавление секции account в конфигурацию MAS..."
    log "DEBUG" "Исходный размер файла: $(stat -c %s "$MAS_CONFIG_FILE" 2>/dev/null || echo "неизвестно") байт"
    
    # Сохраняем контрольную сумму файла перед изменением
    local checksum_before=""
    if command -v md5sum >/dev/null 2>&1; then
        checksum_before=$(md5sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "MD5 до изменения: $checksum_before"
    elif command -v sha1sum >/dev/null 2>&1; then
        checksum_before=$(sha1sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "SHA1 до изменения: $checksum_before"
    fi
    
    # Подробный лог содержимого файла перед изменением (только в debug режиме)
    if [ "${DEBUG_MODE:-false}" = "true" ]; then
        log "DEBUG" "Текущая структура файла перед модификацией:"
        yq eval 'keys' "$MAS_CONFIG_FILE" 2>&1 | while read -r line; do
            log "DEBUG" "  $line"
        done
    fi
    
    # Используем yq для добавления секции account
    local yq_output=""
    local yq_exit_code=0
    
    log "DEBUG" "Выполнение команды yq для добавления секции account"
    if ! yq_output=$(yq eval -i '.account = {
        "password_registration_enabled": false,
        "registration_token_required": false,
        "email_change_allowed": true,
        "displayname_change_allowed": true,
        "password_change_allowed": true,
        "password_recovery_enabled": false,
        "account_deactivation_allowed": false
    }' "$MAS_CONFIG_FILE" 2>&1); then
        yq_exit_code=$?
        log "ERROR" "Ошибка при выполнении yq (код: $yq_exit_code): $yq_output"
    else 
        log "DEBUG" "Команда yq выполнена без ошибок"
    fi
    
    # Проверяем, что файл изменился
    local size_after=$(stat -c %s "$MAS_CONFIG_FILE" 2>/dev/null || echo "неизвестно")
    log "DEBUG" "Размер файла после модификации: $size_after байт"
    
    # Проверяем контрольную сумму после изменения
    local checksum_after=""
    if command -v md5sum >/dev/null 2>&1 && [ -n "$checksum_before" ]; then
        checksum_after=$(md5sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "MD5 после изменения: $checksum_after"
        if [ "$checksum_before" = "$checksum_after" ]; then
            log "WARN" "Файл не изменился после выполнения yq (MD5 совпадает)"
        else
            log "DEBUG" "Файл успешно изменен (MD5 отличается)"
        fi
    elif command -v sha1sum >/dev/null 2>&1 && [ -n "$checksum_before" ]; then
        checksum_after=$(sha1sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "SHA1 после изменения: $checksum_after"
        if [ "$checksum_before" = "$checksum_after" ]; then
            log "WARN" "Файл не изменился после выполнения yq (SHA1 совпадает)"
        else
            log "DEBUG" "Файл успешно изменен (SHA1 отличается)"
        fi
    fi
    
    if [ $yq_exit_code -eq 0 ]; then
        log "SUCCESS" "Секция account добавлена"
        
        # Подробный лог содержимого файла после изменения (только в debug режиме)
        if [ "${DEBUG_MODE:-false}" = "true" ]; then
            log "DEBUG" "Структура файла после модификации:"
            yq eval 'keys' "$MAS_CONFIG_FILE" 2>&1 | while read -r line; do
                log "DEBUG" "  $line"
            done
            
            log "DEBUG" "Содержимое секции account:"
            yq eval '.account' "$MAS_CONFIG_FILE" 2>&1 | while read -r line; do
                log "DEBUG" "  $line"
            done
        fi
        
        # Проверяем валидность YAML
        log "DEBUG" "Проверка валидности YAML после модификации"
        if command -v python3 >/dev/null 2>&1; then
            local python_output=""
            if ! python_output=$(python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>&1); then
                log "ERROR" "YAML поврежден после добавления секции account: $python_output"
                log "DEBUG" "Начало содержимого файла:"
                head -n 20 "$MAS_CONFIG_FILE" 2>&1 | while read -r line; do
                    log "DEBUG" "  $line"
                done
                
                # Восстанавливаем из резервной копии
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    log "INFO" "Восстановление из резервной копии: $latest_backup"
                    if restore_file "$latest_backup" "$MAS_CONFIG_FILE"; then
                        log "SUCCESS" "Конфигурация восстановлена из резервной копии"
                    else
                        log "ERROR" "Не удалось восстановить из резервной копии"
                        # Пробуем прямое копирование
                        if cp "$latest_backup" "$MAS_CONFIG_FILE"; then
                            log "SUCCESS" "Конфигурация восстановлена прямым копированием"
                        else
                            log "ERROR" "Не удалось восстановить конфигурацию. Файл может быть поврежден!"
                        fi
                    fi
                else
                    log "ERROR" "Резервная копия не найдена для восстановления: $latest_backup"
                fi
                return 1
            else
                log "DEBUG" "YAML валиден после модификации"
            fi
        else
            log "WARN" "Python3 не найден, пропуск проверки валидности YAML"
        fi
        
    else
        log "ERROR" "Не удалось добавить секцию account (код: $yq_exit_code)"
        log "DEBUG" "Проверка наличия изменений в файле после ошибки yq"
        
        # Проверяем, не поврежден ли файл после неудачной попытки
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                log "ERROR" "YAML файл поврежден после неудачной попытки модификации"
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    log "INFO" "Восстановление из резервной копии после ошибки yq: $latest_backup"
                    restore_file "$latest_backup" "$MAS_CONFIG_FILE"
                    log "INFO" "Восстановление выполнено"
                fi
            else
                log "DEBUG" "YAML файл остался валидным несмотря на ошибку yq"
            fi
        fi
        
        return 1
    fi
    
    # Устанавливаем права
    log "DEBUG" "Установка прав доступа на файл: владелец=$MAS_USER:$MAS_GROUP, права=600"
    local chown_output=""
    if ! chown_output=$(chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>&1); then
        log "ERROR" "Ошибка при изменении владельца файла: $chown_output"
    else
        log "DEBUG" "Владелец файла успешно изменен"
    fi
    
    local chmod_output=""
    if ! chmod_output=$(chmod 600 "$MAS_CONFIG_FILE" 2>&1); then
        log "ERROR" "Ошибка при изменении прав доступа: $chmod_output"
    else
        log "DEBUG" "Права доступа успешно изменены"
    fi
    
    # Финальная проверка прав
    local final_perms=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $1}')
    local final_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $3":"$4}')
    log "DEBUG" "Финальные права на файл: $final_perms, владелец: $final_owner"
    
    # Перезапускаем MAS
    log "INFO" "Перезапуск MAS для применения изменений..."
    local restart_output=""
    local restart_success=false
    
    if restart_output=$(restart_service "matrix-auth-service" 2>&1); then
        log "DEBUG" "Команда перезапуска выполнена: $restart_output"
        restart_success=true
    else
        log "ERROR" "Ошибка выполнения команды перезапуска: $restart_output"
    fi
    
    # Проверяем статус службы после перезапуска
    log "DEBUG" "Ожидание запуска службы (2 секунды)..."
    sleep 2
    
    if systemctl is-active --quiet matrix-auth-service; then
        log "SUCCESS" "Настройка $key успешно изменена на $value"
        log "DEBUG" "Служба matrix-auth-service активна после перезапуска"
        
        # Проверяем API если доступен
        local mas_port=""
        if [ -f "$CONFIG_DIR/mas.conf" ]; then
            mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
            log "DEBUG" "Обнаружен порт MAS в конфигурации: $mas_port"
        else
            log "DEBUG" "Файл конфигурации $CONFIG_DIR/mas.conf не найден, использую порт по умолчанию"
        fi
        
        if [ -n "$mas_port" ]; then
            local health_url="http://localhost:$mas_port/health"
            log "DEBUG" "Проверка доступности API по URL: $health_url"
            
            local curl_output=""
            local curl_status=0
            if ! curl_output=$(curl -s -f --connect-timeout 5 "$health_url" 2>&1); then
                curl_status=$?
                log "WARN" "MAS запущен, но API недоступен (код: $curl_status): $curl_output"
            else
                log "SUCCESS" "MAS API доступен - настройки применены успешно"
                log "DEBUG" "Ответ API: $curl_output"
            fi
        else
            log "DEBUG" "Порт MAS не определен, пропуск проверки API"
        fi
    else
        log "ERROR" "MAS не запустился после изменения конфигурации"
        log "DEBUG" "Вывод systemctl status: $(systemctl status matrix-auth-service --no-pager -n 10 2>&1)"
        
        # Проверяем журнал systemd для диагностики
        log "DEBUG" "Последние записи в журнале MAS:"
        journalctl -u matrix-auth-service -n 5 --no-pager 2>&1 | while read -r line; do
            log "DEBUG" "  $line"
        done
        
        return 1
    fi
    
    # Проверяем, что изменение сохранилось после перезапуска
    local final_value=$(yq eval "$full_path" "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "Финальное значение параметра $key после перезапуска: '$final_value'"
    
    if [ "$final_value" = "$value" ]; then
        log "SUCCESS" "Параметр $key сохранил значение $value после перезапуска"
    else
        log "WARN" "Значение параметра $key изменилось после перезапуска: '$final_value' (было: '$value')"
    fi
    
    return 0
}

# Просмотр секции account конфигурации MAS
view_mas_account_config() {
    print_header "КОНФИГУРАЦИЯ СЕКЦИИ ACCOUNT В MAS" "$CYAN"
    
    log "DEBUG" "Запуск view_mas_account_config"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "DEBUG" "Проверка директории: $(ls -la "$(dirname "$MAS_CONFIG_FILE")" 2>/dev/null || echo "Директория недоступна")"
        return 1
    fi
    
    if ! check_yq_dependency; then
        log "ERROR" "Невозможно продолжить без yq"
        return 1
    fi
    
    log "DEBUG" "Проверка прав доступа к файлу $MAS_CONFIG_FILE"
    local file_perms=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $1}')
    local file_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $3":"$4}')
    log "DEBUG" "Права на файл: $file_perms, владелец: $file_owner"
    
    safe_echo "${BOLD}Текущая конфигурация секции account:${NC}"
    echo
    
    # Проверяем наличие секции account
    log "DEBUG" "Проверка наличия секции account в файле $MAS_CONFIG_FILE"
    local yq_output=""
    local yq_exit_code=0
    
    if ! yq_output=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>&1); then
        yq_exit_code=$?
        log "DEBUG" "Ошибка при проверке секции account (код: $yq_exit_code): $yq_output"
        safe_echo "${RED}Секция account отсутствует в конфигурации MAS${NC}"
        log "DEBUG" "Структура конфигурационного файла:"
        yq eval 'keys' "$MAS_CONFIG_FILE" 2>&1 | while read -r line; do
            log "DEBUG" "  $line"
        done
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Используйте пункты меню выше для включения настроек регистрации"
        safe_echo "• Секция account будет создана автоматически при первом изменении"
        return 1
    fi
    
    log "DEBUG" "Получение содержимого секции account"
    local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "Содержимое секции account: $(echo "$account_content" | tr -d '\n' | head -c 100)..."
    
    if [ "$account_content" = "null" ] || [ -z "$account_content" ]; then
        log "WARN" "Секция account пуста или повреждена"
        safe_echo "${RED}Секция account пуста или повреждена${NC}"
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Попробуйте переинициализировать секцию через пункт '1. Включить открытую регистрацию'"
        return 1
    fi
    
    log "DEBUG" "Секция account содержит данные, отображаю содержимое"
    
    # Показываем основные параметры регистрации
    safe_echo "${CYAN}🔐 Настройки регистрации:${NC}"
    
    local password_reg=""
    local password_reg_error=""
    
    if ! password_reg=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>&1); then
        password_reg_error=$?
        log "DEBUG" "Ошибка при получении password_registration_enabled (код: $password_reg_error): $password_reg"
        password_reg="ошибка"
    fi
    
    log "DEBUG" "password_registration_enabled=$password_reg"
    
    if [ "$password_reg" = "true" ]; then
        safe_echo "  • password_registration_enabled: ${GREEN}true${NC} (открытая регистрация включена)"
    elif [ "$password_reg" = "false" ]; then
        safe_echo "  • password_registration_enabled: ${RED}false${NC} (открытая регистрация отключена)"
    else
        safe_echo "  • password_registration_enabled: ${YELLOW}$password_reg${NC}"
    fi
    
    local token_req=""
    local token_req_error=""
    
    if ! token_req=$(yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>&1); then
        token_req_error=$?
        log "DEBUG" "Ошибка при получении registration_token_required (код: $token_req_error): $token_req"
        token_req="ошибка"
    fi
    
    log "DEBUG" "registration_token_required=$token_req"
    
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
    log "DEBUG" "email_change_allowed=$email_change"
    safe_echo "  • email_change_allowed: ${BLUE}$email_change${NC}"
    
    local display_change=$(yq eval '.account.displayname_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "displayname_change_allowed=$display_change"
    safe_echo "  • displayname_change_allowed: ${BLUE}$display_change${NC}"
    
    local password_change=$(yq eval '.account.password_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "password_change_allowed=$password_change"
    safe_echo "  • password_change_allowed: ${BLUE}$password_change${NC}"
    
    local password_recovery=$(yq eval '.account.password_recovery_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "password_recovery_enabled=$password_recovery"
    safe_echo "  • password_recovery_enabled: ${BLUE}$password_recovery${NC}"
    
    local account_deactivation=$(yq eval '.account.account_deactivation_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "account_deactivation_allowed=$account_deactivation"
    safe_echo "  • account_deactivation_allowed: ${BLUE}$account_deactivation${NC}"
    
    echo
    safe_echo "${CYAN}📄 Полная секция account (YAML):${NC}"
    echo "────────────────────────────────────────────────────────────"
    
    # Показываем полную секцию account в YAML формате
    log "DEBUG" "Вывод полной секции account в YAML формате"
    local account_yaml_output=""
    local account_yaml_error=0
    
    if ! account_yaml_output=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>&1); then
        account_yaml_error=$?
        log "ERROR" "Ошибка при получении полной секции account (код: $account_yaml_error): $account_yaml_output"
        safe_echo "${RED}Ошибка чтения секции account${NC}"
    else
        echo "$account_yaml_output"
        log "DEBUG" "Секция account успешно отображена"
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
    
    log "DEBUG" "view_mas_account_config завершен"
}

# Получение статуса открытой регистрации MAS
get_mas_registration_status() {
    log "DEBUG" "Запуск get_mas_registration_status"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "DEBUG" "Возвращаем статус: unknown"
        echo "unknown"
        return 1
    fi
    
    if ! check_yq_dependency; then
        log "ERROR" "Невозможно продолжить без yq"
        log "DEBUG" "Возвращаем статус: unknown"
        echo "unknown"
        return 1
    fi
    
    log "DEBUG" "Получение значения параметра password_registration_enabled"
    local status=""
    local status_error=0
    
    if ! status=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>&1); then
        status_error=$?
        log "DEBUG" "Ошибка при получении password_registration_enabled (код: $status_error): $status"
        log "DEBUG" "Возвращаем статус: unknown"
        echo "unknown"
        return 1
    fi
    
    log "DEBUG" "Полученное значение: $status"
    
    if [ "$status" = "true" ]; then
        log "DEBUG" "Возвращаем статус: enabled"
        echo "enabled"
    elif [ "$status" = "false" ]; then
        log "DEBUG" "Возвращаем статус: disabled"
        echo "disabled" 
    else
        log "DEBUG" "Возвращаем статус: unknown (неожиданное значение: $status)"
        echo "unknown"
    fi
}

# Получение статуса регистрации по токенам
get_mas_token_registration_status() {
    log "DEBUG" "Запуск get_mas_token_registration_status"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "DEBUG" "Возвращаем статус: unknown"
        echo "unknown"
        return 1
    fi
    
    if ! check_yq_dependency; then
        log "ERROR" "Невозможно продолжить без yq"
        log "DEBUG" "Возвращаем статус: unknown"
        echo "unknown"
        return 1
    fi
    
    log "DEBUG" "Получение значения параметра registration_token_required"
    local status=""
    local status_error=0
    
    if ! status=$(yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>&1); then
        status_error=$?
        log "DEBUG" "Ошибка при получении registration_token_required (код: $status_error): $status"
        log "DEBUG" "Возвращаем статус: unknown"
        echo "unknown"
        return 1
    fi
    
    log "DEBUG" "Полученное значение: $status"
    
    if [ "$status" = "true" ]; then
        log "DEBUG" "Возвращаем статус: enabled"
        echo "enabled"
    elif [ "$status" = "false" ]; then
        log "DEBUG" "Возвращаем статус: disabled"
        echo "disabled"
    else
        log "DEBUG" "Возвращаем статус: unknown (неожиданное значение: $status)"
        echo "unknown"
    fi
}

# Генерация ULID для токенов
generate_ulid() {
    # Простая генерация ULID-подобного идентификатора
    local timestamp=$(printf '%010x' $(date +%s))
    local random_part=$(openssl rand -hex 10 | tr '[:lower:]' '[:upper:]')
    echo "$(echo "$timestamp$random_part" | tr '[:lower:]' '[:upper:]')"
}

# Создание токена регистрации
create_registration_token() {
    print_header "СОЗДАНИЕ ТОКЕНА РЕГИСТРАЦИИ" "$CYAN"
    
    log "DEBUG" "Запуск create_registration_token"
    
    safe_echo "${BOLD}Параметры токена регистрации:${NC}"
    safe_echo "• ${BLUE}Кастомный токен${NC} - используйте свою строку или оставьте пустым для автогенерации"
    safe_echo "• ${BLUE}Лимит использований${NC} - количество раз, которое можно использовать токен"
    safe_echo "• ${BLUE}Срок действия${NC} - время жизни токена в секундах"
    echo
    
    # Проверяем, что MAS запущен
    if ! systemctl is-active --quiet matrix-auth-service; then
        log "ERROR" "MAS не запущен, невозможно создать токен"
        safe_echo "${RED}❌ Matrix Authentication Service не запущен!${NC}"
        safe_echo "${YELLOW}Для создания токенов MAS должен быть запущен.${NC}"
        return 1
    else
        log "DEBUG" "MAS запущен, продолжаем создание токена"
    fi
    
    # Параметры токена
    read -p "Введите кастомный токен (или оставьте пустым для автогенерации): " custom_token
    log "DEBUG" "Введен кастомный токен: '${custom_token:-пусто}'"
    
    read -p "Лимит использований (или оставьте пустым для неограниченного): " usage_limit
    log "DEBUG" "Введен лимит использований: '${usage_limit:-пусто}'"
    
    read -p "Срок действия в секундах (или оставьте пустым для бессрочного): " expires_in
    log "DEBUG" "Введен срок действия: '${expires_in:-пусто}' секунд"
    
    # Формируем команду
    local cmd="mas manage issue-user-registration-token --config $MAS_CONFIG_FILE"
    
    if [ -n "$custom_token" ]; then
        cmd="$cmd --token '$custom_token'"
    fi
    
    if [ -n "$usage_limit" ]; then
        if [[ ! "$usage_limit" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Лимит использований должен быть числом: '$usage_limit'"
            safe_echo "${RED}❌ Ошибка: Лимит использований должен быть числом${NC}"
            return 1
        fi
        cmd="$cmd --usage-limit $usage_limit"
    fi
    
    if [ -n "$expires_in" ]; then
        if [[ ! "$expires_in" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Срок действия должен быть числом в секундах: '$expires_in'"
            safe_echo "${RED}❌ Ошибка: Срок действия должен быть числом в секундах${NC}"
            return 1
        fi
        cmd="$cmd --expires-in $expires_in"
    fi
    
    log "INFO" "Создание токена регистрации..."
    log "DEBUG" "Команда: $cmd"
    
    # Проверяем наличие пользователя MAS
    if ! id -u "$MAS_USER" >/dev/null 2>&1; then
        log "ERROR" "Пользователь $MAS_USER не существует"
        safe_echo "${RED}❌ Ошибка: Пользователь $MAS_USER не существует${NC}"
        return 1
    fi
    
    # Проверяем доступность утилиты mas
    if ! command -v mas >/dev/null 2>&1; then
        log "ERROR" "Утилита 'mas' не найдена"
        safe_echo "${RED}❌ Ошибка: Утилита 'mas' не найдена${NC}"
        safe_echo "${YELLOW}Убедитесь, что MAS установлен корректно${NC}"
        return 1
    fi
    
    # Выполняем команду как пользователь MAS
    local output
    local exit_code=0
    
    log "DEBUG" "Выполнение команды от имени пользователя $MAS_USER"
    if ! output=$(sudo -u "$MAS_USER" eval "$cmd" 2>&1); then
        exit_code=$?
        log "ERROR" "Ошибка создания токена регистрации (код: $exit_code)"
        log "ERROR" "Вывод: $output"
        
        safe_echo "${RED}❌ Ошибка создания токена регистрации${NC}"
        safe_echo "${YELLOW}Вывод команды:${NC}"
        safe_echo "$output"
        echo
        safe_echo "${YELLOW}Возможные причины ошибки:${NC}"
        safe_echo "• MAS не запущен (проверьте: systemctl status matrix-auth-service)"
        safe_echo "• Проблемы с базой данных"
        safe_echo "• Недостаточные права пользователя $MAS_USER"
        safe_echo "• Проблемы с конфигурацией MAS"
        
        log "DEBUG" "Дополнительная диагностика:"
        log "DEBUG" "Статус сервиса: $(systemctl is-active matrix-auth-service 2>&1)"
        log "DEBUG" "Права на конфигурационный файл: $(ls -la "$MAS_CONFIG_FILE" 2>&1)"
        log "DEBUG" "Последние логи сервиса:"
        journalctl -u matrix-auth-service -n 5 --no-pager 2>&1 | while read -r line; do
            log "DEBUG" "  $line"
        done
        
        return 1
    fi
    
    log "SUCCESS" "Токен регистрации создан"
    log "DEBUG" "Созданный токен: $output"
    
    echo
    safe_echo "${BOLD}${GREEN}Созданный токен:${NC}"
    safe_echo "${CYAN}$output${NC}"
    echo
    safe_echo "${YELLOW}📝 Сохраните этот токен - он больше не будет показан!${NC}"
    safe_echo "${BLUE}Передайте токен пользователю для регистрации${NC}"
    
    # Создаем запись в журнале (без токена по соображениям безопасности)
    if [ -n "$custom_token" ]; then
        log "INFO" "Создан пользовательский токен регистрации: [СКРЫТО]"
    else
        log "INFO" "Создан автоматически сгенерированный токен регистрации: [СКРЫТО]"
    fi
    
    if [ -n "$usage_limit" ]; then
        log "INFO" "Лимит использований токена: $usage_limit"
    fi
    
    if [ -n "$expires_in" ]; then
        log "INFO" "Срок действия токена: $expires_in секунд"
    fi
    
    log "DEBUG" "Завершение create_registration_token"
    return 0
}

# Показ информации о токенах
show_registration_tokens_info() {
    print_header "ИНФОРМАЦИЯ О ТОКЕНАХ РЕГИСТРАЦИИ" "$CYAN"
    
    log "DEBUG" "Запуск show_registration_tokens_info"
    
    safe_echo "${BOLD}Что такое токены регистрации?${NC}"
    safe_echo "Токены регистрации позволяют контролировать регистрацию пользователей."
    safe_echo "Когда включено требование токенов (registration_token_required: true),"
    safe_echo "пользователи должны предоставить действительный токен для регистрации."
    echo
    
    safe_echo "${BOLD}${GREEN}Как использовать токены:${NC}"
    safe_echo "1. ${BLUE}Создайте токен${NC} с помощью этого меню"
    safe_echo "2. ${BLUE}Передайте токен${NC} пользователю любым безопасным способом"
    safe_echo "3. ${BLUE}Пользователь вводит токен${NC} при регистрации на сервере"
    safe_echo "4. ${BLUE}После использования${NC} лимит токена уменьшается"
    echo
    
    safe_echo "${BOLD}${CYAN}Параметры токенов:${NC}"
    safe_echo "• ${YELLOW}Кастомный токен${NC} - задайте свою строку (например, 'invite2024') или автогенерация"
    safe_echo "• ${YELLOW}Лимит использований${NC} - сколько раз можно использовать (например, 5 для группы)"
    safe_echo "• ${YELLOW}Срок действия${NC} - время жизни токена в секундах"
    echo
    
    safe_echo "${BOLD}${BLUE}Примеры сроков действия:${NC}"
    safe_echo "• ${GREEN}3600${NC} = 1 час"
    safe_echo "• ${GREEN}86400${NC} = 1 день"
    safe_echo "• ${GREEN}604800${NC} = 1 неделя"
    safe_echo "• ${GREEN}2592000${NC} = 1 месяц"
    safe_echo "• ${GREEN}пусто${NC} = бессрочный токен"
    echo
    
    safe_echo "${BOLD}${MAGENTA}Примеры использования:${NC}"
    safe_echo "• ${CYAN}Частный сервер${NC}: создайте токены для друзей/семьи"
    safe_echo "• ${CYAN}Корпоративный сервер${NC}: токены для новых сотрудников"
    safe_echo "• ${CYAN}Временный доступ${NC}: токены с ограниченным сроком действия"
    safe_echo "• ${CYAN}Групповые приглашения${NC}: один токен для нескольких человек"
    echo
    
    safe_echo "${BOLD}${RED}Безопасность:${NC}"
    safe_echo "• ${YELLOW}Никогда не передавайте токены через незащищенные каналы${NC}"
    safe_echo "• ${YELLOW}Используйте токены с ограниченным сроком действия${NC}"
    safe_echo "• ${YELLOW}Отслеживайте использование токенов${NC}"
    safe_echo "• ${YELLOW}Удаляйте неиспользованные токены${NC}"
    
    # Проверяем текущее состояние регистрации по токенам
    log "DEBUG" "Проверка текущего статуса регистрации по токенам"
    local token_status=$(get_mas_token_registration_status)
    log "DEBUG" "Текущий статус регистрации по токенам: $token_status"
    
    if [ "$token_status" = "enabled" ]; then
        echo
        safe_echo "${GREEN}ℹ️  Требование токенов регистрации сейчас: ВКЛЮЧЕНО${NC}"
    elif [ "$token_status" = "disabled" ]; then
        echo
        safe_echo "${RED}⚠️  Требование токенов регистрации сейчас: ОТКЛЮЧЕНО${NC}"
        safe_echo "${YELLOW}Для использования токенов включите регистрацию по токенам в меню управления.${NC}"
    fi
    
    log "DEBUG" "Завершение show_registration_tokens_info"
}

# Управление токенами регистрации MAS
manage_mas_registration_tokens() {
    print_header "УПРАВЛЕНИЕ ТОКЕНАМИ РЕГИСТРАЦИИ MAS" "$BLUE"
    
    log "DEBUG" "Запуск manage_mas_registration_tokens"
    
    # Проверка наличия yq
    if ! check_yq_dependency; then
        log "ERROR" "Невозможно продолжить без yq"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi
    
    # Проверяем, что MAS запущен
    log "DEBUG" "Проверка статуса службы matrix-auth-service"
    if ! systemctl is-active --quiet matrix-auth-service; then
        log "WARN" "Matrix Authentication Service не запущен"
        log "INFO" "Для создания токенов MAS должен быть запущен"
        
        safe_echo "${RED}❌ Matrix Authentication Service не запущен!${NC}"
        safe_echo "${YELLOW}Для создания токенов MAS должен быть запущен.${NC}"
        
        if ask_confirmation "Попробовать запустить MAS?"; then
            log "INFO" "Попытка запуска MAS"
            
            local restart_output=""
            if restart_output=$(restart_service "matrix-auth-service" 2>&1); then
                log "DEBUG" "Команда перезапуска выполнена: $restart_output"
                log "INFO" "Ожидание запуска службы (2 секунды)..."
                sleep 2
                
                if systemctl is-active --quiet matrix-auth-service; then
                    log "SUCCESS" "MAS успешно запущен"
                    safe_echo "${GREEN}✅ MAS успешно запущен${NC}"
                else
                    log "ERROR" "Не удалось запустить MAS"
                    log "DEBUG" "Вывод systemctl status: $(systemctl status matrix-auth-service --no-pager -n 5 2>&1)"
                    
                    safe_echo "${RED}❌ Не удалось запустить MAS${NC}"
                    safe_echo "${YELLOW}Проверьте логи: journalctl -u matrix-auth-service -n 20${NC}"
                    read -p "Нажмите Enter для возврата..."
                    return 1
                fi
            else
                log "ERROR" "Ошибка запуска MAS: $restart_output"
                safe_echo "${RED}❌ Ошибка запуска MAS${NC}"
                safe_echo "${YELLOW}Ошибка: $restart_output${NC}"
                read -p "Нажмите Enter для возврата..."
                return 1
            fi
        else
            log "INFO" "Пользователь отказался от запуска MAS"
            read -p "Нажмите Enter для возврата..."
            return 1
        fi
    else
        log "DEBUG" "MAS запущен, продолжаем"
    fi

    while true; do
        # Показываем текущий статус токенов
        log "DEBUG" "Получение текущего статуса токенов"
        local token_status=$(get_mas_token_registration_status)
        log "DEBUG" "Текущий статус токенов: $token_status"
        
        safe_echo "Текущий статус:"
        case "$token_status" in
            "enabled") 
                safe_echo "• Токены регистрации: ${GREEN}ТРЕБУЮТСЯ${NC}"
                log "DEBUG" "Токены регистрации требуются"
                ;;
            "disabled") 
                safe_echo "• Токены регистрации: ${RED}НЕ ТРЕБУЮТСЯ${NC}"
                log "DEBUG" "Токены регистрации не требуются"
                ;;
            *) 
                safe_echo "• Токены регистрации: ${YELLOW}НЕИЗВЕСТНО${NC}"
                log "WARN" "Неизвестный статус токенов: $token_status"
                ;;
        esac
        
        # Показываем статус MAS
        log "DEBUG" "Проверка статуса службы matrix-auth-service"
        if systemctl is-active --quiet matrix-auth-service; then
            safe_echo "• MAS служба: ${GREEN}АКТИВНА${NC}"
            log "DEBUG" "MAS служба активна"
        else
            safe_echo "• MAS служба: ${RED}НЕ АКТИВНА${NC}"
            log "WARN" "MAS служба не активна"
        fi
        
        echo
        safe_echo "${BOLD}Управление токенами регистрации:${NC}"
        safe_echo "1. ${GREEN}✅ Включить требование токенов регистрации${NC}"
        safe_echo "2. ${RED}❌ Отключить требование токенов регистрации${NC}"
        safe_echo "3. ${BLUE}Создать новый токен регистрации${NC}"
        safe_echo "4. ${CYAN}ℹ️  Показать информацию о токенах${NC}"
        safe_echo "5. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-5]: " action
        log "DEBUG" "Выбрано действие: $action"

        case $action in
            1)
                log "INFO" "Включение требования токенов регистрации"
                set_mas_config_value "registration_token_required" "true"
                ;;
            2)
                log "INFO" "Отключение требования токенов регистрации"
                set_mas_config_value "registration_token_required" "false"
                ;;
            3)
                log "INFO" "Создание нового токена регистрации"
                create_registration_token
                ;;
            4)
                log "INFO" "Отображение информации о токенах"
                show_registration_tokens_info
                ;;
            5)
                log "INFO" "Возврат в предыдущее меню"
                log "DEBUG" "Завершение manage_mas_registration_tokens"
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод: $action"
                safe_echo "${RED}❌ Некорректный ввод. Попробуйте ещё раз.${NC}"
                sleep 1
                ;;
        esac
        
        if [ $action -ne 5 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
            log "DEBUG" "Пользователь нажал Enter для продолжения"
        fi
    done
}

# Меню управления регистрацией MAS
manage_mas_registration() {
    print_header "УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ MATRIX AUTHENTICATION SERVICE" "$BLUE"
    
    log "DEBUG" "Запуск manage_mas_registration"

    if ! check_yq_dependency; then
        log "ERROR" "Невозможно продолжить без yq"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi
    
    # Проверяем существование конфигурационного файла
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "DEBUG" "Проверка директории: $(ls -la "$(dirname "$MAS_CONFIG_FILE")" 2>/dev/null || echo "Директория недоступна")"
        
        safe_echo "${RED}❌ Файл конфигурации MAS не найден: $MAS_CONFIG_FILE${NC}"
        safe_echo "${YELLOW}Убедитесь, что MAS установлен и настроен${NC}"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    log "DEBUG" "Проверка прав доступа к файлу $MAS_CONFIG_FILE"
    local file_perms=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $1}')
    local file_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null || ls -la "$MAS_CONFIG_FILE" | awk '{print $3":"$4}')
    log "DEBUG" "Права на файл: $file_perms, владелец: $file_owner"

    while true; do
        # Показываем текущий статус
        log "DEBUG" "Получение текущего статуса регистрации"
        local current_status=$(get_mas_registration_status)
        local token_status=$(get_mas_token_registration_status)
        log "DEBUG" "Текущий статус открытой регистрации: $current_status, статус токенов: $token_status"
        
        safe_echo "${BOLD}Текущий статус регистрации:${NC}"
        case "$current_status" in
            "enabled") 
                safe_echo "• Открытая регистрация: ${GREEN}ВКЛЮЧЕНА${NC}"
                log "DEBUG" "Открытая регистрация включена"
                ;;
            "disabled") 
                safe_echo "• Открытая регистрация: ${RED}ОТКЛЮЧЕНА${NC}"
                log "DEBUG" "Открытая регистрация отключена"
                ;;
            *) 
                safe_echo "• Открытая регистрация: ${YELLOW}НЕИЗВЕСТНО${NC}"
                log "WARN" "Неизвестный статус открытой регистрации: $current_status"
                ;;
        esac
        
        case "$token_status" in
            "enabled") 
                safe_echo "• Регистрация по токенам: ${GREEN}ТРЕБУЕТСЯ${NC}"
                log "DEBUG" "Регистрация по токенам требуется"
                ;;
            "disabled") 
                safe_echo "• Регистрация по токенам: ${RED}НЕ ТРЕБУЕТСЯ${NC}"
                log "DEBUG" "Регистрация по токенам не требуется"
                ;;
            *) 
                safe_echo "• Регистрация по токенам: ${YELLOW}НЕИЗВЕСТНО${NC}"
                log "WARN" "Неизвестный статус регистрации по токенам: $token_status"
                ;;
        esac
        
        # Показываем статус MAS
        log "DEBUG" "Проверка статуса службы matrix-auth-service"
        if systemctl is-active --quiet matrix-auth-service; then
            safe_echo "• MAS служба: ${GREEN}АКТИВНА${NC}"
            log "DEBUG" "MAS служба активна"
        else
            safe_echo "• MAS служба: ${RED}НЕ АКТИВНА${NC}"
            log "WARN" "MAS служба не активна"
        fi
        
        # Вывод рекомендаций на основе текущего состояния
        if [ "$current_status" = "enabled" ] && [ "$token_status" = "disabled" ]; then
            echo
            safe_echo "${YELLOW}⚠️ Предупреждение:${NC} Открытая регистрация включена без требования токенов."
            safe_echo "${YELLOW}   Это означает, что любой может зарегистрироваться на вашем сервере.${NC}"
            safe_echo "${CYAN}   Рекомендуется включить требование токенов или отключить открытую регистрацию.${NC}"
            log "WARN" "Открытая регистрация включена без требования токенов - небезопасная конфигурация"
        fi
        
        echo
        safe_echo "${BOLD}Управление регистрацией MAS:${NC}"
        safe_echo "1. ${GREEN}✅ Включить открытую регистрацию${NC}"
        safe_echo "2. ${RED}❌ Выключить открытую регистрацию${NC}"
        safe_echo "3. ${BLUE}🔐 Включить требование токенов регистрации${NC}"
        safe_echo "4. ${YELLOW}🔓 Отключить требование токенов регистрации${NC}"
        safe_echo "5. ${CYAN}📄 Просмотреть конфигурацию account${NC}"
        safe_echo "6. ${MAGENTA}🎫 Управление токенами регистрации${NC}"
        safe_echo "7. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-7]: " action
        log "DEBUG" "Выбрано действие: $action"

        case $action in
            1)
                log "INFO" "Включение открытой регистрации"
                set_mas_config_value "password_registration_enabled" "true"
                ;;
            2)
                log "INFO" "Выключение открытой регистрации"
                set_mas_config_value "password_registration_enabled" "false"
                ;;
            3)
                log "INFO" "Включение требования токенов регистрации"
                set_mas_config_value "registration_token_required" "true"
                ;;
            4)
                log "INFO" "Отключение требования токенов регистрации"
                set_mas_config_value "registration_token_required" "false"
                ;;
            5)
                log "INFO" "Просмотр конфигурации account"
                view_mas_account_config
                ;;
            6)
                log "INFO" "Переход в меню управления токенами регистрации"
                manage_mas_registration_tokens
                ;;
            7)
                log "INFO" "Возврат в предыдущее меню"
                log "DEBUG" "Завершение manage_mas_registration"
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод: $action"
                safe_echo "${RED}❌ Некорректный ввод. Попробуйте ещё раз.${NC}"
                sleep 1
                ;;
        esac
        
        if [ $action -ne 7 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Главная функция модуля
main() {
    log "DEBUG" "Запуск главной функции модуля mas_manage_mas_registration.sh"
    
    # Проверяем, что MAS установлен
    if ! command -v mas >/dev/null 2>&1 && [ ! -f "$MAS_CONFIG_FILE" ]; then
        print_header "MATRIX AUTHENTICATION SERVICE НЕ УСТАНОВЛЕН" "$RED"
        log "ERROR" "Matrix Authentication Service не установлен"
        log "INFO" "Установите MAS через главное меню"
        
        safe_echo "${RED}❌ Matrix Authentication Service не установлен!${NC}"
        safe_echo "${YELLOW}Установите MAS через главное меню:${NC}"
        safe_echo "${CYAN}  Дополнительные компоненты → Matrix Authentication Service (MAS)${NC}"
        return 1
    else
        log "DEBUG" "MAS установлен, запуск меню управления регистрацией"
        manage_mas_registration
    fi
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log "DEBUG" "Скрипт mas_manage_mas_registration.sh запущен напрямую"
    main "$@"
fi
