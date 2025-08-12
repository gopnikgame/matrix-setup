#!/bin/bash

# Matrix Setup & Management Tool v3.0
# Главный скрипт управления системой Matrix
# Использует модульную архитектуру с common_lib.sh

# Настройки проекта
LIB_NAME="Matrix Management Tool"
LIB_VERSION="3.0.0"
PROJECT_NAME="Matrix Setup"

# Подключение общей библиотеки
# Сначала определяем реальный путь к скрипту, учитывая символические ссылки
if [[ -L "${BASH_SOURCE[0]}" ]]; then
    # Если это символическая ссылка, получаем реальный путь
    REAL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    # Если это обычный файл
    REAL_SCRIPT_PATH="${BASH_SOURCE[0]}"
fi

SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/common/common_lib.sh"

if [ ! -f "$COMMON_LIB" ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Не найдена библиотека common_lib.sh"
    echo "Путь: $COMMON_LIB"
    echo ""
    echo "Проверьте структуру проекта:"
    echo "  matrix-setup/"
    echo "  ├── common/"
    echo "  │   └── common_lib.sh"
    echo "  ├── modules/"
    echo "  │   ├── core_install.sh"
    echo "  │   └── element_web.sh"
    echo "  └── manager-matrix.sh"
    echo ""
    echo "Отладочная информация:"
    echo "  BASH_SOURCE[0]: ${BASH_SOURCE[0]}"
    echo "  Символическая ссылка: $([[ -L "${BASH_SOURCE[0]}" ]] && echo "Да" || echo "Нет")"
    echo "  REAL_SCRIPT_PATH: $REAL_SCRIPT_PATH"
    echo "  SCRIPT_DIR: $SCRIPT_DIR"
    exit 1
fi

source "$COMMON_LIB"

# Конфигурационные переменные
CONFIG_DIR="/opt/matrix-install"
MODULES_DIR="$SCRIPT_DIR/modules"

# Функция проверки системных требований
check_system_requirements() {
    print_header "ПРОВЕРКА СИСТЕМЫ" "$BLUE"
    
    # Проверка операционной системы
    if [ ! -f /etc/os-release ]; then
        log "ERROR" "Неподдерживаемая операционная система"
        return 1
    fi
    
    source /etc/os-release
    log "INFO" "Операционная система: $PRETTY_NAME"
    
    # Проверка поддерживаемых дистрибутивов
    case "$ID" in
        ubuntu|debian)
            log "SUCCESS" "Поддерживаемый дистрибутив: $ID"
            ;;
        *)
            log "WARN" "Дистрибутив $ID может не поддерживаться полностью"
            if ! ask_confirmation "Продолжить на свой страх и риск?"; then
                return 1
            fi
            ;;
    esac
    
    # Проверка версии Ubuntu/Debian
    if [ "$ID" = "ubuntu" ]; then
        local version_id="${VERSION_ID%.*}"
        if [ "$version_id" -lt 20 ]; then
            log "WARN" "Рекомендуется Ubuntu 20.04 или новее (текущая: $VERSION_ID)"
        fi
    elif [ "$ID" = "debian" ]; then
        local version_id="${VERSION_ID%.*}"
        if [ "$version_id" -lt 11 ]; then
            log "WARN" "Рекомендуется Debian 11 или новее (текущая: $VERSION_ID)"
        fi
    fi
    
    # Проверка прав root
    check_root || return 1
    
    # Определение типа сервера на раннем этапе
    load_server_type || return 1
    
    log "INFO" "Тип сервера: $SERVER_TYPE"
    log "INFO" "Bind адрес: $BIND_ADDRESS"
    [[ -n "${PUBLIC_IP:-}" ]] && log "INFO" "Публичный IP: $PUBLIC_IP"
    [[ -n "${LOCAL_IP:-}" ]] && log "INFO" "Локальный IP: $LOCAL_IP"
    
    # Проверка подключения к интернету
    check_internet || return 1
    
    # Проверка системных ресурсов
    get_system_info
    
    log "SUCCESS" "Проверка системы завершена"
    return 0
}

# Функция загрузки модуля
load_module() {
    local module_name="$1"
    local module_path="$MODULES_DIR/${module_name}.sh"
    
    if [ ! -f "$module_path" ]; then
        log "ERROR" "Модуль $module_name не найден: $module_path"
        return 1
    fi
    
    if [ ! -x "$module_path" ]; then
        chmod +x "$module_path"
    fi
    
    log "DEBUG" "Загрузка модуля: $module_name"
    return 0
}

# Функция запуска модуля
run_module() {
    local module_name="$1"
    local module_path="$MODULES_DIR/${module_name}.sh"
    
    load_module "$module_name" || return 1
    
    print_header "ЗАПУСК МОДУЛЯ: ${module_name^^}" "$CYAN"
    log "INFO" "Выполнение модуля: $module_name"
    
    # Запуск модуля в подоболочке с передачей окружения
    (
        export SCRIPT_DIR CONFIG_DIR
        "$module_path"
    )
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log "SUCCESS" "Модуль $module_name завершён успешно"
    else
        log "ERROR" "Модуль $module_name завершён с ошибкой (код: $exit_code)"
    fi
    
    return $exit_code
}

# Функция установки базовой системы Matrix
install_matrix_core() {
    print_header "УСТАНОВКА MATRIX SYNAPSE" "$GREEN"
    
    log "INFO" "Начало установки базовой системы Matrix Synapse"
    
    # Проверка системных требований
    if ! check_system_requirements; then
        log "ERROR" "Системные требования не выполнены"
        return 1
    fi
    
    # Запуск модуля установки ядра
    if ! run_module "core_install"; then
        log "ERROR" "Ошибка установки Matrix Synapse"
        return 1
    fi
    
    log "SUCCESS" "Базовая система Matrix Synapse установлена"
    return 0
}

# Функция установки Element Web
install_element_web() {
    print_header "УСТАНОВКА ELEMENT WEB" "$BLUE"
    
    # Проверка, что Matrix Synapse установлен
    if [ ! -f "$CONFIG_DIR/domain" ]; then
        log "ERROR" "Matrix Synapse не установлен или не настроен"
        log "INFO" "Сначала выполните установку Matrix Synapse (опция 1)"
        return 1
    fi
    
    # Запуск модуля Element Web
    if ! run_module "element_web"; then
        log "ERROR" "Ошибка установки Element Web"
        return 1
    fi
    
    log "SUCCESS" "Element Web установлен"
    return 0
}

# Функция проверки статуса всех компонентов
check_matrix_status() {
    print_header "СТАТУС СИСТЕМЫ MATRIX" "$CYAN"
    
    # Показываем информацию о типе сервера
    safe_echo "${BOLD}${BLUE}Конфигурация сервера:${NC}"
    safe_echo "  ${BOLD}Тип сервера:${NC} ${SERVER_TYPE:-не определен}"
    safe_echo "  ${BOLD}Bind адрес:${NC} ${BIND_ADDRESS:-не определен}"
    [[ -n "${PUBLIC_IP:-}" ]] && safe_echo "  ${BOLD}Публичный IP:${NC} $PUBLIC_IP"
    [[ -n "${LOCAL_IP:-}" ]] && safe_echo "  ${BOLD}Локальный IP:${NC} $LOCAL_IP"
    echo
    
    # Проверка Matrix Synapse
    safe_echo "${BOLD}${BLUE}Matrix Synapse:${NC}"
    if systemctl is-active --quiet matrix-synapse 2>/dev/null; then
        safe_echo "  ${GREEN}✅ Служба запущена${NC}"
        
        # Проверка API в зависимости от типа сервера
        local api_urls=()
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                api_urls=("http://localhost:8008/_matrix/client/versions")
                [[ -n "${LOCAL_IP:-}" ]] && api_urls+=("http://${LOCAL_IP}:8008/_matrix/client/versions")
                ;;
            *)
                api_urls=("http://localhost:8008/_matrix/client/versions")
                ;;
        esac
        
        local api_accessible=false
        for api_url in "${api_urls[@]}"; do
            if curl -s -f --connect-timeout 3 "$api_url" >/dev/null 2>&1; then
                safe_echo "  ${GREEN}✅ API доступен (${api_url})${NC}"
                api_accessible=true
                break
            fi
        done
        
        if [ "$api_accessible" = false ]; then
            safe_echo "  ${RED}❌ API недоступен${NC}"
            safe_echo "  ${YELLOW}   Проверьте настройки bind_addresses в конфигурации Synapse${NC}"
        fi
        
        # Версия Synapse
        local synapse_version=$(dpkg -l | grep matrix-synapse-py3 | awk '{print $3}' | cut -d'-' -f1 2>/dev/null)
        if [ -n "$synapse_version" ]; then
            safe_echo "  ${BOLD}Версия:${NC} $synapse_version"
        fi
        
        # Проверка портов с учетом типа сервера
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                if ss -tlnp | grep -q ":8008.*0.0.0.0"; then
                    safe_echo "  ${GREEN}✅ Порт 8008 слушает на всех интерфейсах (подходит для NAT)${NC}"
                elif ss -tlnp | grep -q ":8008.*127.0.0.1"; then
                    safe_echo "  ${YELLOW}⚠️  Порт 8008 слушает только на localhost (может быть недоступен извне)${NC}"
                fi
                
                if ss -tlnp | grep -q ":8448.*0.0.0.0"; then
                    safe_echo "  ${GREEN}✅ Порт 8448 (федерация) слушает на всех интерфейсах${NC}"
                elif ss -tlnp | grep -q ":8448.*127.0.0.1"; then
                    safe_echo "  ${YELLOW}⚠️  Порт 8448 (федерация) слушает только на localhost${NC}"
                fi
                ;;
            *)
                if ss -tlnp | grep -q ":8008.*127.0.0.1"; then
                    safe_echo "  ${GREEN}✅ Порт 8008 настроен для облачного хостинга (localhost)${NC}"
                elif ss -tlnp | grep -q ":8008.*0.0.0.0"; then
                    safe_echo "  ${YELLOW}⚠️  Порт 8008 слушает на всех интерфейсах (может быть небезопасно)${NC}"
                fi
                ;;
        esac
        
    else
        safe_echo "  ${RED}❌ Служба не запущена${NC}"
    fi
    
    # Проверка домена
    if [ -f "$CONFIG_DIR/domain" ]; then
        local matrix_domain=$(cat "$CONFIG_DIR/domain")
        safe_echo "  ${BOLD}Домен:${NC} $matrix_domain"
        
        # Проверка соответствия домена типу сервера
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                if [[ "$matrix_domain" =~ \.(local|lan|home)$ ]]; then
                    safe_echo "  ${GREEN}✅ Домен подходит для локального сервера${NC}"
                else
                    safe_echo "  ${YELLOW}⚠️  Возможно, стоит использовать локальный домен (.local/.lan)${NC}"
                fi
                ;;
            *)
                if [[ "$matrix_domain" =~ \.(local|lan|home)$ ]]; then
                    safe_echo "  ${YELLOW}⚠️  Локальный домен на облачном сервере${NC}"
                else
                    safe_echo "  ${GREEN}✅ Публичный домен подходит для облачного сервера${NC}"
                fi
                ;;
        esac
    else
        safe_echo "  ${RED}❌ Домен не настроен${NC}"
    fi
    
    echo
    
    # Проверка PostgreSQL
    safe_echo "${BOLD}${BLUE}PostgreSQL:${NC}"
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        safe_echo "  ${GREEN}✅ Служба запущена${NC}"
        
        # Проверка базы данных Synapse
        if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw synapse_db 2>/dev/null; then
            safe_echo "  ${GREEN}✅ База данных synapse_db существует${NC}"
            
            # Размер базы данных
            local db_size=$(sudo -u postgres psql -c "SELECT pg_size_pretty(pg_database_size('synapse_db'));" -t 2>/dev/null | xargs)
            if [ -n "$db_size" ]; then
                safe_echo "  ${BOLD}Размер БД:${NC} $db_size"
            fi
        else
            safe_echo "  ${RED}❌ База данных synapse_db отсутствует${NC}"
        fi
        
    else
        safe_echo "  ${RED}❌ Служба не запущена${NC}"
    fi
    
    echo
    
    # Проверка Element Web
    safe_echo "${BOLD}${BLUE}Element Web:${NC}"
    if [ -d "/var/www/element" ] && [ -f "/var/www/element/index.html" ]; then
        safe_echo "  ${GREEN}✅ Установлен${NC}"
        
        if [ -f "/var/www/element/version" ]; then
            local element_version=$(cat "/var/www/element/version")
            safe_echo "  ${BOLD}Версия:${NC} $element_version"
        fi
        
        if [ -f "$CONFIG_DIR/element_domain" ]; then
            local element_domain=$(cat "$CONFIG_DIR/element_domain")
            safe_echo "  ${BOLD}Домен:${NC} $element_domain"
        fi
        
        # Проверка конфигурации Element в зависимости от типа сервера
        if [ -f "/var/www/element/config.json" ]; then
            if jq empty "/var/www/element/config.json" 2>/dev/null; then
                local mobile_guide=$(jq -r '.mobile_guide_toast' "/var/www/element/config.json" 2>/dev/null)
                local integrations=$(jq -r '.integrations_ui_url' "/var/www/element/config.json" 2>/dev/null)
                
                case "$SERVER_TYPE" in
                    "proxmox"|"home_server"|"docker"|"openvz")
                        if [ "$mobile_guide" = "false" ]; then
                            safe_echo "  ${GREEN}✅ Настроен для локального сервера (mobile_guide отключен)${NC}"
                        else
                            safe_echo "  ${YELLOW}⚠️  Mobile guide включен (рекомендуется отключить для локального сервера)${NC}"
                        fi
                        ;;
                    *)
                        if [ "$mobile_guide" = "true" ]; then
                            safe_echo "  ${GREEN}✅ Настроен для облачного сервера (mobile_guide включен)${NC}"
                        else
                            safe_echo "  ${YELLOW}⚠️  Mobile guide отключен (рекомендуется включить для облачного сервера)${NC}"
                        fi
                        ;;
                esac
                
                if [ "$integrations" != "null" ] && [ -n "$integrations" ]; then
                    safe_echo "  ${BLUE}ⓘ Интеграции включены${NC}"
                else
                    safe_echo "  ${BLUE}ⓘ Интеграции отключены${NC}"
                fi
            else
                safe_echo "  ${RED}❌ Ошибка в конфигурации (config.json)${NC}"
            fi
        fi
        
    else
        safe_echo "  ${RED}❌ Не установлен${NC}"
    fi
    
    echo
    
    # Проверка веб-серверов
    safe_echo "${BOLD}${BLUE}Веб-серверы:${NC}"
    local web_servers=("nginx" "apache2" "caddy")
    local active_servers=0
    
    for server in "${web_servers[@]}"; do
        if systemctl is-active --quiet "$server" 2>/dev/null; then
            safe_echo "  ${GREEN}✅ $server: активен${NC}"
            active_servers=$((active_servers + 1))
            
            # Дополнительная информация для Caddy
            if [ "$server" = "caddy" ] && [ -f "/etc/caddy/Caddyfile" ]; then
                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    safe_echo "    ${GREEN}✅ Конфигурация Caddy корректна${NC}"
                else
                    safe_echo "    ${RED}❌ Ошибка в конфигурации Caddy${NC}"
                fi
            fi
            
        elif command -v "$server" >/dev/null 2>&1; then
            safe_echo "  ${YELLOW}⚠️  $server: установлен, но не активен${NC}"
        fi
    done
    
    if [ $active_servers -eq 0 ]; then
        safe_echo "  ${RED}❌ Нет активных веб-серверов${NC}"
    elif [ $active_servers -gt 1 ]; then
        safe_echo "  ${YELLOW}⚠️  Запущено несколько веб-серверов (возможны конфликты портов)${NC}"
    fi
    
    echo
    
    # Проверка портов с учетом типа сервера
    safe_echo "${BOLD}${BLUE}Сетевые порты:${NC}"
    local ports=("8008:Matrix HTTP" "8448:Matrix Federation" "80:HTTP" "443:HTTPS" "5432:PostgreSQL")
    
    for port_info in "${ports[@]}"; do
        local port="${port_info%%:*}"
        local description="${port_info##*:}"
        
        if ss -tlnp | grep -q ":$port "; then
            safe_echo "  ${GREEN}✅ Порт $port ($description): используется${NC}"
            
            # Показываем, на каких интерфейсах слушает порт
            local listen_info=$(ss -tlnp | grep ":$port " | awk '{print $4}' | sort -u | tr '\n' ' ')
            safe_echo "    ${DIM}Слушает на: $listen_info${NC}"
        else
            safe_echo "  ${YELLOW}⚠️  Порт $port ($description): свободен${NC}"
        fi
    done
    
    echo
    
    # Проверка Coturn TURN сервера
    safe_echo "${BOLD}${BLUE}Coturn TURN Server:${NC}"
    if systemctl is-active --quiet coturn 2>/dev/null; then
        safe_echo "  ${GREEN}✅ Служба запущена${NC}"
        
        # Проверка портов TURN
        local turn_ports=("3478" "5349")
        for port in "${turn_ports[@]}"; do
            if ss -tlnp | grep -q ":$port "; then
                safe_echo "  ${GREEN}✅ Порт $port (TURN): прослушивается${NC}"
            else
                safe_echo "  ${YELLOW}⚠️  Порт $port (TURN): не прослушивается${NC}"
            fi
        done
        
        # Проверка UDP relay диапазона
        if ss -ulnp | grep -q ":4915[2-9]" || ss -ulnp | grep -q ":50000"; then
            safe_echo "  ${GREEN}✅ UDP relay диапазон: активен${NC}"
        else
            safe_echo "  ${YELLOW}⚠️  UDP relay диапазон: проверьте настройки${NC}"
        fi
        
        # Информация о домене TURN
        if [[ -f "$CONFIG_DIR/turn_domain" ]]; then
            local turn_domain=$(cat "$CONFIG_DIR/turn_domain")
            safe_echo "  ${BOLD}Домен TURN:${NC} $turn_domain"
        fi
        
        # Проверка интеграции с Synapse
        if [[ -f "/etc/matrix-synapse/conf.d/turn.yaml" ]]; then
            safe_echo "  ${GREEN}✅ Интеграция с Synapse: настроена${NC}"
        elif grep -q "turn_uris" /etc/matrix-synapse/homeserver.yaml 2>/dev/null; then
            safe_echo "  ${GREEN}✅ Интеграция с Synapse: настроена (homeserver.yaml)${NC}"
        else
            safe_echo "  ${YELLOW}⚠️  Интеграция с Synapse: не настроена${NC}"
        fi
        
        # Показываем важность TURN для типа сервера
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                safe_echo "  ${BLUE}ℹ️  TURN критически важен для NAT-серверов${NC}"
                ;;
            *)
                safe_echo "  ${BLUE}ℹ️  TURN улучшает надежность VoIP звонков${NC}"
                ;;
        esac
        
    else
        safe_echo "  ${RED}❌ Служба не запущена${NC}"
        
        # Проверяем, установлен ли coturn
        if command -v turnserver >/dev/null 2>&1; then
            safe_echo "  ${YELLOW}⚠️  Coturn установлен, но не запущен${NC}"
        else
            safe_echo "  ${YELLOW}⚠️  Coturn не установлен${NC}"
            
            # Рекомендации по установке для разных типов серверов
            case "$SERVER_TYPE" in
                "proxmox"|"home_server"|"docker"|"openvz")
                    safe_echo "  ${BLUE}💡 Рекомендуется установить TURN для надежных звонков"
                    ;;
                *)
                    safe_echo "  ${BLUE}💡 TURN сервер рекомендуется для корпоративных сетей${NC}"
                    ;;
            esac
        fi
    fi
    
    echo
    
    # Проверка веб-серверов
    safe_echo "${BOLD}${BLUE}Веб-серверы:${NC}"
    local web_servers=("nginx" "apache2" "caddy")
    local active_servers=0
    
    for server in "${web_servers[@]}"; do
        if systemctl is-active --quiet "$server" 2>/dev/null; then
            safe_echo "  ${GREEN}✅ $server: активен${NC}"
            active_servers=$((active_servers + 1))
            
            # Дополнительная информация для Caddy
            if [ "$server" = "caddy" ] && [ -f "/etc/caddy/Caddyfile" ]; then
                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    safe_echo "    ${GREEN}✅ Конфигурация Caddy корректна${NC}"
                else
                    safe_echo "    ${RED}❌ Ошибка в конфигурации Caddy${NC}"
                fi
            fi
            
        elif command -v "$server" >/dev/null 2>&1; then
            safe_echo "  ${YELLOW}⚠️  $server: установлен, но не активен${NC}"
        fi
    done
    
    if [ $active_servers -eq 0 ]; then
        safe_echo "  ${RED}❌ Нет активных веб-серверов${NC}"
    elif [ $active_servers -gt 1 ]; then
        safe_echo "  ${YELLOW}⚠️  Запущено несколько веб-серверов (возможны конфликты портов)${NC}"
    fi
    
    echo
    
    # Проверка портов с учетом типа сервера
    safe_echo "${BOLD}${BLUE}Сетевые порты:${NC}"
    local ports=("8008:Matrix HTTP" "8448:Matrix Federation" "80:HTTP" "443:HTTPS" "5432:PostgreSQL")
    
    for port_info in "${ports[@]}"; do
        local port="${port_info%%:*}"
        local description="${port_info##*:}"
        
        if ss -tlnp | grep -q ":$port "; then
            safe_echo "  ${GREEN}✅ Порт $port ($description): используется${NC}"
            
            # Показываем, на каких интерфейсах слушает порт
            local listen_info=$(ss -tlnp | grep ":$port " | awk '{print $4}' | sort -u | tr '\n' ' ')
            safe_echo "    ${DIM}Слушает на: $listen_info${NC}"
        else
            safe_echo "  ${YELLOW}⚠️  Порт $port ($description): свободен${NC}"
        fi
    done
    
    echo
    
    # Общий статус с рекомендациями для типа сервера
    safe_echo "${BOLD}${BLUE}Общий статус:${NC}"
    if systemctl is-active --quiet matrix-synapse && systemctl is-active --quiet postgresql; then
        safe_echo "  ${GREEN}✅ Основные компоненты работают${NC}"
        
        # Проверка API доступности
        local api_check_url="http://localhost:8008/_matrix/client/versions"
        if curl -s -f --connect-timeout 3 "$api_check_url" >/dev/null 2>&1; then
            safe_echo "  ${GREEN}✅ Matrix API доступен локально${NC}"
        else
            safe_echo "  ${YELLOW}⚠️  Matrix API недоступен локально${NC}"
        fi
        
        # Проверка VoIP готовности
        if systemctl is-active --quiet coturn 2>/dev/null; then
            safe_echo "  ${GREEN}✅ VoIP готов (TURN сервер активен)${NC}"
        else
            safe_echo "  ${YELLOW}⚠️  VoIP может не работать за NAT (TURN не активен)${NC}"
        fi
        
        # Рекомендации для типа сервера
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                safe_echo "  ${BLUE}ℹ️  Рекомендации для $SERVER_TYPE:${NC}"
                safe_echo "    • Настройте reverse proxy на хосте с публичным IP"
                safe_echo "    • Перенаправьте порты 80, 443, 8448 на этот сервер"
                safe_echo "    • Используйте Caddy для автоматического SSL"
                if ! systemctl is-active --quiet coturn 2>/dev/null; then
                    safe_echo "    • Установите TURN сервер для надежных звонков"
                fi
                if [ -n "${LOCAL_IP:-}" ]; then
                    safe_echo "    • Локальный доступ: http://${LOCAL_IP}:8008"
                fi
                ;;
            "hosting"|"vps")
                safe_echo "  ${BLUE}ℹ️  Рекомендации для $SERVER_TYPE:${NC}"
                safe_echo "    • Настройте веб-сервер (nginx/caddy) для HTTPS"
                safe_echo "    • Получите SSL сертификат от Let's Encrypt"
                safe_echo "    • Настройте файрвол (разрешите порты 80, 443, 8448)"
                if ! systemctl is-active --quiet coturn 2>/dev/null; then
                    safe_echo "    • Рассмотрите установку TURN сервера для корпоративных пользователей"
                fi
                ;;
        esac
        
    else
        safe_echo "  ${RED}❌ Есть проблемы с основными компонентами${NC}"
        
        # Диагностика проблем
        if ! systemctl is-active --quiet matrix-synapse; then
            safe_echo "    ${RED}• Matrix Synapse не запущен${NC}"
            safe_echo "    ${YELLOW}  Попробуйте: systemctl start matrix-synapse${NC}"
        fi
        
        if ! systemctl is-active --quiet postgresql; then
            safe_echo "    ${RED}• PostgreSQL не запущен${NC}"
            safe_echo "    ${YELLOW}  Попробуйте: systemctl start postgresql${NC}"
        fi
    fi
    
    return 0
}

# Функция управления службами
manage_services() {
    while true; do
        print_header "УПРАВЛЕНИЕ СЛУЖБАМИ" "$YELLOW"
        
        safe_echo "${BOLD}Доступные действия:${NC}"
        safe_echo "${GREEN}1.${NC} Запустить все службы"
        safe_echo "${GREEN}2.${NC} Остановить все службы"
        safe_echo "${GREEN}3.${NC} Перезапустить все службы"
        safe_echo "${GREEN}4.${NC} Управление Matrix Synapse"
        safe_echo "${GREEN}5.${NC} Управление PostgreSQL"
        safe_echo "${GREEN}6.${NC} Управление веб-сервером"
        safe_echo "${GREEN}7.${NC} Показать логи"
        safe_echo "${GREEN}8.${NC} Назад в главное меню"
        
        echo
        read -p "$(safe_echo "${YELLOW}Выберите действие (1-8): ${NC}")" choice
        
        case $choice in
            1)
                log "INFO" "Запуск всех служб Matrix..."
                systemctl start postgresql matrix-synapse
                
                # Запуск веб-сервера если он установлен
                for server in nginx apache2 caddy; do
                    if systemctl is-enabled --quiet "$server" 2>/dev/null; then
                        systemctl start "$server"
                        break
                    fi
                done
                
                log "SUCCESS" "Команды запуска отправлены"
                ;;
            2)
                log "INFO" "Остановка всех служб Matrix..."
                systemctl stop matrix-synapse
                
                # Остановка веб-серверов
                for server in nginx apache2 caddy; do
                    if systemctl is-active --quiet "$server" 2>/dev/null; then
                        systemctl stop "$server"
                    fi
                done
                
                log "SUCCESS" "Службы остановлены"
                ;;
            3)
                log "INFO" "Перезапуск всех служб Matrix..."
                restart_service postgresql
                restart_service matrix-synapse
                
                # Перезапуск веб-сервера
                for server in nginx apache2 caddy; do
                    if systemctl is-enabled --quiet "$server" 2>/dev/null; then
                        restart_service "$server"
                        break
                    fi
                done
                
                log "SUCCESS" "Службы перезапущены"
                ;;
            4)
                manage_synapse_service
                ;;
            5)
                manage_postgresql_service
                ;;
            6)
                manage_web_server
                ;;
            7)
                show_service_logs
                ;;
            8)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                sleep 1
                ;;
        esac
        
        if [ $choice -ne 8 ]; then
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Функция управления Synapse
manage_synapse_service() {
    print_header "УПРАВЛЕНИЕ MATRIX SYNAPSE" "$BLUE"
    
    safe_echo "${BOLD}Текущий статус:${NC}"
    systemctl status matrix-synapse --no-pager -l || true
    
    echo
    safe_echo "${BOLD}Доступные действия:${NC}"
    safe_echo "${GREEN}1.${NC} Запустить"
    safe_echo "${GREEN}2.${NC} Остановить"
    safe_echo "${GREEN}3.${NC} Перезагрузить"
    safe_echo "${GREEN}4.${NC} Показать логи"
    safe_echo "${GREEN}5.${NC} Проверить конфигурацию"
    safe_echo "${GREEN}6.${NC} Назад"
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите действие (1-6): ${NC}")" choice
    
    case $choice in
        1) systemctl start matrix-synapse && log "SUCCESS" "Synapse запущен" ;;
        2) systemctl stop matrix-synapse && log "SUCCESS" "Synapse остановлен" ;;
        3) restart_service matrix-synapse ;;
        4) 
            log "INFO" "Логи Matrix Synapse (Ctrl+C для выхода):"
            journalctl -u matrix-synapse -f
            ;;
        5)
            log "INFO" "Проверка конфигурации Synapse..."
            if python3 -m synapse.config -c /etc/matrix-synapse/homeserver.yaml >/dev/null 2>&1; then
                log "SUCCESS" "Конфигурация корректна"
            else
                log "ERROR" "Ошибки в конфигурации"
                python3 -m synapse.config -c /etc/matrix-synapse/homeserver.yaml
            fi
            ;;
        6) return 0 ;;
        *) log "ERROR" "Неверный выбор" ;;
    esac
}

# Функция управления PostgreSQL
manage_postgresql_service() {
    print_header "УПРАВЛЕНИЕ POSTGRESQL" "$BLUE"
    
    safe_echo "${BOLD}Текущий статус:${NC}"
    systemctl status postgresql --no-pager -l || true
    
    echo
    safe_echo "${BOLD}Доступные действия:${NC}"
    safe_echo "${GREEN}1.${NC} Запустить"
    safe_echo "${GREEN}2.${NC} Остановить"
    safe_echo "${GREEN}3.${NC} Перезапустить"
    safe_echo "${GREEN}4.${NC} Показать логи"
    safe_echo "${GREEN}5.${NC} Подключиться к базе данных"
    safe_echo "${GREEN}6.${NC} Назад"
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите действие (1-6): ${NC}")" choice
    
    case $choice in
        1) systemctl start postgresql && log "SUCCESS" "PostgreSQL запущен" ;;
        2) systemctl stop postgresql && log "SUCCESS" "PostgreSQL остановлен" ;;
        3) restart_service postgresql ;;
        4) 
            log "INFO" "Логи PostgreSQL (Ctrl+C для выхода):"
            journalctl -u postgresql -f
            ;;
        5)
            log "INFO" "Подключение к базе данных synapse_db..."
            sudo -u postgres psql synapse_db
            ;;
        6) return 0 ;;
        *) log "ERROR" "Неверный выбор" ;;
    esac
}

# Функция управления веб-сервером
manage_web_server() {
    print_header "УПРАВЛЕНИЕ ВЕБ-СЕРВЕРОМ" "$BLUE"
    
    # Определение активного веб-сервера
    local active_server=""
    for server in nginx apache2 caddy; do
        if systemctl is-active --quiet "$server" 2>/dev/null; then
            active_server="$server"
            break
        fi
    done
    
    if [ -z "$active_server" ]; then
        log "WARN" "Активный веб-сервер не найден"
        return 1
    fi
    
    safe_echo "${BOLD}Активный веб-сервер: $active_server${NC}"
    systemctl status "$active_server" --no-pager -l || true
    
    echo
    safe_echo "${BOLD}Доступные действия:${NC}"
    safe_echo "${GREEN}1.${NC} Запустить"
    safe_echo "${GREEN}2.${NC} Остановить"
    safe_echo "${GREEN}3.${NC} Перезапустить"
    safe_echo "${GREEN}4.${NC} Перезагрузить конфигурацию"
    safe_echo "${GREEN}5.${NC} Показать логи"
    safe_echo "${GREEN}6.${NC} Проверить конфигурацию"
    safe_echo "${GREEN}7.${NC} Назад"
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите действие (1-7): ${NC}")" choice
    
    case $choice in
        1) systemctl start "$active_server" && log "SUCCESS" "$active_server запущен" ;;
        2) systemctl stop "$active_server" && log "SUCCESS" "$active_server остановлен" ;;
        3) restart_service "$active_server" ;;
        4) systemctl reload "$active_server" && log "SUCCESS" "Конфигурация $active_server перезагружена" ;;
        5) 
            log "INFO" "Логи $active_server (Ctrl+C для выхода):"
            journalctl -u "$active_server" -f
            ;;
        6)
            log "INFO" "Проверка конфигурации $active_server..."
            case "$active_server" in
                nginx) nginx -t ;;
                apache2) apache2ctl configtest ;;
                caddy) caddy validate --config /etc/caddy/Caddyfile ;;
            esac
            ;;
        7) return 0 ;;
        *) log "ERROR" "Неверный выбор" ;;
    esac
}

# Функция показа логов служб
show_service_logs() {
    print_header "ЛОГИ СЛУЖБ" "$CYAN"
    
    safe_echo "${BOLD}Выберите службу для просмотра логов:${NC}"
    safe_echo "${GREEN}1.${NC} Matrix Synapse"
    safe_echo "${GREEN}2.${NC} PostgreSQL"
    safe_echo "${GREEN}3.${NC} Nginx"
    safe_echo "${GREEN}4.${NC} Apache"
    safe_echo "${GREEN}5.${NC} Caddy"
    safe_echo "${GREEN}6.${NC} Все службы Matrix"
    safe_echo "${GREEN}7.${NC} Назад"
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите службу (1-7): ${NC}")" choice
    
    case $choice in
        1) journalctl -u matrix-synapse -f ;;
        2) journalctl -u postgresql -f ;;
        3) journalctl -u nginx -f ;;
        4) journalctl -u apache2 -f ;;
        5) journalctl -u caddy -f ;;
        6) journalctl -u matrix-synapse -u postgresql -u nginx -u apache2 -u caddy -f ;;
        7) return 0 ;;
        *) log "ERROR" "Неверный выбор" ;;
    esac
}

# Функция создания резервной копии
create_backup() {
    print_header "СОЗДАНИЕ РЕЗЕРВНОЙ КОПИИ" "$YELLOW"
    
    local backup_dir="/opt/matrix-backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    log "INFO" "Создание резервной копии Matrix в $backup_dir..."
    
    # Остановка Synapse для консистентной копии
    if systemctl is-active --quiet matrix-synapse; then
        log "INFO" "Остановка Matrix Synapse для создания резервной копии..."
        systemctl stop matrix-synapse
        local synapse_was_running=true
    fi
    
    # Резервная копия конфигурации Synapse
    if [ -d "/etc/matrix-synapse" ]; then
        log "INFO" "Резервная копия конфигурации Synapse..."
        cp -r /etc/matrix-synapse "$backup_dir/synapse-config"
    fi
    
    # Резервная копия данных Synapse
    if [ -d "/var/lib/matrix-synapse" ]; then
        log "INFO" "Резервная копия данных Synapse..."
        cp -r /var/lib/matrix-synapse "$backup_dir/synapse-data"
    fi
    
    # Резервная копия конфигурации установщика
    if [ -d "$CONFIG_DIR" ]; then
        log "INFO" "Резервная копия конфигурации установщика..."
        cp -r "$CONFIG_DIR" "$backup_dir/matrix-install-config"
    fi
    
    # Резервная копия базы данных PostgreSQL
    log "INFO" "Резервная копия базы данных PostgreSQL..."
    if sudo -u postgres pg_dump synapse_db > "$backup_dir/synapse_db_dump.sql" 2>/dev/null; then
        log "SUCCESS" "База данных сохранена в synapse_db_dump.sql"
    else
        log "WARN" "Не удалось создать резервную копию базы данных"
    fi
    
    # Резервная копия Element Web
    if [ -d "/var/www/element" ]; then
        log "INFO" "Резервная копия Element Web..."
        cp -r /var/www/element "$backup_dir/element-web"
    fi
    
    # Запуск Synapse обратно
    if [ "$synapse_was_running" = true ]; then
        log "INFO" "Запуск Matrix Synapse..."
        systemctl start matrix-synapse
    fi
    
    # Создание архива
    log "INFO" "Создание архива резервной копии..."
    local archive_path="/opt/matrix-backup/matrix-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
    
    if tar -czf "$archive_path" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"; then
        log "SUCCESS" "Архив создан: $archive_path"
        
        # Удаление временной директории
        rm -rf "$backup_dir"
        
        # Показ размера архива
        local archive_size=$(du -h "$archive_path" | cut -f1)
        log "INFO" "Размер архива: $archive_size"
        
    else
        log "ERROR" "Ошибка создания архива"
        return 1
    fi
    
    log "SUCCESS" "Резервная копия создана успешно"
    return 0
}

# Функция показа информации о конфигурации
show_configuration_info() {
    print_header "ИНФОРМАЦИЯ О КОНФИГУРАЦИИ" "$CYAN"
    
    # Домены
    safe_echo "${BOLD}${BLUE}Домены:${NC}"
    if [ -f "$CONFIG_DIR/domain" ]; then
        local matrix_domain=$(cat "$CONFIG_DIR/domain")
        safe_echo "  ${BOLD}Matrix сервер:${NC} $matrix_domain"
    else
        safe_echo "  ${RED}Matrix домен не настроен${NC}"
    fi
    
    if [ -f "$CONFIG_DIR/element_domain" ]; then
        local element_domain=$(cat "$CONFIG_DIR/element_domain")
        safe_echo "  ${BOLD}Element Web:${NC} $element_domain"
    else
        safe_echo "  ${YELLOW}Element домен не настроен${NC}"
    fi
    
    echo
    
    # Конфигурационные файлы
    safe_echo "${BOLD}${BLUE}Конфигурационные файлы:${NC}"
    
    local config_files=(
        "/etc/matrix-synapse/homeserver.yaml:Основная конфигурация Synapse"
        "/etc/matrix-synapse/conf.d/database.yaml:Конфигурация базы данных"
        "/etc/matrix-synapse/conf.d/registration.yaml:Настройки регистрации"
        "/var/www/element/config.json:Конфигурация Element Web"
        "$CONFIG_DIR/database.conf:Параметры базы данных"
        "$CONFIG_DIR/secrets.conf:Секретные ключи"
    )
    
    for config_info in "${config_files[@]}"; do
        local file_path="${config_info%%:*}"
        local description="${config_info##*:}"
        
        if [ -f "$file_path" ]; then
            safe_echo "  ${GREEN}✅ $description${NC}"
            safe_echo "     ${DIM}$file_path${NC}"
        else
            safe_echo "  ${RED}❌ $description${NC}"
            safe_echo "     ${DIM}$file_path (отсутствует)${NC}"
        fi
    done
    
    echo
    
    # Пути данных
    safe_echo "${BOLD}${BLUE}Пути данных:${NC}"
    
    local data_paths=(
        "/var/lib/matrix-synapse:Данные Synapse"
        "/var/lib/matrix-synapse/media_store:Медиа-файлы"
        "/var/www/element:Element Web"
        "$CONFIG_DIR:Конфигурация установщика"
    )
    
    for path_info in "${data_paths[@]}"; do
        local dir_path="${path_info%%:*}"
        local description="${path_info##*:}"
        
        if [ -d "$dir_path" ]; then
            local dir_size=$(du -sh "$dir_path" 2>/dev/null | cut -f1)
            safe_echo "  ${GREEN}✅ $description${NC}"
            safe_echo "     ${DIM}$dir_path ($dir_size)${NC}"
        else
            safe_echo "  ${RED}❌ $description${NC}"
            safe_echo "     ${DIM}$dir_path (отсутствует)${NC}"
        fi
    done
    
    return 0
}

# Главное меню
main_menu() {
    while true; do
        print_header "MATRIX SETUP & MANAGEMENT TOOL v3.0" "$GREEN"
        
        safe_echo "${BOLD}Основные компоненты:${NC}"
        echo
        safe_echo "${GREEN}1.${NC}  🚀 Установить Matrix Synapse (базовая система)"
        safe_echo "${GREEN}2.${NC}  🌐 Установить Element Web (веб-клиент)"
        
        echo
        safe_echo "${BOLD}Управление системой:${NC}"
        echo
        safe_echo "${GREEN}3.${NC}  📊 Проверить статус системы"
        safe_echo "${GREEN}4.${NC}  ⚙️  Управление службами"
        safe_echo "${GREEN}5.${NC}  🔧 Дополнительные компоненты"
        
        echo
        safe_echo "${BOLD}Инструменты:${NC}"
        echo
        safe_echo "${GREEN}6.${NC}  📋 Показать конфигурацию"
        safe_echo "${GREEN}7.${NC}  💾 Создать резервную копию"
        safe_echo "${GREEN}8.${NC}  🔄 Обновить модули и библиотеку"
        safe_echo "${GREEN}9.${NC}  🔍 Диагностика и устранение проблем"
        safe_echo "${GREEN}10.${NC} 📖 Показать системную информацию"
        
        echo
        safe_echo "${GREEN}11.${NC} ❌ Выход"
        
        echo
        
        # Показываем краткую информацию о статусе
        if systemctl is-active --quiet matrix-synapse 2>/dev/null; then
            safe_echo "${GREEN}💚 Matrix Synapse: активен${NC}"
        else
            safe_echo "${RED}💔 Matrix Synapse: неактивен${NC}"
        fi
        
        if systemctl is-active --quiet coturn 2>/dev/null; then
            safe_echo "${GREEN}📞 TURN Server: активен${NC}"
        elif [ "$SERVER_TYPE" = "proxmox" ] || [ "$SERVER_TYPE" = "home_server" ]; then
            safe_echo "${YELLOW}📞 TURN Server: рекомендуется для NAT${NC}"
        fi
        
        echo
        read -p "$(safe_echo "${YELLOW}Выберите действие (1-11): ${NC}")" choice
        
        case $choice in
            1)
                install_matrix_core
                ;;
            2)
                install_element_web
                ;;
            3)
                check_matrix_status
                ;;
            4)
                manage_services
                ;;
            5)
                manage_additional_components
                ;;
            6)
                show_configuration_info
                ;;
            7)
                create_backup
                ;;
            8)
                update_modules_and_library
                ;;
            9)
                log "INFO" "Запуск диагностики..."
                get_system_info
                check_matrix_status
                ;;
            10)
                get_system_info
                ;;
            11)
                print_header "ЗАВЕРШЕНИЕ РАБОТЫ" "$GREEN"
                log "INFO" "Спасибо за использование Matrix Setup Tool!"
                safe_echo "${GREEN}До свидания! 👋${NC}"
                exit 0
                ;;
            *)
                log "ERROR" "Неверный выбор: $choice"
                sleep 1
                ;;
        esac
        
        if [ $choice -ne 11 ]; then
            echo
            read -p "Нажмите Enter для возврата в главное меню..."
        fi
    done
}

# Функция инициализации
initialize() {
    # Создание необходимых директорий
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    
    # Проверка наличия модулей
    local required_modules=("core_install" "element_web" "coturn_setup" "caddy_config" "synapse_admin" "federation_control" "registration_control" "ufw_config")
    local missing_modules=()
    
    for module in "${required_modules[@]}"; do
        if [ ! -f "$MODULES_DIR/${module}.sh" ]; then
            missing_modules+=("$module")
        fi
    done
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        log "ERROR" "Отсутствуют модули: ${missing_modules[*]}"
        log "ERROR" "Проверьте структуру проекта"
        return 1
    fi
    
    # Установка прав выполнения на модули
    chmod +x "$MODULES_DIR"/*.sh 2>/dev/null || true
    
    log "SUCCESS" "Инициализация завершена"
    return 0
}

# Функция управления дополнительными компонентами
manage_additional_components() {
    while true; do
        print_header "ДОПОЛНИТЕЛЬНЫЕ КОМПОНЕНТЫ" "$YELLOW"
        
        safe_echo "${BOLD}Доступные компоненты:${NC}"
        safe_echo "${GREEN}1.${NC} 📞 Coturn TURN Server (для VoIP)"
        safe_echo "${GREEN}2.${NC} 👥 Synapse Admin (веб-интерфейс)"
        safe_echo "${GREEN}3.${NC} 🔐 Управление регистрацией"
        safe_echo "${GREEN}4.${NC} 🌍 Управление федерацией"
        safe_echo "${GREEN}5.${NC} 🔒 Настройка файрвола (UFW)"
        safe_echo "${GREEN}6.${NC} 🔧 Настройка Reverse Proxy (Caddy)"
        safe_echo "${GREEN}7.${NC} Назад в главное меню"
        
        echo
        read -p "$(safe_echo "${YELLOW}Выберите действие (1-7): ${NC}")" choice
        
        case $choice in
            1) run_module "coturn_setup" ;;
            2) run_module "synapse_admin" ;;
            3) run_module "registration_control" ;;
            4) run_module "federation_control" ;;
            5) run_module "ufw_config" ;;
            6) run_module "caddy_config" ;;
            7) return 0 ;;
            *)
                log "ERROR" "Неверный выбор"
                sleep 1
                ;;
        esac
        
        if [ $choice -ne 7 ]; then
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Функция обновления модулей и библиотеки
update_modules_and_library() {
    print_header "ОБНОВЛЕНИЕ МОДУЛЕЙ И БИБЛИОТЕКИ" "$YELLOW"
    
    if ! check_internet; then
        log "ERROR" "Нет подключения к интернету. Обновление невозможно."
        return 1
    fi
    
    log "INFO" "Проверка обновлений для модулей и библиотеки..."
    
    local repo_raw_url="https://raw.githubusercontent.com/gopnikgame/matrix-setup/main"
    local updated_files=0
    local checked_files=0
    
    # Список файлов для проверки
    local files_to_check=()
    files_to_check+=("common/common_lib.sh")
    for module_path in "$MODULES_DIR"/*.sh; do
        if [ -f "$module_path" ]; then
            files_to_check+=("modules/$(basename "$module_path")")
        fi
    done
    
    # Проверка зависимостей
    if ! command -v sha256sum >/dev/null 2>&1; then
        log "ERROR" "Команда 'sha256sum' не найдена. Установите coreutils (sudo apt install coreutils)."
        return 1
    fi
    
    for file_rel_path in "${files_to_check[@]}"; do
        local local_file_path="${SCRIPT_DIR}/${file_rel_path}"
        local remote_file_url="${repo_raw_url}/${file_rel_path}"
        local temp_file=$(mktemp)
        
        ((checked_files++))
        
        log "DEBUG" "Проверка файла: $file_rel_path"
        
        # Скачиваем удаленный файл
        if ! curl -sL --fail "$remote_file_url" -o "$temp_file"; then
            log "WARN" "Не удалось скачать удаленный файл: $remote_file_url"
            rm -f "$temp_file"
            continue
        fi
        
        # Сравниваем хеши
        local local_hash=$(sha256sum "$local_file_path" | awk '{print $1}')
        local remote_hash=$(sha256sum "$temp_file" | awk '{print $1}')
        
        if [ "$local_hash" != "$remote_hash" ]; then
            log "INFO" "Обнаружено обновление для: $file_rel_path"
            if mv "$temp_file" "$local_file_path"; then
                chmod +x "$local_file_path"
                log "SUCCESS" "Файл $file_rel_path обновлен."
                ((updated_files++))
            else
                log "ERROR" "Ошибка при обновлении файла: $local_file_path"
                rm -f "$temp_file"
            fi
        else
            rm -f "$temp_file"
        fi
    done
    
    if [ $updated_files -gt 0 ]; then
        log "SUCCESS" "Обновление завершено. Обновлено файлов: $updated_files из $checked_files."
    else
        log "INFO" "Все модули и библиотека уже в актуальном состоянии."
    fi
    
    return 0
}

# Главная функция
main() {
    # Инициализация
    if ! initialize; then
        log "ERROR" "Ошибка инициализации"
        exit 1
    fi
    
    # Приветствие
    print_header "ДОБРО ПОЖАЛОВАТЬ В MATRIX SETUP TOOL!" "$GREEN"
    
    log "INFO" "Запуск $LIB_NAME v$LIB_VERSION"
    log "INFO" "Проект: $PROJECT_NAME"
    
    # Проверка обновлений при запуске
    if ask_confirmation "Проверить наличие обновлений для модулей и библиотеки?"; then
        update_modules_and_library
        read -p "Нажмите Enter для продолжения..."
    fi
    
    # Запуск главного меню
    main_menu
}

# Обработка сигналов
trap 'log "INFO" "Получен сигнал завершения, выходим..."; exit 0' SIGINT SIGTERM

# Запуск если скрипт вызван напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi