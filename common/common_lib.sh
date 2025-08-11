#!/bin/bash

# Универсальная библиотека для bash-скриптов
# Версия: 2.0.0

# Инициализация библиотеки
init_lib() {
    # Настройки по умолчанию
    LIB_NAME=${LIB_NAME:-"Common Library"}
    LIB_VERSION=${LIB_VERSION:-"2.0.0"}
    
    # Пути (можно переопределить в основном скрипте)
    SCRIPT_DIR=${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
    LOG_DIR=${LOG_DIR:-"${SCRIPT_DIR}/logs"}
    BACKUP_DIR=${BACKUP_DIR:-"${SCRIPT_DIR}/backups"}
    CONFIG_DIR=${CONFIG_DIR:-"${SCRIPT_DIR}/config"}
    MODULES_DIR=${MODULES_DIR:-"${SCRIPT_DIR}/modules"}
    
    # Создаем необходимые директории
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$CONFIG_DIR" "$MODULES_DIR"
    
    # Инициализация цветов
    init_colors
    
    # Логирование инициализации
    log "DEBUG" "Инициализация библиотеки ${LIB_NAME} v${LIB_VERSION}"
    log "DEBUG" "SCRIPT_DIR: $SCRIPT_DIR"
    log "DEBUG" "LOG_DIR: $LOG_DIR"
    log "DEBUG" "BACKUP_DIR: $BACKUP_DIR"
    log "DEBUG" "CONFIG_DIR: $CONFIG_DIR"
}

# Функция проверки поддержки цветов терминалом
supports_color() {
    if [[ -t 1 ]] && [[ -n "${TERM:-}" ]] && [[ "${TERM}" != "dumb" ]]; then
        if command -v tput >/dev/null 2>&1; then
            local colors=$(tput colors 2>/dev/null || echo 0)
            [[ $colors -ge 8 ]]
        else
            case "${TERM}" in
                *color*|xterm*|screen*|tmux*|rxvt*) return 0 ;;
                *) return 1 ;;
            esac
        fi
    else
        return 1
    fi
}

# Инициализация цветовых кодов
init_colors() {
    if supports_color; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        MAGENTA='\033[0;35m'
        WHITE='\033[1;37m'
        NC='\033[0m'
        BOLD='\033[1m'
        DIM='\033[2m'
    else
        RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; WHITE=''; NC=''; BOLD=''; DIM=''
    fi
    
    # Экспорт цветов для использования в других скриптах
    export RED GREEN YELLOW BLUE CYAN MAGENTA WHITE NC BOLD DIM
}

# Функция безопасного вывода с цветами
safe_echo() {
    local message="$1"
    if supports_color; then
        echo -e "$message"
    else
        echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g'
    fi
}

# Функция логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Определение цвета для уровня
    case "$level" in
        "ERROR") color="$RED" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARN") color="$YELLOW" ;;
        "INFO") color="$BLUE" ;;
        "DEBUG") color="$CYAN" ;;
        *) color="$NC" ;;
    esac
    
    # Форматирование сообщения
    local log_msg="[${timestamp}] [$level] ${message}"
    local colored_msg="${color}${log_msg}${NC}"
    
    # Вывод в консоль
    if [ "$level" = "DEBUG" ] && [ "${DEBUG_MODE:-false}" != "true" ]; then
        return 0
    fi
    
    if supports_color; then
        echo -e "$colored_msg"
    else
        echo "$log_msg"
    fi
    
    # Запись в лог-файл (без цветовых кодов)
    if [ -d "$LOG_DIR" ]; then
        echo "$log_msg" >> "${LOG_DIR}/${LIB_NAME// /_}.log"
    fi
}

# Проверка root-прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
    return 0
}

# Проверка подключения к интернету
check_internet() {
    local timeout=${1:-3}
    local sites=("google.com" "8.8.8.8" "1.1.1.1")
    
    for site in "${sites[@]}"; do
        if ping -c 1 -W "$timeout" "$site" >/dev/null 2>&1; then
            log "DEBUG" "Интернет доступен (проверка через $site)"
            return 0
        fi
    done
    
    log "ERROR" "Нет подключения к интернету"
    return 1
}

# Загрузка файлов с интернета
download_file() {
    local url="$1"
    local dest="$2"
    local timeout=${3:-10}
    local retries=${4:-3}
    
    log "INFO" "Загрузка файла: $url"
    
    if ! wget -q --tries="$retries" --timeout="$timeout" -O "$dest" "$url"; then
        log "ERROR" "Ошибка загрузки файла: $url"
        return 1
    fi
    
    log "SUCCESS" "Файл успешно загружен: $dest"
    return 0
}

# Создание резервной копии
backup_file() {
    local src="$1"
    local backup_name="${2:-$(basename "$src")}"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local dest="${BACKUP_DIR}/${backup_name}_${timestamp}.bak"
    
    if [ ! -f "$src" ] && [ ! -d "$src" ]; then
        log "ERROR" "Файл/директория для резервирования не существует: $src"
        return 1
    fi
    
    if ! cp -r "$src" "$dest"; then
        log "ERROR" "Ошибка создания резервной копии: $src → $dest"
        return 1
    fi
    
    log "SUCCESS" "Создана резервная копия: $dest"
    return 0
}

# Восстановление из резервной копии
restore_file() {
    local backup_path="$1"
    local dest="$2"
    
    if [ ! -f "$backup_path" ] && [ ! -d "$backup_path" ]; then
        log "ERROR" "Резервная копия не найдена: $backup_path"
        return 1
    fi
    
    if ! cp -r "$backup_path" "$dest"; then
        log "ERROR" "Ошибка восстановления из резервной копии: $backup_path → $dest"
        return 1
    fi
    
    log "SUCCESS" "Файл восстановлен из резервной копии: $dest"
    return 0
}

# Проверка состояния службы
check_service() {
    local service_name="$1"
    
    if ! systemctl is-active --quiet "$service_name"; then
        log "ERROR" "Служба $service_name не запущена"
        return 1
    fi
    
    log "INFO" "Служба $service_name работает"
    return 0
}

# Перезапуск службы
restart_service() {
    local service_name="$1"
    
    log "INFO" "Перезапуск службы: $service_name"
    
    if ! systemctl restart "$service_name"; then
        log "ERROR" "Ошибка перезапуска службы: $service_name"
        return 1
    fi
    
    log "SUCCESS" "Служба успешно перезапущена: $service_name"
    return 0
}

# Красивый заголовок
print_header() {
    local title="$1"
    local color="${2:-$BLUE}"
    local width=${3:-60}
    local padding=$(( (width - ${#title} - 2) / 2 ))
    
    echo
    safe_echo "${color}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
    safe_echo "${color}│$(printf ' %.0s' $(seq 1 $padding))${BOLD}${title}${NC}${color}$(printf ' %.0s' $(seq 1 $((width - padding - ${#title} - 1))))│${NC}"
    safe_echo "${color}└$(printf '─%.0s' $(seq 1 $width))┘${NC}"
    echo
}

# Меню выбора
show_menu() {
    local title="$1"
    shift
    local options=("$@")
    
    print_header "$title" "$MAGENTA"
    
    for i in "${!options[@]}"; do
        safe_echo "${GREEN}$((i+1)).${NC} ${options[i]}"
    done
    
    while true; do
        read -p "$(safe_echo "${YELLOW}Выберите вариант [1-${#options[@]}]: ${NC}")" choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            return "$choice"
        else
            safe_echo "${RED}Неверный выбор. Попробуйте снова.${NC}"
        fi
    done
}

# Получение информации о системе
get_system_info() {
    print_header "ИНФОРМАЦИЯ О СИСТЕМЕ"
    
    safe_echo "${BOLD}${BLUE}Операционная система:${NC}"
    cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"'
    
    safe_echo "\n${BOLD}${BLUE}Версия ядра:${NC}"
    uname -r
    
    safe_echo "\n${BOLD}${BLUE}Архитектура:${NC}"
    uname -m
    
    safe_echo "\n${BOLD}${BLUE}Загрузка CPU:${NC}"
    uptime
    
    safe_echo "\n${BOLD}${BLUE}Использование памяти:${NC}"
    free -h
    
    safe_echo "\n${BOLD}${BLUE}Дисковое пространство:${NC}"
    df -h
    
    return 0
}

# Проверка использования порта
check_port() {
    local port="$1"
    
    if ! command -v lsof &>/dev/null; then
        log "WARN" "lsof не установлен, проверка портов невозможна"
        return 2
    fi
    
    local processes=$(lsof -i ":$port" | grep -v "^COMMAND")
    
    if [ -n "$processes" ]; then
        log "WARN" "Порт $port используется следующими процессами:"
        echo "$processes"
        return 1
    fi
    
    log "INFO" "Порт $port свободен"
    return 0
}

# Добавление конфигурационной опции
set_config_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    local section="${4:-}"
    
    # Проверяем существование файла
    [ -f "$config_file" ] || touch "$config_file"
    
    # Если указана секция
    if [ -n "$section" ]; then
        # Проверяем существование секции
        if ! grep -q "^\[$section\]" "$config_file"; then
            echo -e "\n[$section]" >> "$config_file"
        fi
        
        # Проверяем существование ключа в секции
        if grep -q "^\[$section\].*$key\s*=" "$config_file"; then
            # Обновляем значение
            sed -i "/^\[$section\]/,/^\[/ s|^$key\s*=.*|$key = $value|" "$config_file"
        else
            # Добавляем ключ-значение в секцию
            sed -i "/^\[$section\]/a $key = $value" "$config_file"
        fi
    else
        # Без секции
        if grep -q "^$key\s*=" "$config_file"; then
            sed -i "s|^$key\s*=.*|$key = $value|" "$config_file"
        else
            echo "$key = $value" >> "$config_file"
        fi
    fi
    
    log "INFO" "Конфигурация обновлена: $key = $value в $config_file"
    return 0
}

# Получение значения из конфигурации
get_config_value() {
    local config_file="$1"
    local key="$2"
    local section="${3:-}"
    
    if [ ! -f "$config_file" ]; then
        log "ERROR" "Конфигурационный файл не найден: $config_file"
        return 1
    fi
    
    if [ -n "$section" ]; then
        # Ищем в указанной секции
        sed -n "/^\[$section\]/,/^\[/p" "$config_file" | grep "^$key\s*=" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    else
        # Ищем во всем файле
        grep "^$key\s*=" "$config_file" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
}

# Импорт модуля
import_module() {
    local module_name="$1"
    local module_path="${MODULES_DIR}/${module_name}.sh"
    
    if [ ! -f "$module_path" ]; then
        log "ERROR" "Модуль не найден: $module_path"
        return 1
    fi
    
    source "$module_path"
    log "DEBUG" "Модуль загружен: $module_name"
    return 0
}

# Обновление библиотеки
update_library() {
    local repo_url="${LIB_REPO_URL:-}"
    
    if [ -z "$repo_url" ]; then
        log "ERROR" "Не указан URL репозитория для обновления (LIB_REPO_URL)"
        return 1
    fi
    
    print_header "ОБНОВЛЕНИЕ БИБЛИОТЕКИ" "$YELLOW"
    
    local temp_file=$(mktemp)
    
    log "INFO" "Проверка обновлений..."
    if ! download_file "${repo_url}/common_lib.sh" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    
    local remote_version=$(grep "^LIB_VERSION=" "$temp_file" | cut -d= -f2 | tr -d '"')
    
    if [ "$remote_version" != "$LIB_VERSION" ]; then
        log "INFO" "Доступно обновление: v$LIB_VERSION → v$remote_version"
        if ask_confirmation "Установить обновление?"; then
            if ! mv "$temp_file" "${SCRIPT_DIR}/common_lib.sh"; then
                log "ERROR" "Ошибка при обновлении библиотеки"
                return 1
            fi
            chmod +x "${SCRIPT_DIR}/common_lib.sh"
            log "SUCCESS" "Библиотека успешно обновлена до версии v$remote_version"
            return 0
        fi
    else
        log "INFO" "У вас актуальная версия библиотеки (v$LIB_VERSION)"
    fi
    
    rm -f "$temp_file"
    return 0
}

# Запрос подтверждения
ask_confirmation() {
    local prompt="${1:-Продолжить?}"
    local default="${2:-Y}"
    
    while true; do
        read -p "$(safe_echo "${YELLOW}${prompt} [Y/n]: ${NC}")" answer
        answer=${answer:-$default}
        
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) safe_echo "${RED}Неверный ответ. Пожалуйста, введите Y или N.${NC}" ;;
        esac
    done
}

# Проверка зависимостей
check_dependencies() {
    local deps=("$@")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "ERROR" "Отсутствуют зависимости: ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Инициализация библиотеки при загрузке
init_lib

# Пример использования в основном скрипте:
#
# #!/bin/bash
# 
# # Настройки проекта
# LIB_NAME="My Project Library"
# LIB_VERSION="1.0.0"
# LOG_DIR="/var/log/myproject"
# 
# # Подключение библиотеки
# source "$(dirname "$0")/common/common_lib.sh"
# 
# # Основной код
# print_header "Мой проект" "$GREEN"
# 
# if check_root; then
#     log "INFO" "Скрипт запущен с root-правами"
# fi
# 
# show_menu "Главное меню" "Опция 1" "Опция 2" "Выход"
# choice=$?
# 
# case $choice in
#     1) log "INFO" "Выбрана опция 1" ;;
#     2) log "INFO" "Выбрана опция 2" ;;
#     3) exit 0 ;;
# esac