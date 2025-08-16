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

# Основная функция установки
main() {
    print_header "COTURN TURN SERVER SETUP" "$GREEN"
    
    log "INFO" "Начинаем установку Coturn TURN Server..."
    
    # Выполняем все этапы установки последовательно
    if ! check_coturn_requirements; then
        log "ERROR" "Системные требования не выполнены"
        return 1
    fi
    
    # Выбор способа развертывания (для NAT серверов)
    if ! choose_turn_deployment; then
        log "INFO" "Установка отменена пользователем"
        return 1
    fi
    
    # Получение доменного имени
    if ! get_turn_domain; then
        log "ERROR" "Не удалось настроить домен TURN"
        return 1
    fi
    
    # Установка coturn
    if ! install_coturn; then
        log "ERROR" "Ошибка установки coturn"
        return 1
    fi
    
    # Создание конфигурации
    if ! create_coturn_config; then
        log "ERROR" "Ошибка создания конфигурации coturn"
        return 1
    fi
    
    # Настройка службы
    if ! configure_coturn_service; then
        log "ERROR" "Ошибка настройки службы coturn"
        return 1
    fi
    
    # Настройка файрвола
    if ! configure_coturn_firewall; then
        log "WARN" "Файрвол настроен с предупреждениями"
    fi
    
    # Запуск и проверка
    if ! start_and_verify_coturn; then
        log "ERROR" "Ошибка запуска coturn"
        return 1
    fi
    
    # Интеграция с Matrix Synapse
    if ! integrate_with_synapse; then
        log "ERROR" "Ошибка интеграции с Matrix Synapse"
        return 1
    fi
    
    # Тестирование функциональности
    test_coturn_functionality
    
    print_header "COTURN УСТАНОВЛЕН УСПЕШНО!" "$GREEN"
    safe_echo "${GREEN}✅ Coturn TURN Server готов к работе${NC}"
    safe_echo "${BLUE}📋 Домен TURN: ${TURN_DOMAIN:-не настроен}${NC}"
    safe_echo "${BLUE}🔧 Конфигурация: $COTURN_CONFIG_FILE${NC}"
    safe_echo "${BLUE}📊 Управление: sudo ./modules/coturn_setup.sh${NC}"
    
    log "SUCCESS" "Установка Coturn завершена успешно"
    return 0
}

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

# Функция выбора способа развертывания TURN
choose_turn_deployment() {
    print_header "ВЫБОР СПОСОБА РАЗВЕРТЫВАНИЯ TURN" "$CYAN"
    
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            safe_echo "${YELLOW}⚠️ ОБНАРУЖЕНА ПРОБЛЕМА С СЕТЕВОЙ КОНФИГУРАЦИЕЙ${NC}"
            safe_echo "${RED}Для Proxmox за NAT требуются дополнительные порты:${NC}"
            safe_echo "   - 3478 (TURN TCP/UDP)"
            safe_echo "   - 5349 (TURN TLS TCP/UDP)"  
            safe_echo "   - 49152-65535 (UDP relay range)"
            echo
            safe_echo "${BLUE}Доступные варианты:${NC}"
            safe_echo "${GREEN}1.${NC} Установить локально (требует открытия портов на роутере)"
            safe_echo "${GREEN}2.${NC} Использовать внешний TURN сервер (рекомендуется)"
            safe_echo "${GREEN}3.${NC} Использовать публичный TURN сервер Matrix.org"
            safe_echo "${GREEN}4.${NC} Отменить установку"
            ;;
        *)
            # Для облачных серверов - стандартная установка
            return 0
            ;;
    esac
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите вариант (1-4): ${NC}")" deployment_choice
    
    case $deployment_choice in
        1)
            show_router_configuration_help
            if ask_confirmation "Порты уже настроены на роутере?"; then
                return 0  # Продолжить локальную установку
            else
                return 1  # Прервать установку
            fi
            ;;
        2)
            configure_external_turn_server
            return $?
            ;;
        3)
            configure_public_turn_server
            return $?
            ;;
        4)
            log "INFO" "Установка TURN отменена пользователем"
            return 1
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
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

# Функция создания конфигурации coturn
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
EOF

    # Установка прав доступа
    chown root:root "$COTURN_CONFIG_FILE"
    chmod 644 "$COTURN_CONFIG_FILE"
    
    log "SUCCESS" "Конфигурация coturn создана для типа сервера: $SERVER_TYPE"
    return 0
}

# Функция настройки службы coturn
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

# Функция тестирования coturn
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

# Функция создания скрипта установки для внешнего сервера
create_external_turn_install_script() {
    local external_turn_ip="$1"
    local turn_secret="$2"
    local install_script="$CONFIG_DIR/external_turn_install.sh"
    
    log "INFO" "Создание скрипта установки для внешнего TURN сервера..."
    
    cat > "$install_script" <<'SCRIPT_EOF'
#!/bin/bash
# Automatic Coturn TURN Server Installation Script
# Generated by Matrix Setup Tool for external server

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}          COTURN TURN SERVER INSTALLATION SCRIPT              ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Update system
echo -e "${BLUE}Updating system packages...${NC}"
apt update && apt upgrade -y

# Install coturn
echo -e "${BLUE}Installing coturn...${NC}"
apt install -y coturn

echo -e "${GREEN}✅ Coturn installation completed!${NC}"
SCRIPT_EOF
    
    # Заменяем переменные в скрипте
    sed -i "s/EXTERNAL_IP_PLACEHOLDER/$external_turn_ip/g" "$install_script"
    sed -i "s/TURN_SECRET_PLACEHOLDER/$turn_secret/g" "$install_script"
    sed -i "s/TURN_DOMAIN_PLACEHOLDER/$TURN_DOMAIN/g" "$install_script"
    
    chmod +x "$install_script"
    
    log "SUCCESS" "Скрипт установки создан: $install_script"
    return 0
}

# Функция настройки внешнего TURN сервера
configure_external_turn_server() {
    print_header "НАСТРОЙКА ВНЕШНЕГО TURN СЕРВЕРА" "$BLUE"
    
    safe_echo "${BLUE}Рекомендуемые провайдеры для TURN сервера:${NC}"
    safe_echo "1. Hetzner Cloud (от 300₽/мес)"
    safe_echo "2. DigitalOcean (от \$4/мес)"
    safe_echo "3. Vultr (от \$2.50/мес)"
    safe_echo "4. Свой VPS"
    echo
    
    read -p "$(safe_echo "${YELLOW}Введите IP адрес внешнего TURN сервера: ${NC}")" external_turn_ip
    read -p "$(safe_echo "${YELLOW}Введите домен TURN сервера (или Enter для IP): ${NC}")" external_turn_domain
    
    # Валидация IP адреса
    if [[ ! "$external_turn_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log "ERROR" "Неверный формат IP адреса: $external_turn_ip"
        return 1
    fi
    
    TURN_DOMAIN="${external_turn_domain:-$external_turn_ip}"
    echo "$TURN_DOMAIN" > "$CONFIG_DIR/turn_domain"
    
    # Генерация секрета для внешнего сервера
    local turn_secret=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    echo "$turn_secret" > "$CONFIG_DIR/coturn_secret"
    chmod 600 "$CONFIG_DIR/coturn_secret"
    
    log "INFO" "Сгенерирован секрет TURN для внешнего сервера"
    
    # Создание скрипта установки для внешнего сервера
    create_external_turn_install_script "$external_turn_ip" "$turn_secret"
    
    # Настройка Synapse для внешнего TURN
    configure_synapse_for_external_turn
    
    log "SUCCESS" "Конфигурация для внешнего TURN сервера готова"
    
    return 0
}

# Функция настройки публичного TURN сервера
configure_public_turn_server() {
    print_header "НАСТРОЙКА ПУБЛИЧНОГО TURN СЕРВЕРА" "$GREEN"
    
    safe_echo "${BLUE}Использование публичного TURN сервера Matrix.org${NC}"
    safe_echo "${YELLOW}⚠️ Это временное решение для тестирования${NC}"
    safe_echo "${RED}Не рекомендуется для продакшена!${NC}"
    echo
    
    if ask_confirmation "Продолжить с публичным TURN сервером?"; then
        TURN_DOMAIN="turn.matrix.org"
        echo "$TURN_DOMAIN" > "$CONFIG_DIR/turn_domain"
        
        # Создание конфигурации для публичного TURN
        local synapse_turn_config="$CONFIG_DIR/synapse_turn_config.yaml"
        cat > "$synapse_turn_config" <<EOF
# Public TURN server configuration (TEMPORARY SOLUTION)
turn_uris:
  - "turn:turn.matrix.org:3478?transport=udp"
  - "turn:turn.matrix.org:3478?transport=tcp"
  - "turns:turn.matrix.org:5349?transport=udp"
  - "turns:turn.matrix.org:5349?transport=tcp"

turn_shared_secret: "placeholder_secret"
turn_user_lifetime: 86400000
turn_allow_guests: true
EOF
        
        # Добавление в Synapse
        local synapse_conf_d="/etc/matrix-synapse/conf.d"
        if [[ -d "$synapse_conf_d" ]]; then
            cp "$synapse_turn_config" "$synapse_conf_d/turn.yaml"
            chown matrix-synapse:matrix-synapse "$synapse_conf_d/turn.yaml" 2>/dev/null || true
        fi
        
        log "SUCCESS" "Публичный TURN сервер настроен"
        
        return 0
    else
        return 1
    fi
}

# Функция настройки Synapse для внешнего TURN
configure_synapse_for_external_turn() {
    log "INFO" "Настройка Matrix Synapse для внешнего TURN сервера..."
    
    # Вызываем функцию интеграции с Synapse
    integrate_with_synapse
    
    return $?
}

# Функция диагностики сетевой доступности TURN
diagnose_turn_connectivity() {
    print_header "ДИАГНОСТИКА СЕТЕВОЙ ДОСТУПНОСТИ TURN" "$YELLOW"
    
    log "INFO" "Проведение диагностики сетевой доступности TURN сервера..."
    
    # Проверка локальной доступности
    echo
    safe_echo "${BOLD}${BLUE}1. Проверка локальной доступности портов:${NC}"
    local ports=(3478 5349)
    
    for port in "${ports[@]}"; do
        if ss -tlnp | grep -q ":$port "; then
            safe_echo "   ${GREEN}✓${NC} Порт $port локально доступен"
        else
            safe_echo "   ${RED}✗${NC} Порт $port недоступен локально"
        fi
    done
    
    # Проверка статуса службы
    echo
    safe_echo "${BOLD}${BLUE}2. Проверка статуса службы:${NC}"
    if systemctl is-active --quiet coturn; then
        safe_echo "   ${GREEN}✓${NC} Служба coturn запущена"
    else
        safe_echo "   ${RED}✗${NC} Служба coturn не запущена"
        safe_echo "   ${CYAN}Запустите: systemctl start coturn${NC}"
    fi
    
    return 0
}

# Функция помощи по настройке роутера
show_router_configuration_help() {
    print_header "НАСТРОЙКА ПОРТОВ НА РОУТЕРЕ" "$YELLOW"
    
    safe_echo "${BOLD}Для работы TURN сервера необходимо открыть порты:${NC}"
    echo
    safe_echo "${CYAN}Основные порты TURN:${NC}"
    safe_echo "   3478/tcp → ${LOCAL_IP}:3478"
    safe_echo "   3478/udp → ${LOCAL_IP}:3478"
    safe_echo "   5349/tcp → ${LOCAL_IP}:5349"  
    safe_echo "   5349/udp → ${LOCAL_IP}:5349"
    echo
    safe_echo "${CYAN}UDP relay диапазон:${NC}"
    safe_echo "   49152-65535/udp → ${LOCAL_IP}:49152-65535"
    echo
    safe_echo "${RED}⚠️ ВНИМАНИЕ: Большой UDP диапазон может создать нагрузку${NC}"
    safe_echo "${YELLOW}💡 Рекомендуется использовать внешний TURN сервер${NC}"
}

# Функция главного меню модуля
coturn_menu() {
    while true; do
        print_header "УПРАВЛЕНИЕ COTURN TURN SERVER" "$CYAN"
        
        safe_echo "${BOLD}Доступные действия:${NC}"
        safe_echo "${GREEN}1.${NC} Установить coturn (автовыбор типа)"
        safe_echo "${GREEN}2.${NC} Установить локально (принудительно)"
        safe_echo "${GREEN}3.${NC} Настроить внешний TURN сервер"
        safe_echo "${GREEN}4.${NC} Настроить публичный TURN сервер"
        safe_echo "${GREEN}5.${NC} Показать статус"
        safe_echo "${GREEN}6.${NC} Тестировать функциональность"
        safe_echo "${GREEN}7.${NC} Диагностика сетевой доступности"
        safe_echo "${GREEN}8.${NC} Назад в главное меню"
        
        echo
        read -p "$(safe_echo "${YELLOW}Выберите действие (1-8): ${NC}")" choice
        
        case $choice in
            1) 
                main 
                ;;
            2) 
                log "INFO" "Принудительная локальная установка coturn..."
                if check_coturn_requirements && get_turn_domain; then
                    install_coturn && create_coturn_config && configure_coturn_service && \
                    configure_coturn_firewall && start_and_verify_coturn && \
                    integrate_with_synapse && test_coturn_functionality
                fi
                ;;
            3)
                if check_coturn_requirements; then
                    configure_external_turn_server
                fi
                ;;
            4)
                if check_coturn_requirements; then
                    configure_public_turn_server
                fi
                ;;
            5) 
                test_coturn_functionality
                ;;
            6) 
                test_coturn_functionality 
                ;;
            7)
                diagnose_turn_connectivity
                ;;
            8) 
                break 
                ;;
            *) 
                log "ERROR" "Неверный выбор" 
                ;;
        esac
        
        if [ $choice -ne 8 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Экспорт функций для использования в других скриптах
export -f main
export -f coturn_menu
export -f test_coturn_functionality

# Проверка, вызван ли скрипт напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    coturn_menu
fi