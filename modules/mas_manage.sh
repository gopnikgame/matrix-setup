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

# Главное меню управления MAS
show_mas_management_menu() {
    print_header "УПРАВЛЕНИЕ MATRIX AUTHENTICATION SERVICE (MAS)" "$BLUE"
    
    # Показываем статус MAS
    if systemctl is-active --quiet matrix-auth-service; then
        safe_echo "Статус MAS: ${GREEN}ЗАПУЩЕН${NC}"
    else
        safe_echo "Статус MAS: ${RED}ОСТАНОВЛЕН${NC}"
    fi
    
    # Определяем порт из конфигурации
    local mas_port=""
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
    else
        mas_port=$(determine_mas_port)
    fi
    
    # Проверяем, доступен ли порт
    if [ -n "$mas_port" ] && ss -tlnp | grep -q ":$mas_port "; then
        safe_echo "Порт MAS: ${GREEN}$mas_port${NC} (активен)"
    else
        safe_echo "Порт MAS: ${YELLOW}$mas_port${NC} (не активен)"
    fi
    
    # Показываем статус регистрации
    if [ -x "$(command -v yq)" ] && [ -f "$MAS_CONFIG_FILE" ]; then
        local reg_status=$(get_mas_registration_status)
        local token_status=$(get_mas_token_registration_status)
        
        if [ "$reg_status" = "enabled" ]; then
            safe_echo "Открытая регистрация: ${GREEN}ВКЛЮЧЕНА${NC}"
        elif [ "$reg_status" = "disabled" ]; then
            safe_echo "Открытая регистрация: ${RED}ОТКЛЮЧЕНА${NC}"
        else
            safe_echo "Открытая регистрация: ${YELLOW}НЕИЗВЕСТНО${NC}"
        fi
        
        if [ "$token_status" = "enabled" ]; then
            safe_echo "Регистрация по токенам: ${GREEN}ТРЕБУЕТСЯ${NC}"
        elif [ "$token_status" = "disabled" ]; then
            safe_echo "Регистрация по токенам: ${RED}НЕ ТРЕБУЕТСЯ${NC}"
        else
            safe_echo "Регистрация по токенам: ${YELLOW}НЕИЗВЕСТНО${NC}"
        fi
    fi
    
    echo
    safe_echo "${BOLD}Доступные действия:${NC}"
    safe_echo "1. ${CYAN}📊 Проверить статус MAS${NC}"
    safe_echo "2. ${GREEN}▶️  Запустить MAS${NC}"
    safe_echo "3. ${RED}⏹️  Остановить MAS${NC}"
    safe_echo "4. ${BLUE}🔄 Перезапустить MAS${NC}"
    safe_echo "5. ${YELLOW}🛠️  Диагностика и восстановление MAS${NC}"
    safe_echo "6. ${MAGENTA}👥 Управление регистрацией пользователей${NC}"
    safe_echo "7. ${BLUE}👤 Управление SSO провайдерами${NC}"
    safe_echo "8. ${CYAN}🤖 Управление CAPTCHA${NC}"
    safe_echo "9. ${RED}🚫 Управление заблокированными именами пользователей${NC}"
    safe_echo "10. ${RED}❌ Удалить MAS${NC}"
    safe_echo "0. ${WHITE}↩️  Назад${NC}"
}

# Главная функция модуля
main() {
    while true; do
        clear
        show_mas_management_menu
        
        read -p "Выберите действие [0-10]: " choice
        
        case $choice in
            1)
                # Проверка статуса MAS
                check_mas_status
                read -p "Нажмите Enter для продолжения..."
                ;;
            2)
                # Запуск MAS
                print_header "ЗАПУСК MATRIX AUTHENTICATION SERVICE" "$GREEN"
                if systemctl is-active --quiet matrix-auth-service; then
                    log "INFO" "MAS уже запущен"
                else
                    if systemctl start matrix-auth-service; then
                        log "SUCCESS" "MAS успешно запущен"
                    else
                        log "ERROR" "Не удалось запустить MAS"
                    fi
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            3)
                # Остановка MAS
                print_header "ОСТАНОВКА MATRIX AUTHENTICATION SERVICE" "$RED"
                if ! systemctl is-active --quiet matrix-auth-service; then
                    log "INFO" "MAS уже остановлен"
                else
                    if systemctl stop matrix-auth-service; then
                        log "SUCCESS" "MAS успешно остановлен"
                    else
                        log "ERROR" "Не удалось остановить MAS"
                    fi
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            4)
                # Перезапуск MAS
                print_header "ПЕРЕЗАПУСК MATRIX AUTHENTICATION SERVICE" "$BLUE"
                if systemctl restart matrix-auth-service; then
                    log "SUCCESS" "MAS успешно перезапущен"
                else
                    log "ERROR" "Не удалось перезапустить MAS"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            5)
                # Диагностика и восстановление MAS
                diagnose_and_repair_mas
                ;;
            6)
                # Управление регистрацией пользователей
                manage_mas_registration
                ;;
            7)
                # Управление SSO провайдерами
                manage_mas_sso
                ;;
            8)
                # Управление CAPTCHA
                manage_mas_captcha
                ;;
            9)
                # Управление заблокированными именами пользователей
                manage_mas_ban_usernames
                ;;
            10)
                # Удаление MAS
                remove_mas
                ;;
            0)
                # Выход
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод: $choice"
                sleep 1
                ;;
        esac
    done
}

# Запускаем основную функцию, если скрипт выполняется напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
