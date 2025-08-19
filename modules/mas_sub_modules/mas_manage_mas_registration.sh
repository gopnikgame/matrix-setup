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
        if ask_confirmation "Установить yq автоматически?"; then
            log "INFO" "Установка yq..."
            if command -v snap &>/dev/null; then
                if snap install yq; then
                    log "SUCCESS" "yq установлен через snap"
                    return 0
                fi
            fi
            log "INFO" "Установка yq через GitHub releases..."
            local arch=$(uname -m)
            local yq_binary=""
            case "$arch" in
                x86_64) yq_binary="yq_linux_amd64" ;;
                aarch64|arm64) yq_binary="yq_linux_arm64" ;;
                *) log "ERROR" "Неподдерживаемая архитектура для yq: $arch"; return 1 ;;
            esac
            local yq_url="https://github.com/mikefarah/yq/releases/latest/download/$yq_binary"
            if download_file "$yq_url" "/tmp/yq" && chmod +x /tmp/yq && mv /tmp/yq /usr/local/bin/yq; then
                log "SUCCESS" "yq установлен через GitHub releases"
                return 0
            else
                log "ERROR" "Не удалось установить yq"
                return 1
            fi
        else
            log "ERROR" "yq необходим для управления конфигурацией MAS"
            log "INFO" "Установите вручную: snap install yq или apt install yq"
            return 1
        fi
    fi
    return 0
}

# Инициализация секции account
initialize_mas_account_section() {
    log "INFO" "Инициализация секции account в конфигурации MAS..."
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    # Проверяем, есть ли уже секция account
    if yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$account_content" != "null" ] && [ -n "$account_content" ]; then
            log "INFO" "Секция account уже существует"
            return 0
        fi
    fi
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_account_init"
    
    log "INFO" "Добавление секции account в конфигурацию MAS..."
    
    # Используем yq для добавления секции account
    if yq eval -i '.account = {
        "password_registration_enabled": false,
        "registration_token_required": false,
        "email_change_allowed": true,
        "displayname_change_allowed": true,
        "password_change_allowed": true,
        "password_recovery_enabled": false,
        "account_deactivation_allowed": false
    }' "$MAS_CONFIG_FILE" 2>/dev/null; then
        
        log "SUCCESS" "Секция account добавлена"
        
        # Проверяем валидность YAML
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                log "ERROR" "YAML поврежден после добавления секции account"
                # Восстанавливаем из резервной копии
                local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_account_init_* 2>/dev/null | head -1)
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    restore_file "$latest_backup" "$MAS_CONFIG_FILE"
                    log "INFO" "Конфигурация восстановлена из резервной копии"
                fi
                return 1
            fi
        fi
        
    else
        log "ERROR" "Не удалось добавить секцию account"
        return 1
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    log "SUCCESS" "Секция account успешно инициализирована"
    return 0
}

# Изменение параметра в YAML файле
set_mas_config_value() {
    local key="$1"
    local value="$2"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    if ! check_yq_dependency; then
        return 1
    fi
    
    local full_path=""
    case "$key" in
        "password_registration_enabled"|"registration_token_required"|"email_change_allowed"|"displayname_change_allowed"|"password_change_allowed"|"password_recovery_enabled"|"account_deactivation_allowed")
            full_path=".account.$key"
            
            # Проверяем наличие секции account и инициализируем при необходимости
            if ! yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
                log "WARN" "Секция account отсутствует, инициализирую..."
                if ! initialize_mas_account_section; then
                    log "ERROR" "Не удалось инициализировать секцию account"
                    return 1
                fi
            fi
            ;;
        *)
            log "ERROR" "Неизвестный параметр конфигурации: $key"
            return 1
            ;;
    esac
    
    log "INFO" "Изменение настройки $key на $value..."
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_change"
    
    # Применяем изменение
    if yq eval -i "$full_path = $value" "$MAS_CONFIG_FILE" 2>/dev/null; then
        log "SUCCESS" "Изменение применено"
        
        # Проверяем валидность YAML
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                log "ERROR" "YAML поврежден после изменений"
                # Восстанавливаем из резервной копии
                local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_change_* 2>/dev/null | head -1)
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    restore_file "$latest_backup" "$MAS_CONFIG_FILE"
                    log "INFO" "Конфигурация восстановлена из резервной копии"
                fi
                return 1
            fi
        fi
    else
        log "ERROR" "Не удалось изменить $key в $MAS_CONFIG_FILE"
        return 1
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    # Перезапускаем MAS
    log "INFO" "Перезапуск MAS для применения изменений..."
    if restart_service "matrix-auth-service"; then
        sleep 2
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "Настройка $key успешно изменена на $value"
            
            # Проверяем API если доступен
            local mas_port=""
            if [ -f "$CONFIG_DIR/mas.conf" ]; then
                mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
            fi
            
            if [ -n "$mas_port" ]; then
                local health_url="http://localhost:$mas_port/health"
                if curl -s -f --connect-timeout 5 "$health_url" >/dev/null 2>&1; then
                    log "SUCCESS" "MAS API доступен - настройки применены успешно"
                else
                    log "WARN" "MAS запущен, но API пока недоступен"
                fi
            fi
        else
            log "ERROR" "MAS не запустился после изменения конфигурации"
            return 1
        fi
    else
        log "ERROR" "Ошибка перезапуска matrix-auth-service"
        return 1
    fi
    
    return 0
}

# Просмотр секции account конфигурации MAS
view_mas_account_config() {
    print_header "КОНФИГУРАЦИЯ СЕКЦИИ ACCOUNT В MAS" "$CYAN"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    if ! check_yq_dependency; then
        return 1
    fi
    
    safe_echo "${BOLD}Текущая конфигурация секции account:${NC}"
    echo
    
    # Проверяем наличие секции account
    if ! yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        safe_echo "${RED}Секция account отсутствует в конфигурации MAS${NC}"
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Используйте пункты меню выше для включения настроек регистрации"
        safe_echo "• Секция account будет создана автоматически при первом изменении"
        return 1
    fi
    
    local account_content=$(yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$account_content" = "null" ] || [ -z "$account_content" ]; then
        safe_echo "${RED}Секция account пуста или повреждена${NC}"
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Попробуйте переинициализировать секцию через пункт '1. Включить открытую регистрацию'"
        return 1
    fi
    
    # Показываем основные параметры регистрации
    safe_echo "${CYAN}🔐 Настройки регистрации:${NC}"
    
    local password_reg=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$password_reg" = "true" ]; then
        safe_echo "  • password_registration_enabled: ${GREEN}true${NC} (открытая регистрация включена)"
    elif [ "$password_reg" = "false" ]; then
        safe_echo "  • password_registration_enabled: ${RED}false${NC} (открытая регистрация отключена)"
    else
        safe_echo "  • password_registration_enabled: ${YELLOW}$password_reg${NC}"
    fi
    
    local token_req=$(yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>/dev/null)
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
    safe_echo "  • email_change_allowed: ${BLUE}$email_change${NC}"
    
    local display_change=$(yq eval '.account.displayname_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • displayname_change_allowed: ${BLUE}$display_change${NC}"
    
    local password_change=$(yq eval '.account.password_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • password_change_allowed: ${BLUE}$password_change${NC}"
    
    local password_recovery=$(yq eval '.account.password_recovery_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • password_recovery_enabled: ${BLUE}$password_recovery${NC}"
    
    local account_deactivation=$(yq eval '.account.account_deactivation_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • account_deactivation_allowed: ${BLUE}$account_deactivation${NC}"
    
    echo
    safe_echo "${CYAN}📄 Полная секция account (YAML):${NC}"
    echo "────────────────────────────────────────────────────────────"
    
    # Показываем полную секцию account в YAML формате
    if yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null; then
        log "DEBUG" "Секция account успешно отображена"
    else
        safe_echo "${RED}Ошибка чтения секции account${NC}"
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
}

# Получение статуса открытой регистрации MAS
get_mas_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local status=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$status" = "true" ]; then
        echo "enabled"
    elif [ "$status" = "false" ]; then
        echo "disabled" 
    else
        echo "unknown"
    fi
}

# Получение статуса регистрации по токенам
get_mas_token_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local status=$(yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$status" = "true" ]; then
        echo "enabled"
    elif [ "$status" = "false" ]; then
        echo "disabled"
    else
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
    
    safe_echo "${BOLD}Параметры токена регистрации:${NC}"
    safe_echo "• ${BLUE}Кастомный токен${NC} - используйте свою строку или оставьте пустым для автогенерации"
    safe_echo "• ${BLUE}Лимит использований${NC} - количество раз, которое можно использовать токен"
    safe_echo "• ${BLUE}Срок действия${NC} - время жизни токена в секундах"
    echo
    
    # Параметры токена
    read -p "Введите кастомный токен (или оставьте пустым для автогенерации): " custom_token
    read -p "Лимит использований (или оставьте пустым для неограниченного): " usage_limit
    read -p "Срок действия в секундах (или оставьте пустым для бессрочного): " expires_in
    
    # Формируем команду
    local cmd="mas manage issue-user-registration-token --config $MAS_CONFIG_FILE"
    
    if [ -n "$custom_token" ]; then
        cmd="$cmd --token '$custom_token'"
    fi
    
    if [ -n "$usage_limit" ]; then
        if [[ ! "$usage_limit" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Лимит использований должен быть числом"
            return 1
        fi
        cmd="$cmd --usage-limit $usage_limit"
    fi
    
    if [ -n "$expires_in" ]; then
        if [[ ! "$expires_in" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Срок действия должен быть числом в секундах"
            return 1
        fi
        cmd="$cmd --expires-in $expires_in"
    fi
    
    log "INFO" "Создание токена регистрации..."
    log "DEBUG" "Команда: $cmd"
    
    # Выполняем команду как пользователь MAS
    local output
    if output=$(sudo -u "$MAS_USER" eval "$cmd" 2>&1); then
        log "SUCCESS" "Токен регистрации создан"
        echo
        safe_echo "${BOLD}${GREEN}Созданный токен:${NC}"
        safe_echo "${CYAN}$output${NC}"
        echo
        safe_echo "${YELLOW}📝 Сохраните этот токен - он больше не будет показан!${NC}"
        safe_echo "${BLUE}Передайте токен пользователю для регистрации${NC}"
    else
        log "ERROR" "Ошибка создания токена регистрации"
        log "ERROR" "Вывод: $output"
        echo
        safe_echo "${YELLOW}Возможные причины ошибки:${NC}"
        safe_echo "• MAS не запущен (проверьте: systemctl status matrix-auth-service)"
        safe_echo "• Проблемы с базой данных"
        safe_echo "• Недостаточные права пользователя $MAS_USER"
        safe_echo "• Проблемы с конфигурацией MAS"
        return 1
    fi
}

# Показ информации о токенах
show_registration_tokens_info() {
    print_header "ИНФОРМАЦИЯ О ТОКЕНАХ РЕГИСТРАЦИИ" "$CYAN"
    
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
}

# Управление токенами регистрации MAS
manage_mas_registration_tokens() {
    print_header "УПРАВЛЕНИЕ ТОКЕНАМИ РЕГИСТРАЦИИ MAS" "$BLUE"
    
    # Проверка наличия yq
    if ! check_yq_dependency; then
        read -p "Нажмите Enter для возврата..."
        return 1
    fi
    
    # Проверяем, что MAS запущен
    if ! systemctl is-active --quiet matrix-auth-service; then
        log "WARN" "Matrix Authentication Service не запущен"
        log "INFO" "Для создания токенов MAS должен быть запущен"
        if ask_confirmation "Попробовать запустить MAS?"; then
            if restart_service "matrix-auth-service"; then
                sleep 2
                if systemctl is-active --quiet matrix-auth-service; then
                    log "SUCCESS" "MAS успешно запущен"
                else
                    log "ERROR" "Не удалось запустить MAS"
                    read -p "Нажмите Enter для возврата..."
                    return 1
                fi
            else
                log "ERROR" "Ошибка запуска MAS"
                read -p "Нажмите Enter для возврата..."
                return 1
            fi
        else
            read -p "Нажмите Enter для возврата..."
            return 1
        fi
    fi

    while true; do
        # Показываем текущий статус токенов
        local token_status=$(get_mas_token_registration_status)
        
        safe_echo "Текущий статус:"
        case "$token_status" in
            "enabled") safe_echo "• Токены регистрации: ${GREEN}ТРЕБУЮТСЯ${NC}" ;;
            "disabled") safe_echo "• Токены регистрации: ${RED}НЕ ТРЕБУЮТСЯ${NC}" ;;
            *) safe_echo "• Токены регистрации: ${YELLOW}НЕИЗВЕСТНО${NC}" ;;
        esac
        
        # Показываем статус MAS
        if systemctl is-active --quiet matrix-auth-service; then
            safe_echo "• MAS служба: ${GREEN}АКТИВНА${NC}"
        else
            safe_echo "• MAS служба: ${RED}НЕ АКТИВНА${NC}"
        fi
        
        echo
        safe_echo "${BOLD}Управление токенами регистрации:${NC}"
        safe_echo "1. ${GREEN}✅ Включить требование токенов регистрации${NC}"
        safe_echo "2. ${RED}❌ Отключить требование токенов регистрации${NC}"
        safe_echo "3. ${BLUE}🎫 Создать новый токен регистрации${NC}"
        safe_echo "4. ${CYAN}ℹ️  Показать информацию о токенах${NC}"
        safe_echo "5. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-5]: " action

        case $action in
            1)
                set_mas_config_value "registration_token_required" "true"
                ;;
            2)
                set_mas_config_value "registration_token_required" "false"
                ;;
            3)
                create_registration_token
                ;;
            4)
                show_registration_tokens_info
                ;;
            5)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 5 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Меню управления регистрацией MAS
manage_mas_registration() {
    print_header "УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ MATRIX AUTHENTICATION SERVICE" "$BLUE"

    if ! check_yq_dependency; then
        read -p "Нажмите Enter для возврата..."
        return 1
    fi
    
    # Проверяем существование конфигурационного файла
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "INFO" "Убедитесь, что MAS установлен и настроен"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    while true; do
        # Показываем текущий статус
        local current_status=$(get_mas_registration_status)
        local token_status=$(get_mas_token_registration_status)
        
        safe_echo "${BOLD}Текущий статус регистрации:${NC}"
        case "$current_status" in
            "enabled") safe_echo "• Открытая регистрация: ${GREEN}ВКЛЮЧЕНА${NC}" ;;
            "disabled") safe_echo "• Открытая регистрация: ${RED}ОТКЛЮЧЕНА${NC}" ;;
            *) safe_echo "• Открытая регистрация: ${YELLOW}НЕИЗВЕСТНО${NC}" ;;
        esac
        
        case "$token_status" in
            "enabled") safe_echo "• Регистрация по токенам: ${GREEN}ТРЕБУЕТСЯ${NC}" ;;
            "disabled") safe_echo "• Регистрация по токенам: ${RED}НЕ ТРЕБУЕТСЯ${NC}" ;;
            *) safe_echo "• Регистрация по токенам: ${YELLOW}НЕИЗВЕСТНО${NC}" ;;
        esac
        
        # Показываем статус MAS
        if systemctl is-active --quiet matrix-auth-service; then
            safe_echo "• MAS служба: ${GREEN}АКТИВНА${NC}"
        else
            safe_echo "• MAS служба: ${RED}НЕ АКТИВНА${NC}"
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

        case $action in
            1)
                set_mas_config_value "password_registration_enabled" "true"
                ;;
            2)
                set_mas_config_value "password_registration_enabled" "false"
                ;;
            3)
                set_mas_config_value "registration_token_required" "true"
                ;;
            4)
                set_mas_config_value "registration_token_required" "false"
                ;;
            5)
                view_mas_account_config
                ;;
            6)
                manage_mas_registration_tokens
                ;;
            7)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
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
    # Проверяем, что MAS установлен
    if ! command -v mas >/dev/null 2>&1 && [ ! -f "$MAS_CONFIG_FILE" ]; then
        print_header "MATRIX AUTHENTICATION SERVICE НЕ УСТАНОВЛЕН" "$RED"
        log "ERROR" "Matrix Authentication Service не установлен"
        log "INFO" "Установите MAS через главное меню:"
        log "INFO" "  Дополнительные компоненты → Matrix Authentication Service (MAS)"
        return 1
    fi
    
    manage_mas_registration
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
