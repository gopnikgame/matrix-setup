#!/bin/bash

# Matrix Authentication Service (MAS) - Модуль управления заблокированными именами пользователей
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

# Проверка и инициализация структуры политики
initialize_policy_structure() {
    log "INFO" "Проверка структуры политики в конфигурации MAS..."
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_policy_init"
    
    # Инициализируем структуру если не существует
    if ! yq eval -i '.policy //= {}' "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось инициализировать секцию policy"
        return 1
    fi
    
    if ! yq eval -i '.policy.data //= {}' "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось инициализировать policy.data"
        return 1
    fi
    
    if ! yq eval -i '.policy.data.registration //= {}' "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось инициализировать policy.data.registration"
        return 1
    fi
    
    if ! yq eval -i '.policy.data.registration.banned_usernames //= {}' "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось инициализировать policy.data.registration.banned_usernames"
        return 1
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    log "SUCCESS" "Структура политики инициализирована"
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
sync_banned_usernames_changes() {
    log "INFO" "Применение изменений к заблокированным именам пользователей..."
    
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

# Показ текущих заблокированных имен
show_current_banned() {
    print_header "ТЕКУЩИЕ ЗАБЛОКИРОВАННЫЕ ИМЕНА" "$CYAN"
    
    local banned_literals=$(yq eval '.policy.data.registration.banned_usernames.literals[]' "$MAS_CONFIG_FILE" 2>/dev/null)
    local banned_substrings=$(yq eval '.policy.data.registration.banned_usernames.substrings[]' "$MAS_CONFIG_FILE" 2>/dev/null)
    local banned_regexes=$(yq eval '.policy.data.registration.banned_usernames.regexes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
    local banned_prefixes=$(yq eval '.policy.data.registration.banned_usernames.prefixes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
    local banned_suffixes=$(yq eval '.policy.data.registration.banned_usernames.suffixes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
    
    local has_banned=false
    
    if [ -n "$banned_literals" ] && [ "$banned_literals" != "null" ]; then
        safe_echo "${BOLD}${RED}🔒 Точные имена (literals):${NC}"
        echo "$banned_literals" | while read -r name; do
            [ -n "$name" ] && safe_echo "  • ${RED}$name${NC}"
        done
        echo
        has_banned=true
    fi
    
    if [ -n "$banned_substrings" ] && [ "$banned_substrings" != "null" ]; then
        safe_echo "${BOLD}${YELLOW}🔍 Подстроки (substrings):${NC}"
        echo "$banned_substrings" | while read -r substring; do
            [ -n "$substring" ] && safe_echo "  • ${YELLOW}*$substring*${NC}"
        done
        echo
        has_banned=true
    fi
    
    if [ -n "$banned_regexes" ] && [ "$banned_regexes" != "null" ]; then
        safe_echo "${BOLD}${MAGENTA}📝 Регулярные выражения (regexes):${NC}"
        echo "$banned_regexes" | while read -r regex; do
            [ -n "$regex" ] && safe_echo "  • ${MAGENTA}$regex${NC}"
        done
        echo
        has_banned=true
    fi
    
    if [ -n "$banned_prefixes" ] && [ "$banned_prefixes" != "null" ]; then
        safe_echo "${BOLD}${BLUE}🔰 Префиксы (prefixes):${NC}"
        echo "$banned_prefixes" | while read -r prefix; do
            [ -n "$prefix" ] && safe_echo "  • ${BLUE}$prefix*${NC}"
        done
        echo
        has_banned=true
    fi
    
    if [ -n "$banned_suffixes" ] && [ "$banned_suffixes" != "null" ]; then
        safe_echo "${BOLD}${CYAN}🔚 Суффиксы (suffixes):${NC}"
        echo "$banned_suffixes" | while read -r suffix; do
            [ -n "$suffix" ] && safe_echo "  • ${CYAN}*$suffix${NC}"
        done
        echo
        has_banned=true
    fi
    
    if [ "$has_banned" = false ]; then
        safe_echo "${GREEN}✅ Заблокированные имена пользователей не настроены${NC}"
        echo
        safe_echo "${BLUE}ℹ️  Все пользователи могут регистрироваться с любыми именами${NC}"
        safe_echo "${BLUE}   (при условии, что регистрация включена)${NC}"
    fi
}

# Добавление заблокированного имени
add_banned_username() {
    local type="$1"
    local type_name="$2"
    local path="$3"
    
    print_header "ДОБАВЛЕНИЕ $type_name" "$GREEN"
    
    # Показываем инструкцию для каждого типа
    case "$type" in
        "literal")
            safe_echo "${BOLD}Точные имена (literals):${NC}"
            safe_echo "• Блокируют точное совпадение с именем пользователя"
            safe_echo "• Пример: 'admin' заблокирует только 'admin'"
            ;;
        "substring")
            safe_echo "${BOLD}Подстроки (substrings):${NC}"
            safe_echo "• Блокируют имена, содержащие указанную подстроку"
            safe_echo "• Пример: 'admin' заблокирует 'admin', 'administrator', 'myadmin'"
            ;;
        "regex")
            safe_echo "${BOLD}Регулярные выражения (regexes):${NC}"
            safe_echo "• Блокируют имена по паттерну регулярного выражения"
            safe_echo "• Пример: '^admin.*' заблокирует имена, начинающиеся с 'admin'"
            ;;
        "prefix")
            safe_echo "${BOLD}Префиксы (prefixes):${NC}"
            safe_echo "• Блокируют имена, начинающиеся с указанного префикса"
            safe_echo "• Пример: 'admin' заблокирует 'admin123', 'administrator'"
            ;;
        "suffix")
            safe_echo "${BOLD}Суффиксы (suffixes):${NC}"
            safe_echo "• Блокируют имена, заканчивающиеся указанным суффиксом"
            safe_echo "• Пример: 'admin' заблокирует 'myadmin', 'superadmin'"
            ;;
    esac
    
    echo
    read -p "Введите ${type_name,,}: " username
    
    if [ -z "$username" ]; then
        log "ERROR" "Имя не может быть пустым"
        return 1
    fi
    
    # Валидация для регулярных выражений
    if [ "$type" = "regex" ]; then
        log "INFO" "Проверка валидности регулярного выражения..."
        if ! echo "test" | grep -qE "$username" 2>/dev/null; then
            log "WARN" "Регулярное выражение может быть некорректным"
            if ! ask_confirmation "Продолжить добавление?"; then
                return 0
            fi
        fi
    fi
    
    # Проверяем, не существует ли уже такое значение
    local existing=$(yq eval ".policy.data.registration.banned_usernames.$path[]" "$MAS_CONFIG_FILE" 2>/dev/null | grep -x "$username" 2>/dev/null)
    if [ -n "$existing" ]; then
        log "WARN" "$type_name '$username' уже существует в списке заблокированных"
        return 0
    fi
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_banned_add"
    
    # Инициализируем структуру
    if ! initialize_policy_structure; then
        return 1
    fi
    
    # Инициализируем массив для конкретного типа
    yq eval -i ".policy.data.registration.banned_usernames.$path //= []" "$MAS_CONFIG_FILE"
    
    # Добавляем новое имя
    log "INFO" "Добавление $type_name '$username' в заблокированные..."
    if yq eval -i ".policy.data.registration.banned_usernames.$path += [\"$username\"]" "$MAS_CONFIG_FILE"; then
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        # Применяем изменения
        if sync_banned_usernames_changes; then
            log "SUCCESS" "$type_name '$username' добавлен в заблокированные"
        else
            log "ERROR" "Ошибка применения изменений"
            return 1
        fi
    else
        log "ERROR" "Не удалось добавить $type_name"
        return 1
    fi
}

# Удаление заблокированного имени
remove_banned_username() {
    local type="$1"
    local type_name="$2"
    local path="$3"
    
    print_header "УДАЛЕНИЕ $type_name" "$RED"
    
    # Показываем текущие значения этого типа
    local current_items=$(yq eval ".policy.data.registration.banned_usernames.$path[]" "$MAS_CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$current_items" ] || [ "$current_items" = "null" ]; then
        log "WARN" "Нет заблокированных $type_name для удаления"
        return 0
    fi
    
    safe_echo "${BOLD}Текущие заблокированные $type_name:${NC}"
    local counter=1
    echo "$current_items" | while read -r item; do
        if [ -n "$item" ]; then
            printf "%d. %s\n" "$counter" "$item"
            counter=$((counter + 1))
        fi
    done
    echo
    
    read -p "Введите $type_name для удаления: " username
    
    if [ -z "$username" ]; then
        log "ERROR" "Имя не может быть пустым"
        return 1
    fi
    
    # Проверяем, существует ли такое значение
    local existing=$(echo "$current_items" | grep -x "$username" 2>/dev/null)
    if [ -z "$existing" ]; then
        log "ERROR" "$type_name '$username' не найден в списке заблокированных"
        return 1
    fi
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_banned_remove"
    
    # Удаляем имя
    log "INFO" "Удаление $type_name '$username' из заблокированных..."
    if yq eval -i "del(.policy.data.registration.banned_usernames.$path[] | select(. == \"$username\"))" "$MAS_CONFIG_FILE"; then
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        # Применяем изменения
        if sync_banned_usernames_changes; then
            log "SUCCESS" "$type_name '$username' удален из заблокированных"
        else
            log "ERROR" "Ошибка применения изменений"
            return 1
        fi
    else
        log "ERROR" "Не удалось удалить $type_name"
        return 1
    fi
}

# Установка предустановленного набора заблокированных имен
set_default_banned_usernames() {
    print_header "УСТАНОВКА СТАНДАРТНОГО НАБОРА" "$YELLOW"
    
    safe_echo "${BOLD}Стандартный набор включает:${NC}"
    safe_echo "• ${RED}Системные имена:${NC} admin, root, system, etc."
    safe_echo "• ${YELLOW}Служебные адреса:${NC} postmaster, webmaster, abuse, etc."
    safe_echo "• ${BLUE}Тестовые имена:${NC} test, user, guest, etc."
    safe_echo "• ${MAGENTA}API и технические:${NC} api, www, ftp, etc."
    echo
    
    if ! ask_confirmation "Установить стандартный набор заблокированных имен?"; then
        return 0
    fi
    
    log "INFO" "Установка стандартного набора заблокированных имен..."
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_default_banned"
    
    # Инициализируем структуру
    if ! initialize_policy_structure; then
        return 1
    fi
    
    # Стандартный набор заблокированных имен
    local default_banned_json='
{
  "literals": ["admin", "root", "administrator", "system", "support", "help", "info", "mail", "postmaster", "hostmaster", "webmaster", "abuse", "noreply", "no-reply", "security", "test", "user", "guest", "api", "www", "ftp", "mx", "ns", "dns", "smtp", "pop", "imap", "matrix", "synapse", "element", "riot", "moderator", "mod", "bot", "service"],
  "substrings": ["admin", "root", "system", "matrix", "synapse"],
  "prefixes": ["admin-", "root-", "system-", "support-", "help-", "matrix-", "synapse-"],
  "suffixes": ["-admin", "-root", "-system", "-support", "-bot", "-service"],
  "regexes": ["^admin.*", "^root.*", "^system.*", ".*admin$", ".*root$", "^[0-9]+$"]
}'
    
    # Устанавливаем стандартные значения
    log "INFO" "Применение стандартного набора..."
    if echo "$default_banned_json" | yq eval -i '.policy.data.registration.banned_usernames = .' "$MAS_CONFIG_FILE"; then
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        # Применяем изменения
        if sync_banned_usernames_changes; then
            log "SUCCESS" "Стандартный набор заблокированных имен установлен"
            safe_echo
            safe_echo "${GREEN}✅ Установлено:${NC}"
            safe_echo "  • 34 точных имени"
            safe_echo "  • 5 подстрок"
            safe_echo "  • 7 префиксов"
            safe_echo "  • 6 суффиксов"
            safe_echo "  • 6 регулярных выражений"
        else
            log "ERROR" "Ошибка применения стандартного набора"
            return 1
        fi
    else
        log "ERROR" "Не удалось установить стандартный набор"
        return 1
    fi
}

# Полная очистка заблокированных имен
clear_all_banned_usernames() {
    print_header "ОЧИСТКА ВСЕХ ЗАБЛОКИРОВАННЫХ ИМЕН" "$RED"
    
    safe_echo "${RED}⚠️  ВНИМАНИЕ: Это действие удалит ВСЕ заблокированные имена!${NC}"
    safe_echo "${YELLOW}После очистки любые пользователи смогут регистрироваться с любыми именами.${NC}"
    echo
    
    if ask_confirmation "Вы уверены, что хотите удалить ВСЕ заблокированные имена?"; then
        # Создаем резервную копию
        backup_file "$MAS_CONFIG_FILE" "mas_config_clear_banned"
        
        log "INFO" "Удаление всех заблокированных имен..."
        
        # Удаляем всю секцию banned_usernames
        if yq eval -i 'del(.policy.data.registration.banned_usernames)' "$MAS_CONFIG_FILE"; then
            # Устанавливаем права
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
            chmod 600 "$MAS_CONFIG_FILE"
            
            # Применяем изменения
            if sync_banned_usernames_changes; then
                log "SUCCESS" "Все заблокированные имена удалены"
                safe_echo
                safe_echo "${GREEN}✅ Теперь пользователи могут регистрироваться с любыми именами${NC}"
                safe_echo "${BLUE}ℹ️  Резервная копия сохранена в $BACKUP_DIR${NC}"
            else
                log "ERROR" "Ошибка применения изменений"
                return 1
            fi
        else
            log "ERROR" "Не удалось очистить заблокированные имена"
            return 1
        fi
    else
        log "INFO" "Очистка отменена"
    fi
}

# Экспорт/импорт конфигурации заблокированных имен
export_banned_usernames() {
    print_header "ЭКСПОРТ ЗАБЛОКИРОВАННЫХ ИМЕН" "$BLUE"
    
    local export_file="${BACKUP_DIR}/banned_usernames_export_$(date '+%Y%m%d_%H%M%S').yaml"
    
    log "INFO" "Экспорт заблокированных имен в файл..."
    
    if yq eval '.policy.data.registration.banned_usernames' "$MAS_CONFIG_FILE" > "$export_file" 2>/dev/null; then
        log "SUCCESS" "Заблокированные имена экспортированы в: $export_file"
        safe_echo
        safe_echo "${BLUE}📄 Содержимое экспорта:${NC}"
        cat "$export_file"
    else
        log "ERROR" "Ошибка экспорта заблокированных имен"
        return 1
    fi
}

# Тестирование имени пользователя
test_username() {
    print_header "ТЕСТИРОВАНИЕ ИМЕНИ ПОЛЬЗОВАТЕЛЯ" "$CYAN"
    
    read -p "Введите имя пользователя для проверки: " test_name
    
    if [ -z "$test_name" ]; then
        log "ERROR" "Имя не может быть пустым"
        return 1
    fi
    
    log "INFO" "Проверка имени '$test_name' против всех правил блокировки..."
    
    local is_banned=false
    local ban_reason=""
    
    # Проверка точных имен
    local banned_literals=$(yq eval '.policy.data.registration.banned_usernames.literals[]' "$MAS_CONFIG_FILE" 2>/dev/null)
    if echo "$banned_literals" | grep -qx "$test_name" 2>/dev/null; then
        is_banned=true
        ban_reason="точное совпадение (literals)"
    fi
    
    # Проверка подстрок
    if [ "$is_banned" = false ]; then
        local banned_substrings=$(yq eval '.policy.data.registration.banned_usernames.substrings[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        while read -r substring; do
            if [ -n "$substring" ] && [[ "$test_name" == *"$substring"* ]]; then
                is_banned=true
                ban_reason="содержит подстроку '$substring' (substrings)"
                break
            fi
        done <<< "$banned_substrings"
    fi
    
    # Проверка префиксов
    if [ "$is_banned" = false ]; then
        local banned_prefixes=$(yq eval '.policy.data.registration.banned_usernames.prefixes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        while read -r prefix; do
            if [ -n "$prefix" ] && [[ "$test_name" == "$prefix"* ]]; then
                is_banned=true
                ban_reason="начинается с '$prefix' (prefixes)"
                break
            fi
        done <<< "$banned_prefixes"
    fi
    
    # Проверка суффиксов
    if [ "$is_banned" = false ]; then
        local banned_suffixes=$(yq eval '.policy.data.registration.banned_usernames.suffixes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        while read -r suffix; do
            if [ -n "$suffix" ] && [[ "$test_name" == *"$suffix" ]]; then
                is_banned=true
                ban_reason="заканчивается на '$suffix' (suffixes)"
                break
            fi
        done <<< "$banned_suffixes"
    fi
    
    # Проверка регулярных выражений
    if [ "$is_banned" = false ]; then
        local banned_regexes=$(yq eval '.policy.data.registration.banned_usernames.regexes[]' "$MAS_CONFIG_FILE" 2>/dev/null)
        while read -r regex; do
            if [ -n "$regex" ] && echo "$test_name" | grep -qE "$regex" 2>/dev/null; then
                is_banned=true
                ban_reason="соответствует регулярному выражению '$regex' (regexes)"
                break
            fi
        done <<< "$banned_regexes"
    fi
    
    echo
    if [ "$is_banned" = true ]; then
        safe_echo "${RED}❌ Имя '$test_name' ЗАБЛОКИРОВАНО${NC}"
        safe_echo "${YELLOW}Причина: $ban_reason${NC}"
    else
        safe_echo "${GREEN}✅ Имя '$test_name' РАЗРЕШЕНО${NC}"
        safe_echo "${BLUE}Пользователь может зарегистрироваться с этим именем${NC}"
    fi
}

# Управление заблокированными именами пользователей
manage_banned_usernames() {
    print_header "УПРАВЛЕНИЕ ЗАБЛОКИРОВАННЫМИ ИМЕНАМИ ПОЛЬЗОВАТЕЛЕЙ" "$BLUE"

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
        show_current_banned
        
        safe_echo "${BOLD}Управление заблокированными именами:${NC}"
        safe_echo "1. ➕ Добавить точное имя (literals)"
        safe_echo "2. ➕ Добавить подстроку (substrings)"
        safe_echo "3. ➕ Добавить регулярное выражение (regexes)"
        safe_echo "4. ➕ Добавить префикс (prefixes)"
        safe_echo "5. ➕ Добавить суффикс (suffixes)"
        safe_echo "6. ➖ Удалить точное имя"
        safe_echo "7. ➖ Удалить подстроку"
        safe_echo "8. ➖ Удалить регулярное выражение"
        safe_echo "9. ➖ Удалить префикс"
        safe_echo "10. ➖ Удалить суффикс"
        safe_echo "11. 📦 Установить стандартный набор"
        safe_echo "12. 🗑️  Очистить все заблокированные имена"
        safe_echo "13. 📤 Экспортировать конфигурацию"
        safe_echo "14. 🧪 Тестировать имя пользователя"
        safe_echo "15. ↩️  Назад"

        read -p "Выберите действие [1-15]: " action

        case $action in
            1) add_banned_username "literal" "ТОЧНОЕ ИМЯ" "literals" ;;
            2) add_banned_username "substring" "ПОДСТРОКУ" "substrings" ;;
            3) add_banned_username "regex" "РЕГУЛЯРНОЕ ВЫРАЖЕНИЕ" "regexes" ;;
            4) add_banned_username "prefix" "ПРЕФИКС" "prefixes" ;;
            5) add_banned_username "suffix" "СУФФИКС" "suffixes" ;;
            6) remove_banned_username "literal" "точное имя" "literals" ;;
            7) remove_banned_username "substring" "подстроку" "substrings" ;;
            8) remove_banned_username "regex" "регулярное выражение" "regexes" ;;
            9) remove_banned_username "prefix" "префикс" "prefixes" ;;
            10) remove_banned_username "suffix" "суффикс" "suffixes" ;;
            11) set_default_banned_usernames ;;
            12) clear_all_banned_usernames ;;
            13) export_banned_usernames ;;
            14) test_username ;;
            15) return 0 ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
        
        if [ $action -ne 15 ]; then
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
    
    manage_banned_usernames
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi