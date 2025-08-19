#!/bin/bash

# Matrix Authentication Service (MAS) Management Module

# Определение директории скрипта с учетом символических ссылок
# ВАЖНО: НЕ используем переменную SCRIPT_DIR из родительского процесса
if [[ -L "${BASH_SOURCE[0]}" ]]; then
    # Если это символическая ссылка, получаем реальный путь
    REAL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    # Если это обычный файл
    REAL_SCRIPT_PATH="${BASH_SOURCE[0]}"
fi

# Всегда определяем MAS_SCRIPT_DIR независимо от экспортированного SCRIPT_DIR
MAS_SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" && pwd)"

# Подключение общей библиотеки
if [ -f "${MAS_SCRIPT_DIR}/../common/common_lib.sh" ]; then
    source "${MAS_SCRIPT_DIR}/../common/common_lib.sh"
else
    echo "ОШИБКА: Не найдена общая библиотека common_lib.sh"
    echo "Проверяем пути:"
    echo "  REAL_SCRIPT_PATH: $REAL_SCRIPT_PATH"
    echo "  MAS_SCRIPT_DIR: $MAS_SCRIPT_DIR"
    echo "  Ищем библиотеку: ${MAS_SCRIPT_DIR}/../common/common_lib.sh"
    exit 1
fi

# Отладочная информация для поиска подмодулей
log "DEBUG" "Определение путей к подмодулям:"
log "DEBUG" "  REAL_SCRIPT_PATH: $REAL_SCRIPT_PATH"
log "DEBUG" "  MAS_SCRIPT_DIR: $MAS_SCRIPT_DIR"
log "DEBUG" "  Экспортированный SCRIPT_DIR: ${SCRIPT_DIR:-не установлен}"
log "DEBUG" "  Директория подмодулей: ${MAS_SCRIPT_DIR}/mas_sub_modules"

# Проверяем существование директории подмодулей
if [ ! -d "${MAS_SCRIPT_DIR}/mas_sub_modules" ]; then
    log "ERROR" "Директория подмодулей не найдена: ${MAS_SCRIPT_DIR}/mas_sub_modules"
    log "INFO" "Содержимое MAS_SCRIPT_DIR (${MAS_SCRIPT_DIR}):"
    ls -la "${MAS_SCRIPT_DIR}/" 2>/dev/null || log "ERROR" "Не удалось прочитать содержимое MAS_SCRIPT_DIR"
    
    # Дополнительная диагностика
    log "INFO" "Попробуем найти mas_sub_modules в разных местах..."
    
    # Проверяем в текущей директории
    if [ -d "./mas_sub_modules" ]; then
        log "INFO" "Найдена директория ./mas_sub_modules"
        ls -la "./mas_sub_modules/" 2>/dev/null | head -5
    fi
    
    # Проверяем в директории modules
    if [ -d "./modules/mas_sub_modules" ]; then
        log "INFO" "Найдена директория ./modules/mas_sub_modules"
        ls -la "./modules/mas_sub_modules/" 2>/dev/null | head -5
    fi
    
    # Проверяем относительно SCRIPT_DIR если он установлен
    if [ -n "${SCRIPT_DIR:-}" ] && [ -d "${SCRIPT_DIR}/modules/mas_sub_modules" ]; then
        log "INFO" "Найдена директория ${SCRIPT_DIR}/modules/mas_sub_modules"
        log "INFO" "Переопределяем MAS_SCRIPT_DIR на правильный путь"
        MAS_SCRIPT_DIR="${SCRIPT_DIR}/modules"
    else
        exit 1
    fi
fi

# Подключение всех подмодулей MAS
log "DEBUG" "Подключение подмодулей MAS..."

# Подключение модуля удаления MAS
if [ -f "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_removing.sh" ]; then
    source "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_removing.sh"
    log "DEBUG" "Модуль mas_removing.sh подключен"
else
    log "WARN" "Модуль mas_removing.sh не найден: ${MAS_SCRIPT_DIR}/mas_sub_modules/mas_removing.sh"
fi

# Подключение модуля диагностики и восстановления
if [ -f "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_diagnosis_and_recovery.sh" ]; then
    source "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_diagnosis_and_recovery.sh"
    log "DEBUG" "Модуль mas_diagnosis_and_recovery.sh подключен"
else
    log "WARN" "Модуль mas_diagnosis_and_recovery.sh не найден: ${MAS_SCRIPT_DIR}/mas_sub_modules/mas_diagnosis_and_recovery.sh"
fi

# Подключение модуля управления регистрацией
if [ -f "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_mas_registration.sh" ]; then
    source "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_mas_registration.sh"
    log "DEBUG" "Модуль mas_manage_mas_registration.sh подключен"
else
    log "WARN" "Модуль mas_manage_mas_registration.sh не найден: ${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_mas_registration.sh"
fi

# Подключение модуля управления SSO провайдерами
if [ -f "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_sso.sh" ]; then
    source "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_sso.sh"
    log "DEBUG" "Модуль mas_manage_sso.sh подключен"
else
    log "WARN" "Модуль mas_manage_sso.sh не найден: ${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_sso.sh"
fi

# Подключение модуля управления CAPTCHA
if [ -f "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_captcha.sh" ]; then
    source "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_captcha.sh"
    log "DEBUG" "Модуль mas_manage_captcha.sh подключен"
else
    log "WARN" "Модуль mas_manage_captcha.sh не найден: ${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_captcha.sh"
fi

# Подключение модуля управления заблокированными именами пользователей
if [ -f "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_ban_usernames.sh" ]; then
    source "${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_ban_usernames.sh"
    log "DEBUG" "Модуль mas_manage_ban_usernames.sh подключен"
else
    log "WARN" "Модуль mas_manage_ban_usernames.sh не найден: ${MAS_SCRIPT_DIR}/mas_sub_modules/mas_manage_ban_usernames.sh"
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
    log "DEBUG" "Проверка наличия утилиты yq..."
    
    if ! command -v yq &>/dev/null; then
        log "WARN" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией MAS."
        
        # Проверяем возможные альтернативные пути
        local alt_paths=("/usr/local/bin/yq" "/usr/bin/yq" "/snap/bin/yq" "/opt/bin/yq")
        for path in "${alt_paths[@]}"; do
            if [ -x "$path" ]; then
                log "INFO" "Найден yq в нестандартном расположении: $path"
                export PATH="$PATH:$(dirname "$path")"
                return 0
            fi
        done
        
        if ask_confirmation "Установить yq автоматически?"; then
            log "INFO" "Установка yq..."
            
            # Проверяем наличие snap
            if command -v snap &>/dev/null; then
                log "DEBUG" "Установка через snap..."
                local snap_output=""
                if ! snap_output=$(snap install yq 2>&1); then
                    log "ERROR" "Не удалось установить yq через snap: $snap_output"
                else
                    log "SUCCESS" "yq установлен через snap"
                    return 0
                fi
            else
                log "DEBUG" "Snap не установлен, пробуем другие методы"
            fi
            
            # Установка через GitHub releases
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
                log "ERROR" "Не удалось создать временную директорию"
                log "DEBUG" "Пробуем альтернативный путь"
                temp_dir="/tmp/yq-install-$(date +%s)"
                if ! mkdir -p "$temp_dir"; then
                    log "ERROR" "Не удалось создать временную директорию $temp_dir"
                    return 1
                fi
            fi
            
            log "DEBUG" "Создана временная директория: $temp_dir"
            local temp_yq="$temp_dir/yq"
            
            # Загружаем yq
            log "DEBUG" "Загрузка yq в $temp_yq..."
            local curl_output=""
            if command -v curl &>/dev/null; then
                if ! curl_output=$(curl -sSL --connect-timeout 10 "$yq_url" -o "$temp_yq" 2>&1); then
                    log "ERROR" "Не удалось загрузить yq с помощью curl: $curl_output"
                    rm -rf "$temp_dir"
                    return 1
                fi
            elif command -v wget &>/dev/null; then
                local wget_output=""
                if ! wget_output=$(wget -q --timeout=10 -O "$temp_yq" "$yq_url" 2>&1); then
                    log "ERROR" "Не удалось загрузить yq с помощью wget: $wget_output"
                    rm -rf "$temp_dir"
                    return 1
                fi
            else
                log "ERROR" "Не найдено средств для загрузки (curl или wget)"
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
                rm -rf "$temp_dir"
                return 1
            fi
            
            # Перемещаем файл в каталог с исполняемыми файлами
            log "DEBUG" "Перемещение yq в /usr/local/bin..."
            if ! mv "$temp_yq" /usr/local/bin/yq; then
                log "ERROR" "Не удалось переместить yq в /usr/local/bin"
                log "DEBUG" "Пробуем альтернативный путь /usr/bin..."
                if ! mv "$temp_yq" /usr/bin/yq; then
                    log "ERROR" "Не удалось переместить yq в /usr/bin"
                    rm -rf "$temp_dir"
                    return 1
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
                log "DEBUG" "Проверка наличия файла: $(ls -la /usr/local/bin/yq 2>&1 || ls -la /usr/bin/yq 2>&1 || echo "не найден")"
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

# Функция безопасного выполнения команды с расширенным логированием
safe_execute_command() {
    local cmd="$1"
    local description="$2"
    local error_message="${3:-Команда завершилась с ошибкой}"
    
    log "DEBUG" "Выполнение команды: $cmd"
    
    local output=""
    local exit_code=0
    
    # Выполняем команду с перехватом вывода и кода завершения
    if ! output=$(eval "$cmd" 2>&1); then
        exit_code=$?
        log "ERROR" "$error_message (код: $exit_code)"
        log "DEBUG" "Вывод команды: $output"
        return $exit_code
    fi
    
    log "DEBUG" "Команда успешно выполнена"
    if [ -n "$output" ]; then
        log "DEBUG" "Вывод команды: $output"
    fi
    
    echo "$output"
    return 0
}

# Проверка доступности подмодулей
check_submodule_availability() {
    local missing_modules=()
    
    log "DEBUG" "Проверка доступности подмодулей MAS..."
    log "DEBUG" "Директория подмодулей: ${MAS_SCRIPT_DIR}/mas_sub_modules"
    
    # Показываем содержимое директории подмодулей для отладки
    if [ -d "${MAS_SCRIPT_DIR}/mas_sub_modules" ]; then
        log "DEBUG" "Содержимое директории mas_sub_modules:"
        ls -la "${MAS_SCRIPT_DIR}/mas_sub_modules/" 2>/dev/null | while IFS= read -r line; do
            log "DEBUG" "  $line"
        done
    else
        log "ERROR" "Директория mas_sub_modules не существует!"
        return 1
    fi
    
    # Проверяем доступность каждого подмодуля
    if ! command -v uninstall_mas >/dev/null 2>&1; then
        missing_modules+=("mas_removing.sh")
        log "DEBUG" "Функция uninstall_mas не найдена"
    else
        log "DEBUG" "Функция uninstall_mas доступна"
    fi
    
    if ! command -v diagnose_mas >/dev/null 2>&1; then
        missing_modules+=("mas_diagnosis_and_recovery.sh")
        log "DEBUG" "Функция diagnose_mas не найдена"
    else
        log "DEBUG" "Функция diagnose_mas доступна"
    fi
    
    if ! command -v manage_mas_registration >/dev/null 2>&1; then
        missing_modules+=("mas_manage_mas_registration.sh")
        log "DEBUG" "Функция manage_mas_registration не найдена"
    else
        log "DEBUG" "Функция manage_mas_registration доступна"
    fi
    
    if ! command -v manage_sso_providers >/dev/null 2>&1; then
        missing_modules+=("mas_manage_sso.sh")
        log "DEBUG" "Функция manage_sso_providers не найдена"
    else
        log "DEBUG" "Функция manage_sso_providers доступна"
    fi
    
    if ! command -v manage_captcha_settings >/dev/null 2>&1; then
        missing_modules+=("mas_manage_captcha.sh")
        log "DEBUG" "Функция manage_captcha_settings не найдена"
    else
        log "DEBUG" "Функция manage_captcha_settings доступна"
    fi
    
    if ! command -v manage_banned_usernames >/dev/null 2>&1; then
        missing_modules+=("mas_manage_ban_usernames.sh")
        log "DEBUG" "Функция manage_banned_usernames не найдена"
    else
        log "DEBUG" "Функция manage_banned_usernames доступна"
    fi
    
    # Проверяем, что функции токенов доступны в подмодуле регистрации
    if ! command -v manage_mas_registration_tokens >/dev/null 2>&1; then
        log "WARN" "Функция manage_mas_registration_tokens недоступна"
    else
        log "DEBUG" "Функция manage_mas_registration_tokens доступна"
    fi
    
    # Проверяем, что функции восстановления доступны в подмодуле диагностики
    if ! command -v repair_mas >/dev/null 2>&1; then
        log "WARN" "Функция repair_mas недоступна"
    else
        log "DEBUG" "Функция repair_mas доступна"
    fi
    
    if ! command -v fix_mas_config_issues >/dev/null 2>&1; then
        log "WARN" "Функция fix_mas_config_issues недоступна"
    else
        log "DEBUG" "Функция fix_mas_config_issues доступна"
    fi
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        log "WARN" "Недоступные подмодули: ${missing_modules[*]}"
        log "DEBUG" "Проверим существование файлов модулей:"
        for module in "${missing_modules[@]}"; do
            local module_path="${MAS_SCRIPT_DIR}/mas_sub_modules/${module}"
            if [ -f "$module_path" ]; then
                log "DEBUG" "  $module: файл существует, но функции не загружены"
                log "DEBUG" "    Проверка синтаксиса: $(bash -n "$module_path" 2>&1 || echo "ОШИБКА СИНТАКСИСА")"
            else
                log "DEBUG" "  $module: файл отсутствует по пути $module_path"
            fi
        done
        return 1
    else
        log "SUCCESS" "Все подмодули MAS успешно подключены"
        return 0
    fi
}

# Функция экстренной диагностики путей и файлов
emergency_diagnostics() {
    print_header "ЭКСТРЕННАЯ ДИАГНОСТИКА ПОДМОДУЛЕЙ MAS" "$RED"
    
    safe_echo "${BOLD}Диагностика путей и файлов:${NC}"
    echo
    
    safe_echo "${BLUE}1. Информация о скрипте:${NC}"
    safe_echo "   BASH_SOURCE[0]: ${BASH_SOURCE[0]}"
    safe_echo "   Символическая ссылка: $([[ -L "${BASH_SOURCE[0]}" ]] && echo "Да" || echo "Нет")"
    if [[ -L "${BASH_SOURCE[0]}" ]]; then
        safe_echo "   Реальный путь: $(readlink -f "${BASH_SOURCE[0]}")"
    fi
    safe_echo "   REAL_SCRIPT_PATH: ${REAL_SCRIPT_PATH:-не определен}"
    safe_echo "   MAS_SCRIPT_DIR: ${MAS_SCRIPT_DIR:-не определен}"
    safe_echo "   Экспортированный SCRIPT_DIR: ${SCRIPT_DIR:-не установлен}"
    
    echo
    safe_echo "${BLUE}2. Проверка директорий:${NC}"
    local mas_modules_dir="${MAS_SCRIPT_DIR}/mas_sub_modules"
    safe_echo "   Директория подмодулей: $mas_modules_dir"
    
    if [ -d "$mas_modules_dir" ]; then
        safe_echo "   ${GREEN}✅ Директория существует${NC}"
        safe_echo "   Содержимое:"
        ls -la "$mas_modules_dir" | while IFS= read -r line; do
            safe_echo "     $line"
        done
    else
        safe_echo "   ${RED}❌ Директория НЕ существует${NC}"
        safe_echo "   Содержимое родительской директории (${MAS_SCRIPT_DIR}):"
        ls -la "${MAS_SCRIPT_DIR}" | while IFS= read -r line; do
            safe_echo "     $line"
        done
        
        # Дополнительный поиск
        echo
        safe_echo "   ${BLUE}Поиск mas_sub_modules в других местах:${NC}"
        
        if [ -n "${SCRIPT_DIR:-}" ] && [ -d "${SCRIPT_DIR}/modules/mas_sub_modules" ]; then
            safe_echo "   ${YELLOW}⚠️  Найдена в: ${SCRIPT_DIR}/modules/mas_sub_modules${NC}"
            safe_echo "     Содержимое:"
            ls -la "${SCRIPT_DIR}/modules/mas_sub_modules/" 2>/dev/null | head -5 | while IFS= read -r line; do
                safe_echo "       $line"
            done
        fi
        
        if [ -d "./modules/mas_sub_modules" ]; then
            safe_echo "   ${YELLOW}⚠️  Найдена в: ./modules/mas_sub_modules${NC}"
        fi
        
        if [ -d "../mas_sub_modules" ]; then
            safe_echo "   ${YELLOW}⚠️  Найдена в: ../mas_sub_modules${NC}"
        fi
    fi
    
    echo
    safe_echo "${BLUE}3. Проверка отдельных файлов подмодулей:${NC}"
    local submodules=(
        "mas_removing.sh"
        "mas_diagnosis_and_recovery.sh"
        "mas_manage_mas_registration.sh"
        "mas_manage_sso.sh"
        "mas_manage_captcha.sh"
        "mas_manage_ban_usernames.sh"
    )
    
    for submodule in "${submodules[@]}"; do
        local submodule_path="${mas_modules_dir}/${submodule}"
        safe_echo "   Проверка: $submodule"
        
        if [ -f "$submodule_path" ]; then
            safe_echo "     ${GREEN}✅ Файл существует${NC}"
            
            # Проверка прав доступа
            if [ -r "$submodule_path" ]; then
                safe_echo "     ${GREEN}✅ Файл доступен для чтения${NC}"
            else
                safe_echo "     ${RED}❌ Файл НЕ доступен для чтения${NC}"
            fi
            
            # Проверка синтаксиса
            if bash -n "$submodule_path" 2>/dev/null; then
                safe_echo "     ${GREEN}✅ Синтаксис корректен${NC}"
            else
                safe_echo "     ${RED}❌ Ошибка синтаксиса:${NC}"
                bash -n "$submodule_path" 2>&1 | while IFS= read -r error_line; do
                    safe_echo "       $error_line"
                done
            fi
            
            # Проверка размера файла
            local file_size=$(stat -c%s "$submodule_path" 2>/dev/null || echo "0")
            safe_echo "     Размер файла: $file_size байт"
            
        else
            safe_echo "     ${RED}❌ Файл НЕ существует: $submodule_path${NC}"
            
            # Ищем в альтернативных местах
            if [ -n "${SCRIPT_DIR:-}" ]; then
                local alt_path="${SCRIPT_DIR}/modules/mas_sub_modules/${submodule}"
                if [ -f "$alt_path" ]; then
                    safe_echo "     ${YELLOW}⚠️  Найден в альтернативном месте: $alt_path${NC}"
                fi
            fi
        fi
        echo
    done
    
    echo
    safe_echo "${BLUE}4. Проверка переменных окружения:${NC}"
    safe_echo "   PWD: ${PWD}"
    safe_echo "   USER: ${USER:-не определен}"
    safe_echo "   HOME: ${HOME:-не определен}"
    safe_echo "   DEBUG_MODE: ${DEBUG_MODE:-не установлен}"
    
    echo
    safe_echo "${BLUE}5. Проверка общей библиотеки:${NC}"
    local common_lib_path="${MAS_SCRIPT_DIR}/../common/common_lib.sh"
    safe_echo "   Путь к библиотеке: $common_lib_path"
    
    if [ -f "$common_lib_path" ]; then
        safe_echo "   ${GREEN}✅ Общая библиотека найдена${NC}"
        
        # Проверяем, загружена ли функция log
        if command -v log >/dev/null 2>&1; then
            safe_echo "   ${GREEN}✅ Функции библиотеки доступны (log найдена)${NC}"
        else
            safe_echo "   ${RED}❌ Функции библиотеки НЕ доступны${NC}"
        fi
    else
        safe_echo "   ${RED}❌ Общая библиотека НЕ найдена${NC}"
    fi
    
    echo
    safe_echo "${YELLOW}Рекомендации:${NC}"
    safe_echo "1. Если директория mas_sub_modules не существует, скачайте свежую версию репозитория"
    safe_echo "2. Если файлы существуют, но функции не загружаются, проверьте ошибки синтаксиса"
    safe_echo "3. Убедитесь, что вы запускаете скрипт с правами root"
    safe_echo "4. Попробуйте запустить: export DEBUG_MODE=true && ./modules/mas_manage.sh"
    safe_echo "5. Если подмодули найдены в другом месте, возможно проблема с переменными путей"
    
    echo
    read -p "Нажмите Enter для продолжения..."
}

# Функция-заглушка для недоступных функций (УЛУЧШЕННАЯ ВЕРСИЯ)
handle_missing_function() {
    local function_name="$1"
    local module_name="$2"
    
    print_header "ФУНКЦИЯ НЕДОСТУПНА" "$RED"
    log "ERROR" "Функция '$function_name' недоступна"
    log "INFO" "Требуется подмодуль: $module_name"
    log "INFO" "Убедитесь, что файл $module_name существует в директории mas_sub_modules/"
    
    echo
    safe_echo "${YELLOW}Варианты действий:${NC}"
    safe_echo "${GREEN}1.${NC} Запустить экстренную диагностику"
    safe_echo "${GREEN}2.${NC} Попробовать перезагрузить подмодули"
    safe_echo "${GREEN}3.${NC} Вернуться в меню"
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите действие [1-3]: ${NC}")" emergency_choice
    
    case $emergency_choice in
        1)
            emergency_diagnostics
            ;;
        2)
            log "INFO" "Попытка перезагрузки подмодулей..."
            
            # Пытаемся заново загрузить подмодули
            local reload_success=true
            
            # Проверяем разные возможные пути
            local module_paths=(
                "${MAS_SCRIPT_DIR}/mas_sub_modules/$module_name"
                "${SCRIPT_DIR}/modules/mas_sub_modules/$module_name"
                "./modules/mas_sub_modules/$module_name"
                "./mas_sub_modules/$module_name"
            )
            
            local found_module=false
            for module_path in "${module_paths[@]}"; do
                if [ -f "$module_path" ]; then
                    log "INFO" "Найден модуль по пути: $module_path"
                    log "INFO" "Попытка загрузки $module_name..."
                    
                    if source "$module_path" 2>/dev/null; then
                        log "SUCCESS" "Модуль $module_name загружен"
                        found_module=true
                        
                        # Проверяем, доступна ли теперь функция
                        if command -v "$function_name" >/dev/null 2>&1; then
                            log "SUCCESS" "Функция $function_name теперь доступна!"
                            return 0
                        else
                            log "WARN" "Модуль загружен, но функция $function_name все еще недоступна"
                            reload_success=false
                        fi
                        break
                    else
                        log "ERROR" "Ошибка загрузки модуля $module_name из $module_path"
                        reload_success=false
                    fi
                fi
            done
            
            if [ "$found_module" = false ]; then
                log "ERROR" "Файл модуля не найден ни в одном из ожидаемых мест:"
                for module_path in "${module_paths[@]}"; do
                    log "ERROR" "  $module_path"
                done
                reload_success=false
            fi
            
            if [ "$reload_success" = false ]; then
                safe_echo "${RED}Перезагрузка не удалась. Запустите экстренную диагностику.${NC}"
                read -p "Нажмите Enter для возврата в меню..."
            fi
            ;;
        3)
            log "INFO" "Возврат в меню"
            ;;
        *)
            log "ERROR" "Неверный выбор"
            ;;
    esac
    
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
        echo
        safe_echo "${RED}99.${NC} 🚨 Экстренная диагностика подмодулей${NC}"
        safe_echo "${GREEN}12.${NC} ↩️  Назад в главное меню"

        read -p "$(safe_echo "${YELLOW}Выберите действие [1-12, 99]: ${NC}")" action

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
            99)
                emergency_diagnostics
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
