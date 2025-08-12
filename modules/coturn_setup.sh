#!/bin/bash

# Coturn TURN Server Setup Module for Matrix
# Устанавливает и настраивает coturn для надежных VoIP вызовов
# Версия: 1.0.0

# Настройки модуля
LIB_NAME="Coturn TURN Server Setup"
LIB_VERSION="1.0.0"
MODULE_NAME="coturn_setup"

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
COTURN_CONFIG_FILE="/etc/turnserver.conf"
COTURN_BACKUP_DIR="$CONFIG_DIR/coturn_backups"

# Функция проверки системных требований для coturn
check_coturn_requirements() {
    print_header "ПРОВЕРКА ТРЕБОВАНИЙ ДЛЯ COTURN" "$BLUE"
    
    log "INFO" "Проверка системных требований для coturn..."
    
    # Проверка прав root
    check_root || return 1
    
    # Проверка архитектуры
    local arch=$(uname -m)
    if [[ ! "$arch" =~ ^(x86_64|amd64|arm64|aarch64)$ ]]; then
        log "ERROR" "Неподдерживаемая архитектура: $arch"
        return 1
    fi
    log "INFO" "Архитектура: $arch - поддерживается"
    
    # Проверка доступной памяти (минимум 512MB для coturn)
    local memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local memory_mb=$((memory_kb / 1024))
    
    if [ "$memory_mb" -lt 512 ]; then
        log "WARN" "Недостаточно оперативной памяти: ${memory_mb}MB (рекомендуется минимум 512MB)"
        if ! ask_confirmation "Продолжить установку с недостаточным объемом памяти?"; then
            return 1
        fi
    else
        log "INFO" "Оперативная память: ${memory_mb}MB - достаточно"
    fi
    
    # Проверка подключения к интернету
    check_internet || return 1
    
    # Определение типа сервера для дальнейшей настройки
    load_server_type || return 1
    log "INFO" "Тип сервера: $SERVER_TYPE"
    
    log "SUCCESS" "Системные требования для coturn проверены"
    return 0
}

# Функция получения доменного имени для TURN
get_turn_domain() {
    local domain_file="$CONFIG_DIR/domain"
    local turn_domain_file="$CONFIG_DIR/turn_domain"
    
    # Читаем основной домен Matrix
    if [[ -f "$domain_file" ]]; then
        MATRIX_DOMAIN=$(cat "$domain_file")
        log "INFO" "Основной домен Matrix: $MATRIX_DOMAIN"
    else
        log "ERROR" "Не найден файл с доменом Matrix сервера"
        return 1
    fi
    
    # Проверяем сохранённый домен TURN
    if [[ -f "$turn_domain_file" ]]; then
        TURN_DOMAIN=$(cat "$turn_domain_file")
        log "INFO" "Найден сохранённый домен TURN: $TURN_DOMAIN"
        
        if ask_confirmation "Использовать сохранённый домен TURN $TURN_DOMAIN?"; then
            return 0
        fi
    fi
    
    print_header "НАСТРОЙКА ДОМЕНА TURN СЕРВЕРА" "$CYAN"
    
    # Предлагаем варианты доменов в зависимости от типа сервера
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            local suggested_domain="turn.${MATRIX_DOMAIN#*.}"
            safe_echo "${BLUE}Для локального сервера рекомендуется домен: ${CYAN}$suggested_domain${NC}"
            safe_echo "${YELLOW}Или используйте IP адрес сервера для простоты${NC}"
            ;;
        *)
            local suggested_domain="turn.$MATRIX_DOMAIN"
            safe_echo "${BLUE}Для облачного сервера рекомендуется домен: ${CYAN}$suggested_domain${NC}"
            ;;
    esac
    
    while true; do
        echo
        safe_echo "${YELLOW}Варианты домена TURN сервера:${NC}"
        safe_echo "${GREEN}1.${NC} Использовать поддомен (рекомендуется): turn.$MATRIX_DOMAIN"
        safe_echo "${GREEN}2.${NC} Использовать основной домен: $MATRIX_DOMAIN"
        safe_echo "${GREEN}3.${NC} Использовать IP адрес: ${PUBLIC_IP:-$LOCAL_IP}"
        safe_echo "${GREEN}4.${NC} Ввести собственный домен"
        
        echo
        read -p "$(safe_echo "${YELLOW}Выберите вариант (1-4): ${NC}")" domain_choice
        
        case $domain_choice in
            1)
                TURN_DOMAIN="turn.$MATRIX_DOMAIN"
                break
                ;;
            2)
                TURN_DOMAIN="$MATRIX_DOMAIN"
                break
                ;;
            3)
                TURN_DOMAIN="${PUBLIC_IP:-$LOCAL_IP}"
                break
                ;;
            4)
                read -p "$(safe_echo "${YELLOW}Введите домен TURN сервера: ${NC}")" custom_domain
                if [[ -n "$custom_domain" ]]; then
                    TURN_DOMAIN="$custom_domain"
                    break
                fi
                ;;
            *)
                log "ERROR" "Неверный выбор, попробуйте снова"
                ;;
        esac
    done
    
    log "INFO" "Домен TURN сервера: $TURN_DOMAIN"
    
    # Сохраняем домен
    mkdir -p "$CONFIG_DIR"
    echo "$TURN_DOMAIN" > "$turn_domain_file"
    log "SUCCESS" "Домен TURN сервера сохранён в $turn_domain_file"
    
    export TURN_DOMAIN
    return 0
}

# Функция установки coturn
install_coturn() {
    print_header "УСТАНОВКА COTURN" "$BLUE"
    
    log "INFO" "Установка coturn TURN сервера..."
    
    # Проверка, не установлен ли уже coturn
    if systemctl is-active --quiet coturn 2>/dev/null; then
        log "INFO" "Coturn уже установлен и запущен"
        local coturn_version=$(coturn --help 2>&1 | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "неизвестна")
        log "INFO" "Версия coturn: $coturn_version"
        
        if ask_confirmation "Пересоздать конфигурацию coturn?"; then
            return 0
        else
            return 0
        fi
    fi
    
    # Установка coturn
    log "INFO" "Установка пакета coturn..."
    if ! apt update; then
        log "ERROR" "Ошибка обновления списка пакетов"
        return 1
    fi
    
    if ! apt install -y coturn; then
        log "ERROR" "Ошибка установки coturn"
        return 1
    fi
    
    # Проверка установки
    if ! command -v turnserver >/dev/null 2>&1; then
        log "ERROR" "Coturn не установился корректно"
        return 1
    fi
    
    local coturn_version=$(turnserver --help 2>&1 | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "неизвестна")
    log "SUCCESS" "Coturn установлен, версия: $coturn_version"
    
    return 0
}

# Функция генерации конфигурации coturn
create_coturn_config() {
    print_header "СОЗДАНИЕ КОНФИГУРАЦИИ COTURN" "$CYAN"
    
    log "INFO" "Создание конфигурации coturn..."
    
    # Резервная копия существующей конфигурации
    if [[ -f "$COTURN_CONFIG_FILE" ]]; then
        backup_file "$COTURN_CONFIG_FILE" "coturn-config"
    fi
    
    # Генерация секретного ключа
    local turn_secret
    if [[ -f "$CONFIG_DIR/coturn_secret" ]]; then
        turn_secret=$(cat "$CONFIG_DIR/coturn_secret")
        log "INFO" "Использование существующего секрета TURN"
    else
        turn_secret=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
        echo "$turn_secret" > "$CONFIG_DIR/coturn_secret"
        chmod 600 "$CONFIG_DIR/coturn_secret"
        log "INFO" "Сгенерирован новый секрет TURN"
    fi
    
    # Определение настроек в зависимости от типа сервера
    local listening_ip="0.0.0.0"
    local external_ip=""
    local relay_ips=""
    
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            # Для локальных серверов настраиваем NAT
            if [[ -n "${PUBLIC_IP:-}" ]] && [[ "$PUBLIC_IP" != "$LOCAL_IP" ]]; then
                external_ip="external-ip=$PUBLIC_IP"
                log "INFO" "Настройка для NAT: внутренний IP $LOCAL_IP, внешний IP $PUBLIC_IP"
            else
                log "INFO" "Настройка для локальной сети без NAT"
            fi
            
            # Разрешаем локальные IP для тестирования
            if [[ -n "${LOCAL_IP:-}" ]]; then
                relay_ips="allowed-peer-ip=$LOCAL_IP"
            fi
            ;;
        *)
            # Для облачных серверов используем публичный IP
            if [[ -n "${PUBLIC_IP:-}" ]]; then
                external_ip="external-ip=$PUBLIC_IP"
            fi
            log "INFO" "Настройка для облачного сервера"
            ;;
    esac
    
    # Создание конфигурации coturn
    log "INFO" "Создание файла конфигурации $COTURN_CONFIG_FILE..."
    cat > "$COTURN_CONFIG_FILE" <<EOF
# Coturn TURN Server Configuration
# Generated by Matrix Setup Tool
# Server Type: $SERVER_TYPE
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Основные настройки
listening-port=3478
tls-listening-port=5349

# Адреса для прослушивания
listening-ip=$listening_ip
$external_ip

# Realm (домен) - используется клиентами для аутентификации
realm=$TURN_DOMAIN

# Секретный ключ для аутентификации
use-auth-secret
static-auth-secret=$turn_secret

# Логирование
syslog

# Настройки безопасности
# Запрещаем TCP relay для VoIP (только UDP)
no-tcp-relay

# Блокируем приватные IP адреса (безопасность)
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=172.16.0.0-172.31.255.255

# Дополнительные блокировки для безопасности
no-multicast-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.0.2.0-192.0.2.255
denied-peer-ip=192.88.99.0-192.88.99.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=198.51.100.0-198.51.100.255
denied-peer-ip=203.0.113.0-203.0.113.255
denied-peer-ip=240.0.0.0-255.255.255.255

# Разрешения для локального тестирования (если необходимо)
$relay_ips

# Ограничения для предотвращения DoS атак
user-quota=12
total-quota=1200

# Настройки производительности
max-bps=3000000

# Отключение TLS по умолчанию (можно включить позже)
no-tls
no-dtls

# Добавляем поддержку диапазона портов для relay
min-port=49152
max-port=65535

# Fingerprint для проверки подлинности
fingerprint

# Мобильная оптимизация
mobility

# Настройки для различных типов серверов
$(case "$SERVER_TYPE" in
    "proxmox"|"home_server"|"docker"|"openvz")
        cat <<'EOF_LOCAL'
# Настройки для локального/домашнего сервера
# Более мягкие ограничения для локальной сети
user-quota=20
total-quota=2000

# Разрешаем локальные сети (раскомментировать при необходимости)
# allowed-peer-ip=192.168.0.0-192.168.255.255
# allowed-peer-ip=10.0.0.0-10.255.255.255
# allowed-peer-ip=172.16.0.0-172.31.255.255
EOF_LOCAL
        ;;
    *)
        cat <<'EOF_CLOUD'
# Настройки для облачного сервера
# Более строгие ограничения
user-quota=8
total-quota=800

# Дополнительные меры безопасности
simple-log
EOF_CLOUD
        ;;
esac)
EOF

    # Установка прав доступа
    chown root:root "$COTURN_CONFIG_FILE"
    chmod 644 "$COTURN_CONFIG_FILE"
    
    log "SUCCESS" "Конфигурация coturn создана для типа сервера: $SERVER_TYPE"
    return 0
}

# Функция настройки systemd службы coturn
configure_coturn_service() {
    print_header "НАСТРОЙКА СЛУЖБЫ COTURN" "$CYAN"
    
    log "INFO" "Настройка системной службы coturn..."
    
    # Включение котурна в systemd
    if ! systemctl enable coturn; then
        log "ERROR" "Ошибка включения автозапуска coturn"
        return 1
    fi
    
    # Создание переопределения службы для лучшей производительности
    local override_dir="/etc/systemd/system/coturn.service.d"
    mkdir -p "$override_dir"
    
    cat > "$override_dir/matrix-optimization.conf" <<EOF
# Matrix TURN Server Optimizations
[Unit]
Description=Coturn TURN Server for Matrix
After=network.target

[Service]
# Увеличиваем лимиты для лучшей производительности
LimitNOFILE=65536
LimitNPROC=32768

# Настройки для стабильной работы
Restart=always
RestartSec=5
TimeoutStartSec=30
TimeoutStopSec=30

# Опциональные настройки безопасности
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log /var/run

[Install]
WantedBy=multi-user.target
EOF

    # Перезагрузка systemd конфигурации
    systemctl daemon-reload
    
    log "SUCCESS" "Служба coturn настроена"
    return 0
}

# Функция настройки файрвола для coturn
configure_coturn_firewall() {
    print_header "НАСТРОЙКА ФАЙРВОЛА ДЛЯ COTURN" "$CYAN"
    
    log "INFO" "Настройка правил файрвола для coturn..."
    
    # Проверяем, установлен ли ufw
    if command -v ufw >/dev/null 2>&1; then
        log "INFO" "Настройка правил ufw для coturn..."
        
        # Основные порты TURN
        ufw allow 3478/tcp comment "Coturn TURN TCP"
        ufw allow 3478/udp comment "Coturn TURN UDP"
        ufw allow 5349/tcp comment "Coturn TURN TLS TCP"
        ufw allow 5349/udp comment "Coturn TURN TLS UDP"
        
        # Диапазон портов для relay
        ufw allow 49152:65535/udp comment "Coturn UDP relay range"
        
        log "SUCCESS" "Правила ufw для coturn настроены"
    else
        log "WARN" "ufw не установлен, настройте файрвол вручную"
        safe_echo "${YELLOW}Необходимо открыть порты:${NC}"
        safe_echo "  - 3478/tcp и 3478/udp (TURN)"
        safe_echo "  - 5349/tcp и 5349/udp (TURN TLS)"
        safe_echo "  - 49152-65535/udp (UDP relay)"
    fi
    
    return 0
}

# Функция запуска и проверки coturn
start_and_verify_coturn() {
    print_header "ЗАПУСК И ПРОВЕРКА COTURN" "$GREEN"
    
    log "INFO" "Запуск службы coturn..."
    
    # Запуск службы
    if ! systemctl start coturn; then
        log "ERROR" "Ошибка запуска coturn"
        log "INFO" "Проверьте логи: journalctl -u coturn -n 50"
        return 1
    fi
    
    # Ожидание запуска
    log "INFO" "Ожидание готовности coturn..."
    local attempts=0
    local max_attempts=10
    
    while [ $attempts -lt $max_attempts ]; do
        if systemctl is-active --quiet coturn; then
            log "SUCCESS" "Coturn запущен"
            break
        fi
        
        attempts=$((attempts + 1))
        if [ $attempts -eq $max_attempts ]; then
            log "ERROR" "Coturn не запустился в течение 10 секунд"
            log "INFO" "Проверьте логи: journalctl -u coturn -n 50"
            return 1
        fi
        
        log "DEBUG" "Ожидание запуска... ($attempts/$max_attempts)"
        sleep 1
    done
    
    # Проверка портов
    log "INFO" "Проверка сетевых портов..."
    if check_port 3478; then
        log "SUCCESS" "Порт 3478 готов для TURN соединений"
    else
        log "WARN" "Порт 3478 может быть недоступен"
    fi
    
    if check_port 5349; then
        log "SUCCESS" "Порт 5349 готов для TURN TLS соединений"
    else
        log "WARN" "Порт 5349 может быть недоступен"
    fi
    
    log "SUCCESS" "Coturn запущен и готов к работе"
    return 0
}

# Функция интеграции с Matrix Synapse
integrate_with_synapse() {
    print_header "ИНТЕГРАЦИЯ С MATRIX SYNAPSE" "$MAGENTA"
    
    log "INFO" "Настройка интеграции coturn с Matrix Synapse..."
    
    # Читаем секрет TURN
    local turn_secret
    if [[ -f "$CONFIG_DIR/coturn_secret" ]]; then
        turn_secret=$(cat "$CONFIG_DIR/coturn_secret")
    else
        log "ERROR" "Секрет TURN не найден"
        return 1
    fi
    
    # Создание конфигурации для Synapse
    local synapse_turn_config="$CONFIG_DIR/synapse_turn_config.yaml"
    log "INFO" "Создание конфигурации TURN для Synapse..."
    
    cat > "$synapse_turn_config" <<EOF
# TURN server configuration for Matrix Synapse
# Add this to your homeserver.yaml or include it via config includes

# TURN server URIs
turn_uris:
  - "turn:$TURN_DOMAIN:3478?transport=udp"
  - "turn:$TURN_DOMAIN:3478?transport=tcp"

# Shared secret for TURN authentication
turn_shared_secret: "$turn_secret"

# User lifetime for TURN credentials (24 hours)
turn_user_lifetime: 86400000

# Allow guests to use TURN server
turn_allow_guests: true
EOF

    chmod 600 "$synapse_turn_config"
    
    # Добавление в основную конфигурацию Synapse если возможно
    local synapse_config="/etc/matrix-synapse/homeserver.yaml"
    local synapse_conf_d="/etc/matrix-synapse/conf.d"
    
    if [[ -d "$synapse_conf_d" ]]; then
        # Предпочитаемый способ - отдельный файл в conf.d
        local turn_config_file="$synapse_conf_d/turn.yaml"
        cp "$synapse_turn_config" "$turn_config_file"
        chown matrix-synapse:matrix-synapse "$turn_config_file" 2>/dev/null || true
        
        log "SUCCESS" "Конфигурация TURN добавлена в $turn_config_file"
    elif [[ -f "$synapse_config" ]]; then
        # Резервный способ - показываем что добавить вручную
        log "WARN" "Добавьте следующие строки в $synapse_config:"
        echo
        safe_echo "${CYAN}# TURN server configuration${NC}"
        safe_echo "${CYAN}turn_uris:${NC}"
        safe_echo "${CYAN}  - \"turn:$TURN_DOMAIN:3478?transport=udp\"${NC}"
        safe_echo "${CYAN}  - \"turn:$TURN_DOMAIN:3478?transport=tcp\"${NC}"
        safe_echo "${CYAN}turn_shared_secret: \"$turn_secret\"${NC}"
        safe_echo "${CYAN}turn_user_lifetime: 86400000${NC}"
        safe_echo "${CYAN}turn_allow_guests: true${NC}"
        echo
    else
        log "WARN" "Конфигурация Synapse не найдена"
        log "INFO" "Используйте файл $synapse_turn_config для ручной настройки"
    fi
    
    # Сохранение конфигурации для справки
    cat > "$CONFIG_DIR/coturn_info.conf" <<EOF
# Coturn TURN Server Information
TURN_DOMAIN=$TURN_DOMAIN
TURN_SECRET_FILE=$CONFIG_DIR/coturn_secret
SYNAPSE_TURN_CONFIG=$synapse_turn_config
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
SERVER_TYPE=$SERVER_TYPE
EOF

    log "SUCCESS" "Интеграция с Matrix Synapse настроена"
    log "INFO" "Перезапустите Matrix Synapse для применения настроек TURN"
    
    return 0
}

# Функция проверки работы coturn
test_coturn_functionality() {
    print_header "ТЕСТИРОВАНИЕ COTURN" "$GREEN"
    
    log "INFO" "Проверка функциональности coturn..."
    
    # Базовые проверки
    if ! systemctl is-active --quiet coturn; then
        log "ERROR" "Coturn не запущен"
        return 1
    fi
    
    # Проверка портов
    local ports=(3478 5349)
    for port in "${ports[@]}"; do
        if ss -tlnp | grep -q ":$port "; then
            log "SUCCESS" "✓ Порт $port прослушивается"
        else
            log "WARN" "✗ Порт $port не прослушивается"
        fi
    done
    
    # Проверка конфигурации
    if turnserver --check-config -c "$COTURN_CONFIG_FILE" >/dev/null 2>&1; then
        log "SUCCESS" "✓ Конфигурация coturn корректна"
    else
        log "WARN" "✗ Возможны проблемы в конфигурации coturn"
    fi
    
    # Инструкции по тестированию
    safe_echo "${BOLD}${BLUE}Дополнительное тестирование:${NC}"
    safe_echo "1. ${CYAN}Тестер Matrix VoIP:${NC}"
    safe_echo "   https://test.voip.librepush.net/"
    echo
    safe_echo "2. ${CYAN}WebRTC тестер:${NC}"
    safe_echo "   https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/"
    echo
    safe_echo "3. ${CYAN}Информация для тестирования:${NC}"
    safe_echo "   TURN URI: turn:$TURN_DOMAIN:3478"
    safe_echo "   Username: test"
    safe_echo "   Password: используйте временные credentials из Synapse"
    
    return 0
}

# Функция показа статуса coturn
show_coturn_status() {
    print_header "СТАТУС COTURN" "$CYAN"
    
    echo "Домен TURN сервера: ${TURN_DOMAIN:-не настроен}"
    echo "Конфигурация: $COTURN_CONFIG_FILE"
    echo "Тип сервера: ${SERVER_TYPE:-не определен}"
    
    # Статус службы
    echo
    echo "Статус службы:"
    if systemctl is-active --quiet coturn; then
        safe_echo "${GREEN}• Coturn: запущен${NC}"
        
        # Показываем порты
        echo "  Прослушиваемые порты:"
        ss -tlnp | grep -E ":(3478|5349) " | while read line; do
            safe_echo "    ${GREEN}✓${NC} $line"
        done
    else
        safe_echo "${RED}• Coturn: остановлен${NC}"
    fi
    
    # Информация о конфигурации
    echo
    echo "Конфигурация:"
    if [[ -f "$CONFIG_DIR/coturn_secret" ]]; then
        safe_echo "${GREEN}• Секрет TURN: настроен${NC}"
    else
        safe_echo "${RED}• Секрет TURN: не настроен${NC}"
    fi
    
    if [[ -f "$CONFIG_DIR/coturn_info.conf" ]]; then
        source "$CONFIG_DIR/coturn_info.conf"
        safe_echo "${GREEN}• Дата установки: ${INSTALL_DATE:-неизвестна}${NC}"
    fi
    
    # Статистика подключений (если доступна)
    echo
    echo "Статистика (последние 24 часа):"
    local turn_sessions=$(journalctl -u coturn --since "24 hours ago" 2>/dev/null | grep -c "session" || echo "0")
    echo "  Сессий TURN: $turn_sessions"
    
    return 0
}

# Функция управления котурном
manage_coturn() {
    while true; do
        print_header "УПРАВЛЕНИЕ COTURN" "$YELLOW"
        
        safe_echo "${BOLD}Доступные действия:${NC}"
        safe_echo "${GREEN}1.${NC} Показать статус coturn"
        safe_echo "${GREEN}2.${NC} Перезапустить coturn"
        safe_echo "${GREEN}3.${NC} Остановить coturn"
        safe_echo "${GREEN}4.${NC} Запустить coturn"
        safe_echo "${GREEN}5.${NC} Показать логи coturn"
        safe_echo "${GREEN}6.${NC} Проверить конфигурацию"
        safe_echo "${GREEN}7.${NC} Тестировать функциональность"
        safe_echo "${GREEN}8.${NC} Пересоздать конфигурацию"
        safe_echo "${GREEN}9.${NC} Назад в главное меню"
        
        echo
        read -p "$(safe_echo "${YELLOW}Выберите действие (1-9): ${NC}")" choice
        
        case $choice in
            1)
                show_coturn_status
                ;;
            2)
                log "INFO" "Перезапуск coturn..."
                if restart_service coturn; then
                    log "SUCCESS" "Coturn перезапущен"
                else
                    log "ERROR" "Ошибка перезапуска coturn"
                fi
                ;;
            3)
                log "INFO" "Остановка coturn..."
                if systemctl stop coturn; then
                    log "SUCCESS" "Coturn остановлен"
                else
                    log "ERROR" "Ошибка остановки coturn"
                fi
                ;;
            4)
                log "INFO" "Запуск coturn..."
                if systemctl start coturn; then
                    log "SUCCESS" "Coturn запущен"
                else
                    log "ERROR" "Ошибка запуска coturn"
                fi
                ;;
            5)
                log "INFO" "Логи coturn (Ctrl+C для выхода):"
                journalctl -u coturn -f
                ;;
            6)
                log "INFO" "Проверка конфигурации coturn..."
                if turnserver --check-config -c "$COTURN_CONFIG_FILE"; then
                    log "SUCCESS" "Конфигурация корректна"
                else
                    log "ERROR" "Ошибки в конфигурации"
                fi
                ;;
            7)
                test_coturn_functionality
                ;;
            8)
                if ask_confirmation "Пересоздать конфигурацию coturn?"; then
                    create_coturn_config
                    if ask_confirmation "Перезапустить coturn для применения изменений?"; then
                        restart_service coturn
                    fi
                fi
                ;;
            9)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                sleep 1
                ;;
        esac
        
        if [ $choice -ne 9 ]; then
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Функция удаления coturn
remove_coturn() {
    print_header "УДАЛЕНИЕ COTURN" "$RED"
    
    if ! ask_confirmation "Вы уверены, что хотите удалить coturn TURN сервер?"; then
        log "INFO" "Удаление отменено пользователем"
        return 0
    fi
    
    log "INFO" "Начинаем удаление coturn..."
    
    # Остановка и отключение службы
    systemctl stop coturn 2>/dev/null || true
    systemctl disable coturn 2>/dev/null || true
    
    # Создание резервной копии конфигурации
    if [[ -f "$COTURN_CONFIG_FILE" ]]; then
        mkdir -p "$COTURN_BACKUP_DIR"
        cp "$COTURN_CONFIG_FILE" "$COTURN_BACKUP_DIR/turnserver.conf.backup-$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Резервная копия конфигурации создана в $COTURN_BACKUP_DIR"
    fi
    
    # Удаление пакета
    apt remove -y coturn 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    
    # Удаление конфигурационных файлов
    rm -f "$COTURN_CONFIG_FILE"
    rm -rf /etc/systemd/system/coturn.service.d/
    
    # Очистка systemd
    systemctl daemon-reload
    
    # Удаление из конфигурации Synapse
    local synapse_turn_config="/etc/matrix-synapse/conf.d/turn.yaml"
    if [[ -f "$synapse_turn_config" ]]; then
        mv "$synapse_turn_config" "$COTURN_BACKUP_DIR/synapse_turn.yaml.backup-$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Конфигурация TURN удалена из Synapse"
    fi
    
    log "SUCCESS" "Coturn успешно удален"
    log "INFO" "Резервные копии сохранены в: $COTURN_BACKUP_DIR"
    log "WARN" "Не забудьте перезапустить Matrix Synapse и удалить настройки TURN из homeserver.yaml"
    
    return 0
}

# Главная функция установки coturn
main() {
    print_header "COTURN TURN SERVER SETUP v1.0" "$GREEN"
    
    log "INFO" "Начало настройки coturn TURN сервера"
    log "INFO" "Использование библиотеки: $LIB_NAME v$LIB_VERSION"
    
    # Выполнение этапов установки
    local steps=(
        "check_coturn_requirements:Проверка системных требований"
        "get_turn_domain:Настройка домена TURN сервера"
        "install_coturn:Установка coturn"
        "create_coturn_config:Создание конфигурации"
        "configure_coturn_service:Настройка службы"
        "configure_coturn_firewall:Настройка файрвола"
        "start_and_verify_coturn:Запуск и проверка"
        "integrate_with_synapse:Интеграция с Synapse"
        "test_coturn_functionality:Тестирование"
    )
    
    local total_steps=${#steps[@]}
    local current_step=0
    
    for step_info in "${steps[@]}"; do
        current_step=$((current_step + 1))
        local step_func="${step_info%%:*}"
        local step_name="${step_info##*:}"
        
        print_header "ЭТАП $current_step/$total_steps: $step_name" "$CYAN"
        
        if ! $step_func; then
            log "ERROR" "Ошибка на этапе: $step_name"
            log "ERROR" "Установка прервана"
            return 1
        fi
        
        log "SUCCESS" "Этап завершён: $step_name"
        echo
    done
    
    # Вывод итоговой информации
    print_header "УСТАНОВКА COTURN ЗАВЕРШЕНА УСПЕШНО!" "$GREEN"
    
    safe_echo "${GREEN}✅ Coturn TURN сервер установлен и настроен${NC}"
    safe_echo "${BLUE}📋 Информация об установке:${NC}"
    safe_echo "   ${BOLD}Тип сервера:${NC} $SERVER_TYPE"
    safe_echo "   ${BOLD}Домен TURN:${NC} $TURN_DOMAIN"
    safe_echo "   ${BOLD}Конфигурация:${NC} $COTURN_CONFIG_FILE"
    safe_echo "   ${BOLD}Логи:${NC} journalctl -u coturn"
    [[ -n "${PUBLIC_IP:-}" ]] && safe_echo "   ${BOLD}Публичный IP:${NC} $PUBLIC_IP"
    [[ -n "${LOCAL_IP:-}" ]] && safe_echo "   ${BOLD}Локальный IP:${NC} $LOCAL_IP"
    
    echo
    safe_echo "${YELLOW}📝 Следующие шаги:${NC}"
    safe_echo "   1. ${CYAN}Перезапустите Matrix Synapse:${NC}"
    safe_echo "      systemctl restart matrix-synapse"
    echo
    safe_echo "   2. ${CYAN}Проверьте работу TURN:${NC}"
    safe_echo "      https://test.voip.librepush.net/"
    echo
    safe_echo "   3. ${CYAN}Настройте DNS (если используется домен):${NC}"
    safe_echo "      A запись: $TURN_DOMAIN → ${PUBLIC_IP:-$LOCAL_IP}"
    echo
    safe_echo "   4. ${CYAN}Порты для файрвола:${NC}"
    safe_echo "      3478/tcp,udp - TURN"
    safe_echo "      5349/tcp,udp - TURN TLS"
    safe_echo "      49152-65535/udp - UDP relay"
    
    echo
    safe_echo "${GREEN}🎉 Coturn готов для использования с Matrix!${NC}"
    safe_echo "${BLUE}💡 VoIP звонки теперь будут работать даже за NAT/firewall${NC}"
    
    # Сохранение информации об установке
    set_config_value "$CONFIG_DIR/coturn.conf" "COTURN_INSTALLED" "true"
    set_config_value "$CONFIG_DIR/coturn.conf" "INSTALL_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
    set_config_value "$CONFIG_DIR/coturn.conf" "SERVER_TYPE" "$SERVER_TYPE"
    set_config_value "$CONFIG_DIR/coturn.conf" "TURN_DOMAIN" "$TURN_DOMAIN"
    
    return 0
}

# Функция главного меню модуля
coturn_menu() {
    while true; do
        show_menu "УПРАВЛЕНИЕ COTURN TURN SERVER" \
            "Установить coturn" \
            "Показать статус" \
            "Управление службой" \
            "Тестировать функциональность" \
            "Пересоздать конфигурацию" \
            "Удалить coturn" \
            "Назад в главное меню"
        
        local choice=$?
        
        case $choice in
            1) main ;;
            2) show_coturn_status ;;
            3) manage_coturn ;;
            4) test_coturn_functionality ;;
            5) 
                if ask_confirmation "Пересоздать конфигурацию coturn?"; then
                    get_turn_domain && create_coturn_config
                    if ask_confirmation "Перезапустить coturn для применения изменений?"; then
                        restart_service coturn
                    fi
                fi
                ;;
            6) remove_coturn ;;
            7) break ;;
            *) log "ERROR" "Неверный выбор" ;;
        esac
        
        if [ $choice -ne 7 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Экспорт функций для использования в других скриптах
export -f main
export -f coturn_menu
export -f show_coturn_status
export -f manage_coturn
export -f test_coturn_functionality

# Проверка, вызван ли скрипт напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    coturn_menu
fi