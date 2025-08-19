#!/bin/bash

# Matrix Authentication Service (MAS) - Модуль управления SSO провайдерами
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

# Проверка валидности YAML после изменений
validate_yaml_config() {
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "YAML файл поврежден после изменений!"
            # Восстанавливаем из резервной копии
            local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                restore_file "$latest_backup" "$MAS_CONFIG_FILE"
                chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
                chmod 600 "$MAS_CONFIG_FILE"
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            return 1
        fi
    fi
    return 0
}

# Синхронизация изменений с MAS
sync_sso_changes() {
    log "INFO" "Применение изменений к SSO провайдерам..."
    
    # Проверяем валидность YAML
    if ! validate_yaml_config; then
        return 1
    fi
    
    # Перезапускаем MAS для применения изменений
    log "INFO" "Перезапуск MAS для применения изменений..."
    if restart_service "matrix-auth-service"; then
        sleep 2
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "Изменения успешно применены"
            
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
            log "ERROR" "MAS не запустился после изменений"
            return 1
        fi
    else
        log "ERROR" "Ошибка перезапуска matrix-auth-service"
        return 1
    fi
    
    return 0
}

# Генерация ULID для провайдеров
generate_ulid() {
    # Простая генерация ULID-подобного идентификатора
    local timestamp=$(printf '%010x' $(date +%s))
    local random_part=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')
    echo "${timestamp}${random_part}" | tr '[:lower:]' '[:upper:]' | head -c 26
}

# Функция для инициализации структуры upstream_oauth2
init_upstream_oauth2_structure() {
    log "INFO" "Инициализация структуры upstream_oauth2..."
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_sso_init"
    
    # Инициализируем структуру upstream_oauth2 если не существует
    if ! yq eval -i '.upstream_oauth2 //= {}' "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось инициализировать секцию upstream_oauth2"
        return 1
    fi
    
    if ! yq eval -i '.upstream_oauth2.providers //= []' "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось инициализировать массив providers"
        return 1
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    log "SUCCESS" "Структура upstream_oauth2 инициализирована"
    return 0
}

# Функция для проверки существования секции upstream_oauth2
check_upstream_oauth2_structure() {
    local upstream_section=$(yq eval '.upstream_oauth2' "$MAS_CONFIG_FILE" 2>/dev/null)
    local providers_section=$(yq eval '.upstream_oauth2.providers' "$MAS_CONFIG_FILE" 2>/dev/null)
    
    if [ "$upstream_section" = "null" ] || [ "$providers_section" = "null" ]; then
        log "WARN" "Секция upstream_oauth2 отсутствует или неполная, инициализирую..."
        if ! init_upstream_oauth2_structure; then
            return 1
        fi
    fi
    return 0
}

# Функция для валидации JSON провайдера
validate_provider_json() {
    local provider_json="$1"
    
    # Проверяем базовый JSON синтаксис
    if ! echo "$provider_json" | jq . >/dev/null 2>&1; then
        log "ERROR" "Неверный JSON синтаксис провайдера"
        return 1
    fi
    
    # Проверяем обязательные поля
    local required_fields=("id" "client_id" "client_secret" "scope")
    for field in "${required_fields[@]}"; do
        local value=$(echo "$provider_json" | jq -r ".$field" 2>/dev/null)
        if [ -z "$value" ] || [ "$value" = "null" ]; then
            log "ERROR" "Отсутствует обязательное поле: $field"
            return 1
        fi
    done
    
    # Проверяем формат ULID для ID (26 символов)
    local provider_id=$(echo "$provider_json" | jq -r '.id')
    if [ ${#provider_id} -ne 26 ]; then
        log "ERROR" "ID провайдера должен быть 26 символов (ULID формат)"
        return 1
    fi
    
    log "SUCCESS" "JSON провайдера прошел валидацию"
    return 0
}

# Функция для проверки существования провайдера
check_provider_exists() {
    local provider_id="$1"
    
    local existing_provider=$(yq eval ".upstream_oauth2.providers[] | select(.id == \"$provider_id\")" "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ -n "$existing_provider" ] && [ "$existing_provider" != "null" ]; then
        return 0  # Провайдер существует
    else
        return 1  # Провайдер не существует
    fi
}

# Получение списка провайдеров
list_sso_providers() {
    print_header "СПИСОК SSO ПРОВАЙДЕРОВ" "$CYAN"
    
    if ! check_upstream_oauth2_structure; then
        return 1
    fi
    
    local providers_count=$(yq eval '.upstream_oauth2.providers | length' "$MAS_CONFIG_FILE" 2>/dev/null)
    
    if [ "$providers_count" = "0" ] || [ "$providers_count" = "null" ]; then
        safe_echo "${YELLOW}SSO провайдеры не настроены${NC}"
        safe_echo "${BLUE}Используйте пункт 'Добавить провайдера' для настройки внешней аутентификации${NC}"
        return 0
    fi
    
    safe_echo "${BOLD}Настроенные SSO провайдеры (${GREEN}$providers_count${NC}${BOLD}):${NC}"
    echo
    
    # Получаем список провайдеров
    local provider_index=0
    while true; do
        local provider=$(yq eval ".upstream_oauth2.providers[$provider_index]" "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ "$provider" = "null" ] || [ -z "$provider" ]; then
            break
        fi
        
        local provider_id=$(echo "$provider" | yq eval '.id' - 2>/dev/null)
        local issuer=$(echo "$provider" | yq eval '.issuer // "неизвестно"' - 2>/dev/null)
        local client_id=$(echo "$provider" | yq eval '.client_id // "неизвестно"' - 2>/dev/null)
        local scope=$(echo "$provider" | yq eval '.scope // "неизвестно"' - 2>/dev/null)
        
        safe_echo "${BOLD}$((provider_index + 1)). Провайдер ${CYAN}$provider_id${NC}"
        safe_echo "   • Issuer: ${BLUE}$issuer${NC}"
        safe_echo "   • Client ID: ${GREEN}$client_id${NC}"
        safe_echo "   • Scope: ${YELLOW}$scope${NC}"
        echo
        
        provider_index=$((provider_index + 1))
    done
    
    safe_echo "${BOLD}Информация о конфигурации:${NC}"
    safe_echo "• Файл конфигурации: ${CYAN}$MAS_CONFIG_FILE${NC}"
    safe_echo "• Секция: ${YELLOW}upstream_oauth2.providers${NC}"
    safe_echo "• Применение изменений: перезапуск MAS"
}

# Добавление нового SSO провайдера
add_sso_provider() {
    print_header "ДОБАВЛЕНИЕ SSO ПРОВАЙДЕРА" "$GREEN"
    
    # Проверяем и инициализируем структуру
    if ! check_upstream_oauth2_structure; then
        return 1
    fi
    
    safe_echo "${BOLD}Добавление нового SSO провайдера${NC}"
    safe_echo "${BLUE}Введите параметры OAuth2/OIDC провайдера:${NC}"
    echo
    
    # Собираем информацию о провайдере
    read -p "Введите Issuer URL (например, https://accounts.google.com): " issuer_url
    if [ -z "$issuer_url" ]; then
        log "ERROR" "Issuer URL не может быть пустым"
        return 1
    fi
    
    read -p "Введите Client ID: " client_id
    if [ -z "$client_id" ]; then
        log "ERROR" "Client ID не может быть пустым"
        return 1
    fi
    
    read -p "Введите Client Secret: " client_secret
    if [ -z "$client_secret" ]; then
        log "ERROR" "Client Secret не может быть пустым"
        return 1
    fi
    
    read -p "Введите Scope (например, openid email profile): " scope
    if [ -z "$scope" ]; then
        scope="openid email profile"
        log "INFO" "Используется scope по умолчанию: $scope"
    fi
    
    # Дополнительные параметры
    read -p "Введите Claims Mapping для username (или оставьте пустым): " username_claim
    read -p "Введите Claims Mapping для email (или оставьте пустым): " email_claim
    read -p "Введите Claims Mapping для display name (или оставьте пустым): " displayname_claim
    
    # Генерируем уникальный ID
    local provider_id=$(generate_ulid)
    log "INFO" "Сгенерирован ID провайдера: $provider_id"
    
    # Создаем JSON структуру провайдера
    local provider_json="{
        \"id\": \"$provider_id\",
        \"issuer\": \"$issuer_url\",
        \"client_id\": \"$client_id\",
        \"client_secret\": \"$client_secret\",
        \"scope\": \"$scope\""
    
    # Добавляем дополнительные поля если указаны
    if [ -n "$username_claim" ]; then
        provider_json="$provider_json,
        \"claims\": {
            \"subject\": {
                \"template\": \"{{ user.$username_claim }}\"
            }"
        
        if [ -n "$email_claim" ]; then
            provider_json="$provider_json,
            \"email\": {
                \"template\": \"{{ user.$email_claim }}\"
            }"
        fi
        
        if [ -n "$displayname_claim" ]; then
            provider_json="$provider_json,
            \"displayname\": {
                \"template\": \"{{ user.$displayname_claim }}\"
            }"
        fi
        
        provider_json="$provider_json
        }"
    fi
    
    provider_json="$provider_json
    }"
    
    # Валидируем JSON
    if ! validate_provider_json "$provider_json"; then
        log "ERROR" "Ошибка валидации данных провайдера"
        return 1
    fi
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_add_provider"
    
    # Добавляем провайдера
    log "INFO" "Добавление провайдера в конфигурацию..."
    
    # Добавляем провайдера в массив
    if echo "$provider_json" | yq eval -i '.upstream_oauth2.providers += [.]' "$MAS_CONFIG_FILE"; then
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        # Применяем изменения
        if sync_sso_changes; then
            log "SUCCESS" "SSO провайдер успешно добавлен"
            safe_echo
            safe_echo "${GREEN}✅ Провайдер добавлен:${NC}"
            safe_echo "   • ID: ${CYAN}$provider_id${NC}"
            safe_echo "   • Issuer: ${BLUE}$issuer_url${NC}"
            safe_echo "   • Client ID: ${GREEN}$client_id${NC}"
            echo
            safe_echo "${YELLOW}📝 Следующие шаги:${NC}"
            safe_echo "1. Убедитесь, что в вашем OAuth2 провайдере настроен Redirect URI"
            safe_echo "2. Проверьте работу SSO через интерфейс MAS"
            safe_echo "3. Настройте дополнительные claims при необходимости"
        else
            log "ERROR" "Ошибка применения изменений"
            return 1
        fi
    else
        log "ERROR" "Не удалось добавить провайдера в конфигурацию"
        return 1
    fi
}

# Удаление SSO провайдера
remove_sso_provider() {
    print_header "УДАЛЕНИЕ SSO ПРОВАЙДЕРА" "$RED"
    
    if ! check_upstream_oauth2_structure; then
        return 1
    fi
    
    # Показываем список существующих провайдеров
    local providers_count=$(yq eval '.upstream_oauth2.providers | length' "$MAS_CONFIG_FILE" 2>/dev/null)
    
    if [ "$providers_count" = "0" ] || [ "$providers_count" = "null" ]; then
        log "WARN" "SSO провайдеры не настроены"
        return 0
    fi
    
    safe_echo "${BOLD}Существующие SSO провайдеры:${NC}"
    
    # Показываем список для выбора
    local provider_index=0
    local provider_ids=()
    
    while true; do
        local provider=$(yq eval ".upstream_oauth2.providers[$provider_index]" "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ "$provider" = "null" ] || [ -z "$provider" ]; then
            break
        fi
        
        local provider_id=$(echo "$provider" | yq eval '.id' - 2>/dev/null)
        local issuer=$(echo "$provider" | yq eval '.issuer // "неизвестно"' - 2>/dev/null)
        
        provider_ids+=("$provider_id")
        safe_echo "$((provider_index + 1)). ${CYAN}$provider_id${NC} (${BLUE}$issuer${NC})"
        
        provider_index=$((provider_index + 1))
    done
    
    if [ ${#provider_ids[@]} -eq 0 ]; then
        log "WARN" "Нет провайдеров для удаления"
        return 0
    fi
    
    echo
    read -p "Введите номер провайдера для удаления [1-${#provider_ids[@]}]: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#provider_ids[@]} ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_id="${provider_ids[$((choice-1))]}"
    
    safe_echo
    safe_echo "${RED}⚠️  ВНИМАНИЕ: Вы собираетесь удалить провайдера:${NC}"
    safe_echo "ID: ${CYAN}$selected_id${NC}"
    
    if ! ask_confirmation "Удалить этого провайдера?"; then
        log "INFO" "Удаление отменено"
        return 0
    fi
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_remove_provider"
    
    # Удаляем провайдера
    log "INFO" "Удаление провайдера $selected_id..."
    
    if yq eval -i "del(.upstream_oauth2.providers[] | select(.id == \"$selected_id\"))" "$MAS_CONFIG_FILE"; then
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        # Применяем изменения
        if sync_sso_changes; then
            log "SUCCESS" "SSO провайдер успешно удален"
        else
            log "ERROR" "Ошибка применения изменений"
            return 1
        fi
    else
        log "ERROR" "Не удалось удалить провайдера из конфигурации"
        return 1
    fi
}

# Просмотр конфигурации провайдера
view_provider_config() {
    print_header "ПРОСМОТР КОНФИГУРАЦИИ ПРОВАЙДЕРА" "$CYAN"
    
    if ! check_upstream_oauth2_structure; then
        return 1
    fi
    
    # Показываем список провайдеров для выбора
    local providers_count=$(yq eval '.upstream_oauth2.providers | length' "$MAS_CONFIG_FILE" 2>/dev/null)
    
    if [ "$providers_count" = "0" ] || [ "$providers_count" = "null" ]; then
        log "WARN" "SSO провайдеры не настроены"
        return 0
    fi
    
    safe_echo "${BOLD}Выберите провайдера для просмотра:${NC}"
    
    local provider_index=0
    local provider_ids=()
    
    while true; do
        local provider=$(yq eval ".upstream_oauth2.providers[$provider_index]" "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ "$provider" = "null" ] || [ -z "$provider" ]; then
            break
        fi
        
        local provider_id=$(echo "$provider" | yq eval '.id' - 2>/dev/null)
        local issuer=$(echo "$provider" | yq eval '.issuer // "неизвестно"' - 2>/dev/null)
        
        provider_ids+=("$provider_id")
        safe_echo "$((provider_index + 1)). ${CYAN}$provider_id${NC} (${BLUE}$issuer${NC})"
        
        provider_index=$((provider_index + 1))
    done
    
    echo
    read -p "Введите номер провайдера [1-${#provider_ids[@]}]: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#provider_ids[@]} ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_id="${provider_ids[$((choice-1))]}"
    
    # Показываем конфигурацию выбранного провайдера
    echo
    safe_echo "${BOLD}Конфигурация провайдера ${CYAN}$selected_id${NC}:${NC}"
    echo "────────────────────────────────────────────────────────────"
    
    yq eval ".upstream_oauth2.providers[] | select(.id == \"$selected_id\")" "$MAS_CONFIG_FILE" 2>/dev/null
    
    echo "────────────────────────────────────────────────────────────"
    
    # Дополнительная информация
    local provider_config=$(yq eval ".upstream_oauth2.providers[] | select(.id == \"$selected_id\")" "$MAS_CONFIG_FILE" 2>/dev/null)
    local issuer=$(echo "$provider_config" | yq eval '.issuer' - 2>/dev/null)
    local client_id=$(echo "$provider_config" | yq eval '.client_id' - 2>/dev/null)
    local scope=$(echo "$provider_config" | yq eval '.scope' - 2>/dev/null)
    
    echo
    safe_echo "${BOLD}Дополнительная информация:${NC}"
    safe_echo "• ${BLUE}Issuer URL:${NC} $issuer"
    safe_echo "• ${GREEN}Client ID:${NC} $client_id"
    safe_echo "• ${YELLOW}Scope:${NC} $scope"
    
    # Проверяем наличие custom claims
    local claims=$(echo "$provider_config" | yq eval '.claims' - 2>/dev/null)
    if [ "$claims" != "null" ] && [ -n "$claims" ]; then
        safe_echo "• ${MAGENTA}Custom Claims:${NC} настроены"
    else
        safe_echo "• ${MAGENTA}Custom Claims:${NC} не настроены"
    fi
}

# Информация о SSO провайдерах
show_sso_info() {
    print_header "ИНФОРМАЦИЯ О SSO ПРОВАЙДЕРАХ" "$YELLOW"
    
    safe_echo "${BOLD}Что такое SSO провайдеры в MAS?${NC}"
    safe_echo "SSO (Single Sign-On) провайдеры позволяют пользователям аутентифицироваться"
    safe_echo "через внешние OAuth2/OIDC сервисы вместо создания отдельного пароля."
    echo
    
    safe_echo "${BOLD}${GREEN}Поддерживаемые провайдеры:${NC}"
    safe_echo "• ${BLUE}Google${NC} - accounts.google.com"
    safe_echo "• ${CYAN}Microsoft${NC} - login.microsoftonline.com"
    safe_echo "• ${YELLOW}GitHub${NC} - github.com"
    safe_echo "• ${MAGENTA}Discord${NC} - discord.com"
    safe_echo "• ${GREEN}Keycloak${NC} - собственный сервер"
    safe_echo "• ${RED}Любой OAuth2/OIDC совместимый провайдер${NC}"
    echo
    
    safe_echo "${BOLD}${CYAN}Основные параметры:${NC}"
    safe_echo "• ${YELLOW}Issuer URL${NC} - базовый URL провайдера OAuth2/OIDC"
    safe_echo "• ${YELLOW}Client ID${NC} - идентификатор приложения у провайдера"
    safe_echo "• ${YELLOW}Client Secret${NC} - секретный ключ приложения"
    safe_echo "• ${YELLOW}Scope${NC} - запрашиваемые разрешения (openid, email, profile)"
    echo
    
    safe_echo "${BOLD}${BLUE}Примеры конфигурации:${NC}"
    echo
    safe_echo "${CYAN}Google:${NC}"
    safe_echo "  Issuer: https://accounts.google.com"
    safe_echo "  Scope: openid email profile"
    safe_echo "  Настройка: Google Cloud Console > APIs & Services > Credentials"
    echo
    safe_echo "${CYAN}Microsoft:${NC}"
    safe_echo "  Issuer: https://login.microsoftonline.com/common/v2.0"
    safe_echo "  Scope: openid email profile"
    safe_echo "  Настройка: Azure Portal > App registrations"
    echo
    safe_echo "${CYAN}GitHub:${NC}"
    safe_echo "  Issuer: https://github.com"
    safe_echo "  Scope: user:email"
    safe_echo "  Настройка: GitHub Settings > Developer settings > OAuth Apps"
    echo
    
    safe_echo "${BOLD}${RED}Важные моменты:${NC}"
    safe_echo "• ${YELLOW}Redirect URI${NC} должен быть настроен у провайдера"
    safe_echo "• ${YELLOW}Client Secret${NC} должен храниться в безопасности"
    safe_echo "• ${YELLOW}Scope${NC} должен включать необходимые разрешения"
    safe_echo "• ${YELLOW}Claims mapping${NC} может потребоваться для custom провайдеров"
    echo
    
    safe_echo "${BOLD}${GREEN}Redirect URI для MAS:${NC}"
    local mas_port=""
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
    fi
    local domain=$(hostname -f 2>/dev/null || hostname)
    
    if [ -n "$mas_port" ]; then
        safe_echo "http://$domain:$mas_port/upstream/callback/{provider_id}"
        safe_echo "https://$domain/upstream/callback/{provider_id} (если используется reverse proxy)"
    else
        safe_echo "http://$domain:8080/upstream/callback/{provider_id}"
        safe_echo "https://$domain/upstream/callback/{provider_id} (если используется reverse proxy)"
    fi
    
    echo
    safe_echo "${BLUE}где {provider_id} - это ID провайдера из конфигурации MAS${NC}"
}

# Управление SSO провайдерами
manage_sso_providers() {
    print_header "УПРАВЛЕНИЕ ВНЕШНИМИ ПРОВАЙДЕРАМИ (SSO)" "$BLUE"

    # Проверка наличия yq
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
        # Показываем текущее состояние
        local providers_count=$(yq eval '.upstream_oauth2.providers | length' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$providers_count" = "null" ]; then
            providers_count=0
        fi
        
        safe_echo "${BOLD}Текущее состояние SSO:${NC}"
        if [ "$providers_count" -gt 0 ]; then
            safe_echo "• SSO провайдеры: ${GREEN}$providers_count настроено${NC}"
        else
            safe_echo "• SSO провайдеры: ${YELLOW}не настроены${NC}"
        fi
        
        # Показываем статус MAS
        if systemctl is-active --quiet matrix-auth-service; then
            safe_echo "• MAS служба: ${GREEN}АКТИВНА${NC}"
        else
            safe_echo "• MAS служба: ${RED}НЕ АКТИВНА${NC}"
        fi
        
        echo
        safe_echo "${BOLD}Управление SSO провайдерами:${NC}"
        safe_echo "1. ${GREEN}➕ Добавить SSO провайдера${NC}"
        safe_echo "2. ${RED}➖ Удалить SSO провайдера${NC}"
        safe_echo "3. ${CYAN}📋 Список провайдеров${NC}"
        safe_echo "4. ${BLUE}👁️  Просмотр конфигурации провайдера${NC}"
        safe_echo "5. ${YELLOW}ℹ️  Информация о SSO провайдерах${NC}"
        safe_echo "6. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-6]: " action

        case $action in
            1)
                add_sso_provider
                ;;
            2)
                remove_sso_provider
                ;;
            3)
                list_sso_providers
                ;;
            4)
                view_provider_config
                ;;
            5)
                show_sso_info
                ;;
            6)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 6 ]; then
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
    
    manage_sso_providers
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi