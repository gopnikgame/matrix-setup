#!/bin/bash

# Matrix Setup & Management Tool - Installation Script
# Скрипт быстрой установки с поддержкой библиотеки common_lib.sh
# Версия: 3.0.0

# Настройки установки
REPO_URL="https://github.com/gopnikgame/matrix-setup.git"
INSTALL_DIR="/opt/matrix-setup"
LINK_PATH="/usr/local/bin/manager-matrix"
TEMP_DIR="/tmp/matrix-setup-install"

# Временные цвета для начального вывода (до загрузки библиотеки)
RED='\033[0;31m'
GREEN='\'\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Функция безопасного вывода с цветами
safe_echo() {
    local message="$1"
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
        echo -e "$message"
    else
        echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g'
    fi
}

# Функция простого логирования до загрузки библиотеки
simple_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "ERROR") color="$RED" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARN") color="$YELLOW" ;;
        "INFO") color="$BLUE" ;;
        *) color="$NC" ;;
    esac
    
    safe_echo "${color}[$timestamp] [$level] ${message}${NC}"
}

# Функция проверки root прав
check_root_simple() {
    if [[ $EUID -ne 0 ]]; then
        simple_log "ERROR" "Этот скрипт должен быть запущен с правами root (sudo)"
        simple_log "INFO" "Запустите: sudo $0"
        exit 1
    fi
}

# Функция проверки подключения к интернету
check_internet_simple() {
    simple_log "INFO" "Проверка подключения к интернету..."
    
    local sites=("google.com" "github.com" "8.8.8.8")
    for site in "${sites[@]}"; do
        if ping -c 1 -W 3 "$site" >/dev/null 2>&1; then
            simple_log "SUCCESS" "Интернет подключение работает"
            return 0
        fi
    done
    
    simple_log "ERROR" "Нет подключения к интернету"
    simple_log "INFO" "Проверьте сетевое подключение и попробуйте снова"
    return 1
}

# Функция установки зависимостей
install_dependencies() {
    simple_log "INFO" "Установка необходимых зависимостей..."
    
    # Обновление списка пакетов
    if ! apt update >/dev/null 2>&1; then
        simple_log "WARN" "Не удалось обновить список пакетов, продолжаем..."
    fi
    
    # Установка основных зависимостей
    local packages=("git" "curl" "wget" "ca-certificates")
    local missing_packages=()
    
    # Проверка каких пакетов не хватает
    for package in "${packages[@]}"; do
        if ! command -v "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        simple_log "INFO" "Установка пакетов: ${missing_packages[*]}"
        if apt install -y "${missing_packages[@]}" >/dev/null 2>&1; then
            simple_log "SUCCESS" "Зависимости установлены"
        else
            simple_log "ERROR" "Ошибка установки зависимостей"
            return 1
        fi
    else
        simple_log "INFO" "Все необходимые зависимости уже установлены"
    fi
    
    return 0
}

# Функция клонирования репозитория
clone_repository() {
    simple_log "INFO" "Скачивание Matrix Setup Tool..."
    
    # Создание временной директории
    mkdir -p "$TEMP_DIR"
    
    # Удаление существующей установки если есть
    if [ -d "$INSTALL_DIR" ]; then
        simple_log "INFO" "Обнаружена существующая установка в $INSTALL_DIR"
        
        # Создание резервной копии
        local backup_dir="/opt/matrix-setup-backup-$(date +%Y%m%d_%H%M%S)"
        simple_log "INFO" "Создание резервной копии в $backup_dir"
        mv "$INSTALL_DIR" "$backup_dir"
        simple_log "SUCCESS" "Резервная копия создана: $backup_dir"
    fi
    
    # Создание директории установки
    mkdir -p /opt
    
    # Клонирование репозитория
    simple_log "INFO" "Клонирование из $REPO_URL..."
    if git clone "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1; then
        simple_log "SUCCESS" "Репозиторий успешно клонирован"
    else
        simple_log "ERROR" "Ошибка клонирования репозитория"
        simple_log "INFO" "Проверьте подключение к интернету и доступность GitHub"
        return 1
    fi
    
    return 0
}

# Функция загрузки библиотеки common_lib.sh
load_common_library() {
    local lib_path="$INSTALL_DIR/common/common_lib.sh"
    
    simple_log "INFO" "Загрузка общей библиотеки..."
    
    if [ ! -f "$lib_path" ]; then
        simple_log "ERROR" "Библиотека common_lib.sh не найдена: $lib_path"
        simple_log "INFO" "Проверьте целостность репозитория"
        return 1
    fi
    
    # Инициализация библиотеки с настройками для установщика
    export LIB_NAME="Matrix Setup Installer"
    export LIB_VERSION="3.0.0"
    export SCRIPT_DIR="$INSTALL_DIR"
    export LOG_DIR="$INSTALL_DIR/logs"
    export DEBUG_MODE="false"
    
    # Загрузка библиотеки
    if source "$lib_path"; then
        simple_log "SUCCESS" "Библиотека common_lib.sh загружена"
        
        # Инициализация библиотеки
        init_lib
        
        return 0
    else
        simple_log "ERROR" "Ошибка загрузки библиотеки common_lib.sh"
        return 1
    fi
}

# Функция настройки прав доступа
setup_permissions() {
    log "INFO" "Настройка прав доступа..."
    
    # Установка прав выполнения на все bash скрипты
    find "$INSTALL_DIR" -name "*.sh" -type f -exec chmod +x {} \;
    
    # Установка владельца
    chown -R root:root "$INSTALL_DIR"
    
    # Особые права для директории логов
    if [ -d "$INSTALL_DIR/logs" ]; then
        chmod 755 "$INSTALL_DIR/logs"
    fi
    
    log "SUCCESS" "Права доступа настроены"
    return 0
}

# Функция создания символической ссылки
create_symlink() {
    log "INFO" "Создание символической ссылки для глобального доступа..."
    
    # Проверка существования главного скрипта
    if [ ! -f "$INSTALL_DIR/manager-matrix.sh" ]; then
        log "ERROR" "Главный скрипт не найден: $INSTALL_DIR/manager-matrix.sh"
        return 1
    fi
    
    # Удаление существующей ссылки
    if [ -L "$LINK_PATH" ] || [ -f "$LINK_PATH" ]; then
        rm -f "$LINK_PATH"
    fi
    
    # Создание новой символической ссылки
    if ln -sf "$INSTALL_DIR/manager-matrix.sh" "$LINK_PATH"; then
        log "SUCCESS" "Символическая ссылка создана: $LINK_PATH"
    else
        log "ERROR" "Ошибка создания символической ссылки"
        return 1
    fi
    
    # Проверка PATH
    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        log "WARN" "/usr/local/bin не в PATH, добавьте в ~/.bashrc:"
        log "INFO" "export PATH=\"/usr/local/bin:\$PATH\""
    fi
    
    return 0
}

# Функция проверки установки
verify_installation() {
    log "INFO" "Проверка установки..."
    
    local errors=0
    
    # Проверка основных файлов
    local required_files=(
        "$INSTALL_DIR/manager-matrix.sh"
        "$INSTALL_DIR/common/common_lib.sh"
        "$INSTALL_DIR/modules/core_install.sh"
        "$INSTALL_DIR/modules/element_web.sh"
        "$INSTALL_DIR/modules/coturn_setup.sh"
        "$INSTALL_DIR/modules/caddy_config.sh"
        "$INSTALL_DIR/modules/synapse_admin.sh"
        "$INSTALL_DIR/modules/federation_control.sh"
        "$INSTALL_DIR/modules/registration_control.sh"
        "$INSTALL_DIR/modules/ufw_config.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            log "DEBUG" "✅ $file"
        else
            log "ERROR" "❌ $file (отсутствует или не исполняемый)"
            errors=$((errors + 1))
        fi
    done
    
    # Проверка символической ссылки
    if [ -L "$LINK_PATH" ] && [ -x "$LINK_PATH" ]; then
        log "DEBUG" "✅ Символическая ссылка: $LINK_PATH"
    else
        log "ERROR" "❌ Символическая ссылка недоступна: $LINK_PATH"
        errors=$((errors + 1))
    fi
    
    # Проверка библиотеки
    if source "$INSTALL_DIR/common/common_lib.sh" >/dev/null 2>&1; then
        log "DEBUG" "✅ Библиотека common_lib.sh работает"
    else
        log "ERROR" "❌ Библиотека common_lib.sh содержит ошибки"
        errors=$((errors + 1))
    fi
    
    if [ $errors -eq 0 ]; then
        log "SUCCESS" "Установка прошла успешно!"
        return 0
    else
        log "ERROR" "Обнаружено $errors ошибок при проверке установки"
        return 1
    fi
}

# Функция очистки временных файлов
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Функция отображения информации после установки
show_installation_info() {
    print_header "УСТАНОВКА ЗАВЕРШЕНА!" "$GREEN"
    
    safe_echo "${BOLD}${GREEN}✅ Matrix Setup & Management Tool v3.0 установлен!${NC}"
    echo
    
    safe_echo "${BOLD}📍 Расположение:${NC}"
    safe_echo "   Директория: $INSTALL_DIR"
    safe_echo "   Команда: $LINK_PATH"
    echo
    
    safe_echo "${BOLD}🚀 Запуск:${NC}"
    safe_echo "   ${CYAN}sudo manager-matrix${NC}     # Из любой директории"
    safe_echo "   ${CYAN}sudo $INSTALL_DIR/manager-matrix.sh${NC}     # Полный путь"
    echo
    
    safe_echo "${BOLD}📚 Документация:${NC}"
    safe_echo "   README: $INSTALL_DIR/README.md"
    safe_echo "   Логи: $INSTALL_DIR/logs/"
    echo
    
    safe_echo "${BOLD}🔧 Первые шаги:${NC}"
    safe_echo "   1. Убедитесь что у вас есть 3 настроенных домена"
    safe_echo "   2. Запустите: ${CYAN}sudo manager-matrix${NC}"
    safe_echo "   3. Выберите опцию 1 для установки Matrix Synapse"
    safe_echo "   4. Следуйте инструкциям мастера установки"
    echo
    
    safe_echo "${BOLD}🆘 Поддержка:${NC}"
    safe_echo "   GitHub: https://github.com/gopnikgame/matrix-setup"
    safe_echo "   Issues: https://github.com/gopnikgame/matrix-setup/issues"
    echo
    
    # Проверка системных требований
    local warnings=0
    
    # Проверка памяти
    local memory_gb=$(free -g | awk 'NR==2{print $2}')
    if [ "$memory_gb" -lt 1 ]; then
        safe_echo "${YELLOW}⚠️  Предупреждение: Недостаточно RAM ($memory_gb GB, рекомендуется 2GB+)${NC}"
        warnings=$((warnings + 1))
    fi
    
    # Проверка свободного места
    local disk_free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$disk_free_gb" -lt 10 ]; then
        safe_echo "${YELLOW}⚠️  Предупреждение: Мало свободного места ($disk_free_gb GB, рекомендуется 10GB+)${NC}"
        warnings=$((warnings + 1))
    fi
    
    if [ $warnings -gt 0 ]; then
        echo
        safe_echo "${YELLOW}💡 Рекомендуется устранить предупреждения перед установкой Matrix${NC}"
    fi
    
    echo
    safe_echo "${GREEN}Готово! Удачной установки! 🎉${NC}"
}

# Функция обработки ошибок
handle_error() {
    local exit_code=$?
    local line_number=$1
    
    simple_log "ERROR" "Ошибка в строке $line_number (код: $exit_code)"
    simple_log "INFO" "Очистка временных файлов..."
    cleanup
    exit $exit_code
}

# Главная функция
main() {
    # Обработчик ошибок
    trap 'handle_error $LINENO' ERR
    
    # Приветствие
    safe_echo ""
    safe_echo "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    safe_echo "${BOLD}${BLUE}║           Matrix Setup & Management Tool v3.0           ║${NC}"
    safe_echo "${BOLD}${BLUE}║                  Установщик системы                     ║${NC}"
    safe_echo "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    safe_echo ""
    
    simple_log "INFO" "Начало установки Matrix Setup Tool"
    
    # Этапы установки
    local steps=(
        "check_root_simple:Проверка прав root"
        "check_internet_simple:Проверка интернет подключения"
        "install_dependencies:Установка зависимостей"
        "clone_repository:Скачивание репозитория"
        "load_common_library:Загрузка библиотеки common_lib.sh"
        "setup_permissions:Настройка прав доступа"
        "create_symlink:Создание символической ссылки"
        "verify_installation:Проверка установки"
    )
    
    local total_steps=${#steps[@]}
    local current_step=0
    
    for step_info in "${steps[@]}"; do
        current_step=$((current_step + 1))
        local step_func="${step_info%%:*}"
        local step_name="${step_info##*:}"
        
        # Используем простое логирование до загрузки библиотеки
        if [ "$step_func" = "load_common_library" ]; then
            simple_log "INFO" "Этап $current_step/$total_steps: $step_name"
        else
            # После загрузки библиотеки используем её функции
            if declare -f log >/dev/null 2>&1; then
                log "INFO" "Этап $current_step/$total_steps: $step_name"
            else
                simple_log "INFO" "Этап $current_step/$total_steps: $step_name"
            fi
        fi
        
        if ! $step_func; then
            if declare -f log >/dev/null 2>&1; then
                log "ERROR" "Ошибка на этапе: $step_name"
            else
                simple_log "ERROR" "Ошибка на этапе: $step_name"
            fi
            cleanup
            exit 1
        fi
        
        if declare -f log >/dev/null 2>&1; then
            log "SUCCESS" "Этап завершён: $step_name"
        else
            simple_log "SUCCESS" "Этап завершён: $step_name"
        fi
    done
    
    # Очистка временных файлов
    cleanup
    
    # Отображение информации об установке
    show_installation_info
    
    return 0
}

# Проверка что скрипт вызван напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi