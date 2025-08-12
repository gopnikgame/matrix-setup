#!/bin/bash

# UFW Firewall Configuration Module for Matrix Setup
# Версия: 3.0.0 - с интеграцией системы определения типа сервера

# Настройки модуля
LIB_NAME="UFW Firewall Manager"
LIB_VERSION="3.0.0"
MODULE_NAME="ufw_config"

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../common/common_lib.sh"

if [ ! -f "$COMMON_LIB" ]; then
    echo "ОШИБКА: Не найдена библиотека common_lib.sh по пути: $COMMON_LIB"
    exit 1
fi

source "$COMMON_LIB"

# Конфигурационные переменные
CONFIG_DIR="/opt/matrix-install"

# Функция проверки UFW
check_ufw_installation() {
    log "INFO" "Проверка установки UFW..."
    
    if ! command -v ufw >/dev/null 2>&1; then
        log "INFO" "UFW не установлен, выполняется установка..."
        if ! apt update && apt install -y ufw; then
            log "ERROR" "Ошибка установки UFW"
            return 1
        fi
        log "SUCCESS" "UFW установлен"
    else
        log "INFO" "UFW уже установлен"
    fi
    
    return 0
}

# Функция получения доменной конфигурации
get_domain_config() {
    local domain_file="$CONFIG_DIR/domain"
    
    if [[ -f "$domain_file" ]]; then
        MATRIX_DOMAIN=$(cat "$domain_file")
        log "INFO" "Домен Matrix: $MATRIX_DOMAIN"
    else
        log "ERROR" "Домен Matrix не настроен. Сначала выполните установку Matrix Synapse."
        return 1
    fi
    
    export MATRIX_DOMAIN
    return 0
}

# Функция базовой настройки файрвола
configure_basic_firewall() {
    print_header "БАЗОВАЯ НАСТРОЙКА ФАЙРВОЛА" "$BLUE"
    
    log "INFO" "Настройка базового файрвола (HTTP/HTTPS только)..."
    
    # Сброс правил (с подтверждением)
    if ! ask_confirmation "Сбросить все текущие правила UFW?"; then
        log "INFO" "Настройка отменена"
        return 0
    fi
    
    # Сброс и базовые правила
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH доступ
    log "INFO" "Добавление правила для SSH..."
    ufw allow ssh
    
    # HTTP/HTTPS
    log "INFO" "Добавление правил для HTTP/HTTPS..."
    ufw allow http
    ufw allow https
    
    # Адаптация под тип сервера
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            log "INFO" "Настройка для локального сервера ($SERVER_TYPE)..."
            
            # Разрешаем доступ из локальной сети
            if [[ -n "${LOCAL_IP:-}" ]]; then
                local network_prefix=$(echo "$LOCAL_IP" | sed 's/\.[0-9]*$/\.0\/24/')
                log "INFO" "Разрешение доступа из локальной сети: $network_prefix"
                ufw allow from "$network_prefix"
            fi
            
            # Дополнительные порты для локального доступа
            ufw allow 8008/tcp comment "Matrix Synapse local"
            ufw allow 8448/tcp comment "Matrix Federation local"
            ;;
        *)
            log "INFO" "Настройка для облачного сервера ($SERVER_TYPE)..."
            # Для облачных серверов только стандартные порты
            ;;
    esac
    
    # Включение файрвола
    ufw --force enable
    
    log "SUCCESS" "Базовый файрвол настроен"
    show_ufw_status
    return 0
}

# Функция полной настройки файрвола для Matrix
configure_full_matrix_firewall() {
    print_header "ПОЛНАЯ НАСТРОЙКА ФАЙРВОЛА MATRIX" "$GREEN"
    
    log "INFO" "Настройка полного файрвола Matrix с поддержкой федерации..."
    
    # Сброс правил (с подтверждением)
    if ! ask_confirmation "Сбросить все текущие правила UFW и настроить полный набор для Matrix?"; then
        log "INFO" "Настройка отменена"
        return 0
    fi
    
    # Сброс и базовые правила
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH доступ
    log "INFO" "Добавление правила для SSH..."
    ufw allow ssh
    
    # Веб-серверы
    log "INFO" "Добавление правил для веб-серверов..."
    ufw allow http comment "Web server HTTP"
    ufw allow https comment "Web server HTTPS"
    
    # Matrix Synapse
    log "INFO" "Добавление правил для Matrix Synapse..."
    ufw allow 8448/tcp comment "Matrix Federation"
    
    # Настройки в зависимости от типа сервера
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            log "INFO" "Дополнительные правила для локального сервера ($SERVER_TYPE)..."
            
            # Локальная сеть
            if [[ -n "${LOCAL_IP:-}" ]]; then
                local network_prefix=$(echo "$LOCAL_IP" | sed 's/\.[0-9]*$/\.0\/24/')
                log "INFO" "Разрешение доступа из локальной сети: $network_prefix"
                ufw allow from "$network_prefix" comment "Local network access"
            fi
            
            # Matrix HTTP API для локального доступа
            ufw allow 8008/tcp comment "Matrix HTTP API (local)"
            
            # TURN сервер (если планируется)
            ufw allow 3478/tcp comment "TURN TCP"
            ufw allow 3478/udp comment "TURN UDP"
            ufw allow 5349/tcp comment "TURN TLS"
            ufw allow 5349/udp comment "TURN DTLS"
            ufw allow 49152:65535/udp comment "TURN UDP range"
            
            # Дополнительные сервисы для домашней лаборатории
            ufw allow 5432/tcp comment "PostgreSQL (local)"
            ;;
        "hosting"|"vps")
            log "INFO" "Настройки для облачного сервера ($SERVER_TYPE)..."
            
            # Только внешние порты, внутренние закрыты
            # Matrix HTTP API не открываем (доступ через reverse proxy)
            
            # TURN сервер (опционально)
            if ask_confirmation "Настроить порты для TURN сервера (голосовые/видео звонки)?"; then
                ufw allow 3478/tcp comment "TURN TCP"
                ufw allow 3478/udp comment "TURN UDP" 
                ufw allow 5349/tcp comment "TURN TLS"
                ufw allow 5349/udp comment "TURN DTLS"
                ufw allow 49152:65535/udp comment "TURN UDP range"
                log "INFO" "Порты TURN сервера открыты"
            fi
            ;;
    esac
    
    # Дополнительные сервисы
    if ask_confirmation "Открыть порты для мониторинга (Prometheus/Grafana)?"; then
        ufw allow 9090/tcp comment "Prometheus"
        ufw allow 3000/tcp comment "Grafana"
        log "INFO" "Порты мониторинга открыты"
    fi
    
    # Включение файрвола
    ufw --force enable
    
    log "SUCCESS" "Полный файрвол Matrix настроен"
    show_ufw_status
    return 0
}

# Функция настройки файрвола для reverse proxy
configure_reverse_proxy_firewall() {
    print_header "НАСТРОЙКА ФАЙРВОЛА ДЛЯ REVERSE PROXY" "$CYAN"
    
    log "INFO" "Настройка файрвола для сервера reverse proxy..."
    
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            log "ERROR" "Эта функция предназначена для хост-серверов с публичным IP"
            log "INFO" "Для серверов за NAT используйте стандартную настройку"
            return 1
            ;;
    esac
    
    if ! ask_confirmation "Настроить файрвол для reverse proxy (откроет только внешние порты)?"; then
        log "INFO" "Настройка отменена"
        return 0
    fi
    
    # Сброс и базовые правила
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH доступ
    log "INFO" "Добавление правила для SSH..."
    ufw allow ssh
    
    # Только внешние порты для reverse proxy
    log "INFO" "Добавление правил для reverse proxy..."
    ufw allow http comment "Reverse proxy HTTP"
    ufw allow https comment "Reverse proxy HTTPS"
    ufw allow 8448/tcp comment "Matrix Federation proxy"
    
    # Включение файрвола
    ufw --force enable
    
    log "SUCCESS" "Файрвол для reverse proxy настроен"
    log "INFO" "Настройте проксирование трафика на внутренние серверы"
    show_ufw_status
    return 0
}

# Функция открытия дополнительного порта
open_additional_port() {
    print_header "ОТКРЫТИЕ ДОПОЛНИТЕЛЬНОГО ПОРТА" "$YELLOW"
    
    while true; do
        read -p "$(safe_echo "${YELLOW}Введите номер порта (например, 8008): ${NC}")" port_num
        
        if [[ ! "$port_num" =~ ^[0-9]+$ ]] || [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
            log "ERROR" "Неверный номер порта"
            continue
        fi
        break
    done
    
    local protocols=("tcp" "udp" "both")
    show_menu "Выберите протокол" "${protocols[@]}"
    local protocol_choice=$?
    
    local protocol=""
    case $protocol_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="" ;;  # оба протокола
        *) log "ERROR" "Неверный выбор"; return 1 ;;
    esac
    
    read -p "$(safe_echo "${YELLOW}Введите комментарий (опционально): ${NC}")" comment
    
    # Открытие порта
    log "INFO" "Открытие порта $port_num..."
    
    if [ -z "$protocol" ]; then
        # Оба протокола
        if [ -n "$comment" ]; then
            ufw allow "$port_num/tcp" comment "$comment (TCP)"
            ufw allow "$port_num/udp" comment "$comment (UDP)"
        else
            ufw allow "$port_num/tcp"
            ufw allow "$port_num/udp"
        fi
        log "SUCCESS" "Порт $port_num открыт для TCP и UDP"
    else
        if [ -n "$comment" ]; then
            ufw allow "$port_num/$protocol" comment "$comment"
        else
            ufw allow "$port_num/$protocol"
        fi
        log "SUCCESS" "Порт $port_num/$protocol открыт"
    fi
    
    show_ufw_status
    return 0
}

# Функция закрытия порта
close_port() {
    print_header "ЗАКРЫТИЕ ПОРТА" "$RED"
    
    # Показываем текущие правила
    log "INFO" "Текущие правила UFW:"
    ufw status numbered
    
    echo
    read -p "$(safe_echo "${YELLOW}Введите номер правила для удаления: ${NC}")" rule_num
    
    if [[ ! "$rule_num" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Неверный номер правила"
        return 1
    fi
    
    if ask_confirmation "Удалить правило #$rule_num?"; then
        if ufw --force delete "$rule_num"; then
            log "SUCCESS" "Правило #$rule_num удалено"
        else
            log "ERROR" "Ошибка удаления правила"
            return 1
        fi
    else
        log "INFO" "Удаление отменено"
    fi
    
    show_ufw_status
    return 0
}

# Функция показа статуса UFW
show_ufw_status() {
    print_header "СТАТУС ФАЙРВОЛА UFW" "$CYAN"
    
    # Общий статус
    local status=$(ufw status | head -1)
    if [[ "$status" =~ "Status: active" ]]; then
        safe_echo "${GREEN}✅ UFW активен${NC}"
    elif [[ "$status" =~ "Status: inactive" ]]; then
        safe_echo "${RED}❌ UFW неактивен${NC}"
    else
        safe_echo "${YELLOW}⚠️  Статус UFW неизвестен${NC}"
    fi
    
    echo
    safe_echo "${BOLD}${BLUE}Информация о сервере:${NC}"
    safe_echo "  ${BOLD}Тип сервера:${NC} ${SERVER_TYPE:-не определен}"
    safe_echo "  ${BOLD}Bind адрес:${NC} ${BIND_ADDRESS:-не определен}"
    [[ -n "${PUBLIC_IP:-}" ]] && safe_echo "  ${BOLD}Публичный IP:${NC} $PUBLIC_IP"
    [[ -n "${LOCAL_IP:-}" ]] && safe_echo "  ${BOLD}Локальный IP:${NC} $LOCAL_IP"
    
    echo
    safe_echo "${BOLD}${BLUE}Активные правила:${NC}"
    
    # Проверяем наличие правил
    local rules_count=$(ufw status numbered | grep -c "^\[")
    
    if [ "$rules_count" -eq 0 ]; then
        safe_echo "${YELLOW}  Нет активных правил${NC}"
    else
        # Показываем правила с нумерацией
        ufw status numbered | grep "^\[" | while read -r line; do
            safe_echo "  $line"
        done
    fi
    
    echo
    safe_echo "${BOLD}${BLUE}Политики по умолчанию:${NC}"
    ufw status verbose | grep "Default:" | while read -r line; do
        safe_echo "  $line"
    done
    
    echo
    safe_echo "${BOLD}${BLUE}Рекомендации для $SERVER_TYPE:${NC}"
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            safe_echo "  • Разрешите доступ из локальной сети"
            safe_echo "  • Откройте порт 8008 для локального доступа к Matrix"
            safe_echo "  • Откройте порт 8448 для федерации (если нужна)"
            if [[ -n "${LOCAL_IP:-}" ]]; then
                local network=$(echo "$LOCAL_IP" | sed 's/\.[0-9]*$/\.0\/24/')
                safe_echo "  • Команда для локальной сети: ufw allow from $network"
            fi
            ;;
        "hosting"|"vps")
            safe_echo "  • Откройте только необходимые внешние порты (80, 443, 8448)"
            safe_echo "  • НЕ открывайте порт 8008 напрямую (используйте reverse proxy)"
            safe_echo "  • Настройте TURN сервер для голосовых звонков (порты 3478, 5349)"
            safe_echo "  • Рассмотрите использование fail2ban для защиты от атак"
            ;;
    esac
    
    return 0
}

# Функция включения/выключения UFW
toggle_ufw() {
    local current_status=$(ufw status | head -1)
    
    if [[ "$current_status" =~ "Status: active" ]]; then
        if ask_confirmation "UFW активен. Отключить файрвол?"; then
            ufw --force disable
            log "SUCCESS" "UFW отключен"
        fi
    else
        if ask_confirmation "UFW неактивен. Включить файрвол?"; then
            ufw --force enable
            log "SUCCESS" "UFW включен"
        fi
    fi
    
    show_ufw_status
}

# Функция экспорта/импорта конфигурации
export_ufw_config() {
    print_header "ЭКСПОРТ КОНФИГУРАЦИИ UFW" "$BLUE"
    
    local export_file="$CONFIG_DIR/ufw-backup-$(date +%Y%m%d_%H%M%S).txt"
    
    log "INFO" "Экспорт конфигурации UFW в $export_file..."
    
    {
        echo "# UFW Configuration Backup"
        echo "# Generated: $(date)"
        echo "# Server Type: $SERVER_TYPE"
        echo ""
        echo "# Status"
        ufw status verbose
        echo ""
        echo "# Rules (numbered)"
        ufw status numbered
    } > "$export_file"
    
    if [ -f "$export_file" ]; then
        log "SUCCESS" "Конфигурация UFW экспортирована в $export_file"
    else
        log "ERROR" "Ошибка экспорта конфигурации"
        return 1
    fi
    
    return 0
}

# Функция диагностики UFW
diagnose_ufw() {
    print_header "ДИАГНОСТИКА UFW" "$CYAN"
    
    log "INFO" "Запуск диагностики UFW..."
    
    # Проверка установки
    echo "1. Установка UFW:"
    if command -v ufw >/dev/null 2>&1; then
        safe_echo "${GREEN}   ✓ UFW установлен${NC}"
        local ufw_version=$(ufw --version | head -1)
        safe_echo "${BLUE}   ✓ $ufw_version${NC}"
    else
        safe_echo "${RED}   ✗ UFW не установлен${NC}"
        return 1
    fi
    
    # Статус UFW
    echo "2. Статус UFW:"
    local status=$(ufw status | head -1)
    if [[ "$status" =~ "Status: active" ]]; then
        safe_echo "${GREEN}   ✓ UFW активен${NC}"
    else
        safe_echo "${RED}   ✗ UFW неактивен${NC}"
    fi
    
    # Проверка основных портов
    echo "3. Проверка портов Matrix:"
    local matrix_ports=("22:SSH" "80:HTTP" "443:HTTPS" "8008:Matrix API" "8448:Federation")
    
    for port_info in "${matrix_ports[@]}"; do
        local port="${port_info%%:*}"
        local description="${port_info##*:}"
        
        if ufw status | grep -q ":$port "; then
            safe_echo "${GREEN}   ✓ Порт $port ($description): разрешен${NC}"
        else
            safe_echo "${YELLOW}   ! Порт $port ($description): не настроен${NC}"
        fi
    done
    
    # Проверка сетевой связности
    echo "4. Проверка сетевых подключений:"
    local test_ports=(80 443 22)
    
    for port in "${test_ports[@]}"; do
        if ss -tlnp | grep -q ":$port "; then
            safe_echo "${GREEN}   ✓ Порт $port прослушивается${NC}"
        else
            safe_echo "${YELLOW}   ! Порт $port не прослушивается${NC}"
        fi
    done
    
    # Проверка логов
    echo "5. Последние записи в логах UFW:"
    if [ -f "/var/log/ufw.log" ]; then
        tail -n 5 /var/log/ufw.log 2>/dev/null || safe_echo "${YELLOW}   Лог UFW пуст${NC}"
    else
        safe_echo "${YELLOW}   Лог файл UFW не найден${NC}"
    fi
    
    return 0
}

# Главное меню модуля UFW
ufw_menu() {
    while true; do
        show_menu "УПРАВЛЕНИЕ ФАЙРВОЛОМ UFW" \
            "Базовая настройка (HTTP/HTTPS)" \
            "Полная настройка Matrix" \
            "Настройка для reverse proxy" \
            "Открыть дополнительный порт" \
            "Закрыть порт" \
            "Показать статус" \
            "Включить/отключить UFW" \
            "Экспорт конфигурации" \
            "Диагностика" \
            "Назад в главное меню"
        
        local choice=$?
        
        case $choice in
            1) configure_basic_firewall ;;
            2) configure_full_matrix_firewall ;;
            3) configure_reverse_proxy_firewall ;;
            4) open_additional_port ;;
            5) close_port ;;
            6) show_ufw_status ;;
            7) toggle_ufw ;;
            8) export_ufw_config ;;
            9) diagnose_ufw ;;
            10) break ;;
            *) log "ERROR" "Неверный выбор" ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Основная функция модуля
main() {
    print_header "НАСТРОЙКА ФАЙРВОЛА UFW" "$BLUE"
    
    # Проверка прав root
    check_root || return 1
    
    # Загрузка типа сервера
    load_server_type || return 1
    
    # Получение конфигурации домена
    get_domain_config || return 1
    
    # Проверка и установка UFW
    check_ufw_installation || return 1
    
    log "INFO" "Модуль UFW готов к работе"
    log "INFO" "Тип сервера: $SERVER_TYPE"
    
    # Запуск меню
    ufw_menu
    
    return 0
}

# Экспорт функций
export -f main ufw_menu show_ufw_status diagnose_ufw

# Запуск если вызван напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi