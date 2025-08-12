#!/bin/bash

# Модуль управления федерацией Matrix Synapse
# Версия: 3.0.0
# Работает только с конфигурациями Synapse, не затрагивает реверс-прокси

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/common_lib.sh"

# Константы модуля
MODULE_NAME="Federation Control"
MODULE_VERSION="3.0.0"
CONFIG_DIR="/opt/matrix-install"
SYNAPSE_CONFIG_DIR="/etc/matrix-synapse"
FEDERATION_CONFIG_FILE="${SYNAPSE_CONFIG_DIR}/conf.d/federation.yaml"

# Инициализация модуля
init_federation_module() {
    print_header "$MODULE_NAME v$MODULE_VERSION" "$CYAN"
    
    # Проверка root прав
    check_root || exit 1
    
    # Проверка основной конфигурации
    if [[ ! -f "$CONFIG_DIR/domain" ]]; then
        log "ERROR" "Файл домена не найден: $CONFIG_DIR/domain"
        log "ERROR" "Пожалуйста, сначала выполните основную установку Matrix Synapse"
        exit 1
    fi
    
    MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain" 2>/dev/null)
    if [[ -z "$MATRIX_DOMAIN" ]]; then
        log "ERROR" "Домен Matrix не настроен. Запустите сначала основную установку"
        exit 1
    fi
    
    # Проверка конфигурационной директории Synapse
    if [[ ! -d "$SYNAPSE_CONFIG_DIR" ]]; then
        log "ERROR" "Конфигурационная директория Synapse не найдена: $SYNAPSE_CONFIG_DIR"
        exit 1
    fi
    
    # Создание директории для модульных конфигураций если не существует
    mkdir -p "${SYNAPSE_CONFIG_DIR}/conf.d"
    
    log "INFO" "Модуль федерации инициализирован для домена: $MATRIX_DOMAIN"
}

# Создание резервной копии конфигурации
backup_federation_config() {
    local backup_name="federation_config"
    
    if [[ -f "$FEDERATION_CONFIG_FILE" ]]; then
        backup_file "$FEDERATION_CONFIG_FILE" "$backup_name"
        log "SUCCESS" "Создана резервная копия конфигурации федерации"
    fi
}

# Получение текущего статуса федерации
get_federation_status() {
    local config_file="$FEDERATION_CONFIG_FILE"
    
    if [[ ! -f "$config_file" ]]; then
        echo "default"
        return 0
    fi
    
    # Проверяем наличие federation_domain_whitelist
    if grep -q "^federation_domain_whitelist:" "$config_file"; then
        local whitelist_content=$(grep -A 10 "^federation_domain_whitelist:" "$config_file" | tail -n +2)
        
        # Если список пустой или содержит только []
        if echo "$whitelist_content" | grep -q "^\s*\[\s*\]\s*$" || [[ -z "$whitelist_content" ]]; then
            echo "disabled"
        else
            echo "whitelist"
        fi
    else
        echo "default"
    fi
}

# Включение федерации по умолчанию (полная федерация)
enable_full_federation() {
    log "INFO" "Включение полной федерации..."
    
    backup_federation_config
    
    cat > "$FEDERATION_CONFIG_FILE" << 'EOF'
# Конфигурация федерации Matrix Synapse
# Автоматически сгенерировано

# Полная федерация - разрешена со всеми серверами
# federation_domain_whitelist не указан = федерация со всеми

# Настройки безопасности федерации
federation_verify_certificates: true
federation_client_minimum_tls_version: "1.2"

# Разрешить просмотр профилей через федерацию
allow_profile_lookup_over_federation: true

# Разрешить просмотр имен устройств через федерацию
allow_device_name_lookup_over_federation: false

# Доверенные серверы ключей
trusted_key_servers:
  - server_name: "matrix.org"

# Тайм-ауты и настройки федерации
federation:
  client_timeout: 60s
  max_short_retry_delay: 2s
  max_long_retry_delay: 60s
  max_short_retries: 3
  max_long_retries: 10
  destination_min_retry_interval: 10m
  destination_retry_multiplier: 2
  destination_max_retry_interval: 1w
EOF

    if restart_service "matrix-synapse"; then
        log "SUCCESS" "Полная федерация включена для всех серверов Matrix"
        log "INFO" "Ваш сервер может федерироваться с любыми серверами Matrix"
    else
        log "ERROR" "Ошибка при перезапуске Synapse"
        return 1
    fi
}

# Отключение федерации
disable_federation() {
    log "INFO" "Отключение федерации..."
    
    backup_federation_config
    
    cat > "$FEDERATION_CONFIG_FILE" << 'EOF'
# Конфигурация федерации Matrix Synapse (отключена)
# Автоматически сгенерировано

# Федерация отключена - пустой белый список
federation_domain_whitelist: []

# Настройки безопасности (даже при отключенной федерации)
federation_verify_certificates: true
federation_client_minimum_tls_version: "1.2"

# Запретить просмотр профилей через федерацию
allow_profile_lookup_over_federation: false

# Запретить просмотр имен устройств через федерацию
allow_device_name_lookup_over_federation: false

# Минимальный набор доверенных серверов ключей
trusted_key_servers:
  - server_name: "matrix.org"
EOF

    if restart_service "matrix-synapse"; then
        log "SUCCESS" "Федерация отключена"
        log "INFO" "Ваш сервер работает в изолированном режиме"
    else
        log "ERROR" "Ошибка при перезапуске Synapse"
        return 1
    fi
}

# Проверка статуса федерации
check_federation_status() {
    print_header "СТАТУС ФЕДЕРАЦИИ" "$BLUE"
    
    local status=$(get_federation_status)
    
    echo "📊 Информация о федерации:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    case "$status" in
        "default")
            safe_echo "${GREEN}✓ Статус: Полная федерация${NC}"
            echo "  Разрешена федерация со всеми серверами Matrix"
            ;;
        "whitelist")
            safe_echo "${YELLOW}⚠ Статус: Ограниченная федерация${NC}"
            echo "  Разрешена федерация только с доменами из белого списка:"
            echo
            grep -A 20 "^federation_domain_whitelist:" "$FEDERATION_CONFIG_FILE" | grep "^  -" | sed 's/^  - "\(.*\)"/  - \1/'
            ;;
        "disabled")
            safe_echo "${RED}✗ Статус: Федерация отключена${NC}"
            echo "  Сервер работает в изолированном режиме"
            ;;
    esac
    
    echo
    echo "🌐 Сетевые проверки:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Проверка well-known файла
    echo -n "  Well-known файл: "
    if curl -s --connect-timeout 5 "https://$MATRIX_DOMAIN/.well-known/matrix/server" >/dev/null 2>&1; then
        safe_echo "${GREEN}✓ Доступен${NC}"
    else
        safe_echo "${RED}✗ Недоступен${NC}"
    fi
    
    # Проверка federation API
    echo -n "  Federation API: "
    if curl -s --connect-timeout 5 "https://$MATRIX_DOMAIN:8448/_matrix/federation/v1/version" >/dev/null 2>&1; then
        safe_echo "${GREEN}✓ Доступен${NC}"
    else
        safe_echo "${RED}✗ Недоступен${NC}"
    fi
    
    # Проверка службы Synapse
    echo -n "  Служба Synapse: "
    if systemctl is-active --quiet matrix-synapse; then
        safe_echo "${GREEN}✓ Активна${NC}"
    else
        safe_echo "${RED}✗ Неактивна${NC}"
    fi
    
    echo
    echo "🔧 Полезные ссылки:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  • Тестер федерации: https://federationtester.matrix.org/#$MATRIX_DOMAIN"
    echo "  • Проверка well-known: https://$MATRIX_DOMAIN/.well-known/matrix/server"
    echo
}

# Главное меню
show_federation_menu() {
    local current_status=$(get_federation_status)
    local status_text
    
    case "$current_status" in
        "default") status_text="${GREEN}Полная федерация${NC}" ;;
        "whitelist") status_text="${YELLOW}Ограниченная федерация${NC}" ;;
        "disabled") status_text="${RED}Федерация отключена${NC}" ;;
    esac
    
    while true; do
        print_header "УПРАВЛЕНИЕ ФЕДЕРАЦИЕЙ MATRIX SYNAPSE" "$CYAN"
        
        safe_echo "Домен сервера: ${BOLD}$MATRIX_DOMAIN${NC}"
        safe_echo "Текущий статус: $status_text"
        echo
        
        echo "Выберите действие:"
        echo
        echo "1) 🌐 Включить полную федерацию (со всеми серверами)"
        echo "2) ❌ Отключить федерацию"
        echo "3) 📊 Проверить статус федерации"
        echo "4) 🔙 Вернуться в главное меню"
        echo
        
        read -p "Ваш выбор [1-4]: " choice
        
        case $choice in
            1)
                enable_full_federation
                current_status=$(get_federation_status)
                case "$current_status" in
                    "default") status_text="${GREEN}Полная федерация${NC}" ;;
                    "whitelist") status_text="${YELLOW}Ограниченная федерация${NC}" ;;
                    "disabled") status_text="${RED}Федерация отключена${NC}" ;;
                esac
                ;;
            2)
                disable_federation
                current_status=$(get_federation_status)
                case "$current_status" in
                    "default") status_text="${GREEN}Полная федерация${NC}" ;;
                    "whitelist") status_text="${YELLOW}Ограниченная федерация${NC}" ;;
                    "disabled") status_text="${RED}Федерация отключена${NC}" ;;
                esac
                ;;
            3)
                check_federation_status
                echo
                read -p "Нажмите Enter для продолжения..."
                ;;
            4)
                log "INFO" "Возврат в главное меню"
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Пожалуйста, выберите от 1 до 4"
                sleep 2
                ;;
        esac
        
        echo
    done
}

# Основная функция
main() {
    init_federation_module
    show_federation_menu
}

# Запуск если скрипт вызван напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi