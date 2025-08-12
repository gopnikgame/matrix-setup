#!/bin/bash

# Registration Control Module
# Matrix Setup & Management Tool v3.0
# Модуль управления регистрацией пользователей

# Определение директории скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключение общей библиотеки
if [ -f "${SCRIPT_DIR}/../common/common_lib.sh" ]; then
    source "${SCRIPT_DIR}/../common/common_lib.sh"
else
    echo "ОШИБКА: Не найдена общая библиотека common_lib.sh"
    exit 1
fi

# Настройки модуля
CONFIG_DIR="/opt/matrix-install"
REGISTRATION_CONFIG="/etc/matrix-synapse/conf.d/registration.yaml"
HOMESERVER_CONFIG="/etc/matrix-synapse/homeserver.yaml"

# Проверка root прав
check_root

# Создание резервной копии конфигурации
backup_registration_config() {
    log "INFO" "Создание резервной копии конфигурации регистрации"
    
    if [ -f "$REGISTRATION_CONFIG" ]; then
        backup_file "$REGISTRATION_CONFIG" "registration"
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Резервная копия создана"
        else
            log "ERROR" "Ошибка создания резервной копии"
            return 1
        fi
    fi
    return 0
}

# Проверка статуса регистрации
check_registration_status() {
    print_header "ТЕКУЩИЙ СТАТУС РЕГИСТРАЦИИ" "$BLUE"
    
    if [ -f "$REGISTRATION_CONFIG" ]; then
        log "INFO" "Анализ текущей конфигурации..."
        
        # Проверяем enable_registration
        local enable_reg=$(grep "^enable_registration:" "$REGISTRATION_CONFIG" | awk '{print $2}')
        
        # Проверяем требования 3PID
        local require_email=$(grep -A 5 "registrations_require_3pid:" "$REGISTRATION_CONFIG" | grep "email")
        
        # Проверяем captcha
        local captcha_enabled="false"
        if grep -q "enable_registration_captcha:" "$HOMESERVER_CONFIG"; then
            captcha_enabled=$(grep "enable_registration_captcha:" "$HOMESERVER_CONFIG" | awk '{print $2}')
        fi
        
        # Проверяем token requirement
        local token_required="false"
        if grep -q "registration_requires_token:" "$HOMESERVER_CONFIG"; then
            token_required=$(grep "registration_requires_token:" "$HOMESERVER_CONFIG" | awk '{print $2}')
        fi
        
        # Проверяем guest access
        local guest_access="false"
        if grep -q "allow_guest_access:" "$HOMESERVER_CONFIG"; then
            guest_access=$(grep "allow_guest_access:" "$HOMESERVER_CONFIG" | awk '{print $2}')
        fi
        
        # Отображение статуса
        echo
        safe_echo "${BOLD}${CYAN}Параметры регистрации:${NC}"
        safe_echo "├─ Регистрация включена: ${enable_reg:-'не установлено'}"
        
        if [ -n "$require_email" ]; then
            safe_echo "├─ Требуется email: ${GREEN}да${NC}"
        else
            safe_echo "├─ Требуется email: ${RED}нет${NC}"
        fi
        
        safe_echo "├─ CAPTCHA включена: $captcha_enabled"
        safe_echo "├─ Требуются токены: $token_required"
        safe_echo "└─ Гостевой доступ: $guest_access"
        echo
    else
        log "WARN" "Конфигурационный файл регистрации не найден"
        safe_echo "${YELLOW}Конфигурация регистрации не настроена${NC}"
    fi
}

# Включение открытой регистрации
enable_open_registration() {
    print_header "ВКЛЮЧЕНИЕ ОТКРЫТОЙ РЕГИСТРАЦИИ" "$GREEN"
    
    log "WARN" "Внимание: Открытая регистрация может привести к спаму и злоупотреблениям"
    
    if ! ask_confirmation "Вы уверены, что хотите включить открытую регистрацию?"; then
        log "INFO" "Операция отменена пользователем"
        return 0
    fi
    
    backup_registration_config
    
    log "INFO" "Настройка открытой регистрации..."
    
    cat > "$REGISTRATION_CONFIG" <<EOL
# Registration Configuration - Open Registration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Включить регистрацию новых пользователей
enable_registration: true

# Разрешить регистрацию без проверки email
enable_registration_without_verification: true

# Отключить требования к 3PID (email/phone)
registrations_require_3pid: []

# Политика паролей
password_config:
  enabled: true
  policy:
    enabled: true
    minimum_length: 8
    require_digit: true
    require_symbol: false
    require_lowercase: true
    require_uppercase: false

# Настройки bcrypt (безопасность паролей)
bcrypt_rounds: 12
EOL

    # Отключаем captcha и token requirement в основном конфиге
    if grep -q "enable_registration_captcha:" "$HOMESERVER_CONFIG"; then
        sed -i 's/enable_registration_captcha: true/enable_registration_captcha: false/' "$HOMESERVER_CONFIG"
    fi
    
    if grep -q "registration_requires_token:" "$HOMESERVER_CONFIG"; then
        sed -i 's/registration_requires_token: true/registration_requires_token: false/' "$HOMESERVER_CONFIG"
    fi
    
    log "INFO" "Перезапуск Synapse..."
    if restart_service "matrix-synapse"; then
        log "SUCCESS" "Открытая регистрация успешно включена"
        log "WARN" "Рекомендуется настроить мониторинг новых регистраций"
    else
        log "ERROR" "Ошибка перезапуска службы"
        return 1
    fi
    
    return 0
}

# Настройка регистрации с email верификацией
enable_email_registration() {
    print_header "НАСТРОЙКА РЕГИСТРАЦИИ С EMAIL ВЕРИФИКАЦИЕЙ" "$YELLOW"
    
    log "INFO" "Для работы email верификации необходимо настроить SMTP"
    
    # Ввод SMTP параметров
    echo
    safe_echo "${BOLD}${CYAN}Настройка SMTP:${NC}"
    
    read -p "$(safe_echo "${YELLOW}SMTP хост (например: smtp.gmail.com): ${NC}")" SMTP_HOST
    if [ -z "$SMTP_HOST" ]; then
        log "ERROR" "SMTP хост не может быть пустым"
        return 1
    fi
    
    read -p "$(safe_echo "${YELLOW}SMTP порт (обычно 587 или 465): ${NC}")" SMTP_PORT
    SMTP_PORT=${SMTP_PORT:-587}
    
    read -p "$(safe_echo "${YELLOW}SMTP пользователь: ${NC}")" SMTP_USER
    if [ -z "$SMTP_USER" ]; then
        log "ERROR" "SMTP пользователь не может быть пустым"
        return 1
    fi
    
    read -s -p "$(safe_echo "${YELLOW}SMTP пароль: ${NC}")" SMTP_PASS
    echo
    if [ -z "$SMTP_PASS" ]; then
        log "ERROR" "SMTP пароль не может быть пустым"
        return 1
    fi
    
    read -p "$(safe_echo "${YELLOW}Email отправителя (например: noreply@yourdomain.com): ${NC}")" FROM_ADDR
    if [ -z "$FROM_ADDR" ]; then
        log "ERROR" "Email отправителя не может быть пустым"
        return 1
    fi
    
    # Дополнительные параметры
    echo
    safe_echo "${BOLD}${CYAN}Дополнительные настройки:${NC}"
    
    # TLS настройки
    if ask_confirmation "Использовать TLS/STARTTLS?"; then
        REQUIRE_TLS="true"
    else
        REQUIRE_TLS="false"
    fi
    
    # Captcha
    local ENABLE_CAPTCHA="false"
    if ask_confirmation "Включить CAPTCHA для дополнительной защиты?"; then
        ENABLE_CAPTCHA="true"
        log "INFO" "Для работы CAPTCHA необходимо настроить reCAPTCHA в основном конфиге"
    fi
    
    backup_registration_config
    
    log "INFO" "Создание конфигурации email регистрации..."
    
    cat > "$REGISTRATION_CONFIG" <<EOL
# Registration Configuration - Email Verification
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Включить регистрацию новых пользователей
enable_registration: true

# Требовать email для регистрации
registrations_require_3pid:
  - email

# Отключить регистрацию без верификации
enable_registration_without_verification: false

# Настройки email
email:
  smtp_host: '$SMTP_HOST'
  smtp_port: $SMTP_PORT
  smtp_user: '$SMTP_USER'
  smtp_pass: '$SMTP_PASS'
  require_transport_security: $REQUIRE_TLS
  notif_from: '$FROM_ADDR'
  
  # Дополнительные настройки email
  enable_notifs: true
  notif_for_new_users: true
  client_base_url: "https://element.yourdomain.com"
  validation_token_lifetime: "1h"
  
  # Настройки тем писем
  subjects:
    email_validation: "[Matrix] Подтвердите ваш email адрес"
    password_reset: "[Matrix] Сброс пароля"

# Политика паролей
password_config:
  enabled: true
  policy:
    enabled: true
    minimum_length: 10
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# Настройки bcrypt
bcrypt_rounds: 12

# Отключить гостевой доступ
allow_guest_access: false
EOL

    # Настройка captcha в основном конфиге
    if [ "$ENABLE_CAPTCHA" = "true" ]; then
        log "INFO" "Включение CAPTCHA в основной конфигурации..."
        
        # Проверяем, есть ли уже настройки captcha
        if ! grep -q "enable_registration_captcha:" "$HOMESERVER_CONFIG"; then
            echo "" >> "$HOMESERVER_CONFIG"
            echo "# CAPTCHA Configuration" >> "$HOMESERVER_CONFIG"
            echo "enable_registration_captcha: true" >> "$HOMESERVER_CONFIG"
            echo "# Необходимо настроить recaptcha_public_key и recaptcha_private_key" >> "$HOMESERVER_CONFIG"
        else
            sed -i 's/enable_registration_captcha: false/enable_registration_captcha: true/' "$HOMESERVER_CONFIG"
        fi
    fi
    
    # Отключаем token requirement
    if grep -q "registration_requires_token:" "$HOMESERVER_CONFIG"; then
        sed -i 's/registration_requires_token: true/registration_requires_token: false/' "$HOMESERVER_CONFIG"
    fi
    
    log "INFO" "Перезапуск Synapse..."
    if restart_service "matrix-synapse"; then
        log "SUCCESS" "Регистрация с email верификацией настроена"
        echo
        safe_echo "${BOLD}${GREEN}Важная информация:${NC}"
        safe_echo "• Пользователи должны будут подтвердить email при регистрации"
        safe_echo "• Настройте client_base_url в конфигурации под ваш домен"
        if [ "$ENABLE_CAPTCHA" = "true" ]; then
            safe_echo "• Не забудьте настроить reCAPTCHA ключи в homeserver.yaml"
        fi
    else
        log "ERROR" "Ошибка перезапуска службы"
        return 1
    fi
    
    return 0
}

# Настройка регистрации по токенам
enable_token_registration() {
    print_header "НАСТРОЙКА РЕГИСТРАЦИИ ПО ТОКЕНАМ" "$MAGENTA"
    
    log "INFO" "Регистрация по токенам обеспечивает максимальную безопасность"
    log "INFO" "Только пользователи с валидными токенами смогут регистрироваться"
    
    backup_registration_config
    
    # Генерация секретного ключа для токенов
    local REGISTRATION_SECRET
    if [ -f "$CONFIG_DIR/secrets.conf" ] && grep -q "REGISTRATION_SHARED_SECRET" "$CONFIG_DIR/secrets.conf"; then
        REGISTRATION_SECRET=$(grep "REGISTRATION_SHARED_SECRET" "$CONFIG_DIR/secrets.conf" | cut -d'=' -f2 | tr -d '"')
        log "INFO" "Используется существующий секретный ключ"
    else
        REGISTRATION_SECRET=$(openssl rand -hex 32)
        log "INFO" "Сгенерирован новый секретный ключ для токенов"
        
        # Сохраняем секрет
        mkdir -p "$CONFIG_DIR"
        echo "REGISTRATION_SHARED_SECRET=\"$REGISTRATION_SECRET\"" >> "$CONFIG_DIR/secrets.conf"
    fi
    
    log "INFO" "Создание конфигурации регистрации по токенам..."
    
    cat > "$REGISTRATION_CONFIG" <<EOL
# Registration Configuration - Token Based
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Включить регистрацию новых пользователей
enable_registration: true

# Требовать токены для регистрации
registration_requires_token: true

# Отключить регистрацию без верификации
enable_registration_without_verification: false

# Отключить требования к email (опционально)
registrations_require_3pid: []

# Политика паролей (усиленная)
password_config:
  enabled: true
  policy:
    enabled: true
    minimum_length: 12
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# Настройки bcrypt
bcrypt_rounds: 14

# Отключить гостевой доступ
allow_guest_access: false

# Отключить открытую регистрацию
enable_registration_without_verification: false
EOL

    # Обновляем основной конфиг
    log "INFO" "Обновление основной конфигурации..."
    
    # Добавляем или обновляем настройки в homeserver.yaml
    if ! grep -q "registration_requires_token:" "$HOMESERVER_CONFIG"; then
        echo "" >> "$HOMESERVER_CONFIG"
        echo "# Token Registration" >> "$HOMESERVER_CONFIG"
        echo "registration_requires_token: true" >> "$HOMESERVER_CONFIG"
    else
        sed -i 's/registration_requires_token: false/registration_requires_token: true/' "$HOMESERVER_CONFIG"
    fi
    
    # Добавляем registration_shared_secret если его нет
    if ! grep -q "registration_shared_secret:" "$HOMESERVER_CONFIG"; then
        echo "registration_shared_secret: \"$REGISTRATION_SECRET\"" >> "$HOMESERVER_CONFIG"
    else
        sed -i "s/registration_shared_secret:.*/registration_shared_secret: \"$REGISTRATION_SECRET\"/" "$HOMESERVER_CONFIG"
    fi
    
    # Отключаем captcha
    if grep -q "enable_registration_captcha:" "$HOMESERVER_CONFIG"; then
        sed -i 's/enable_registration_captcha: true/enable_registration_captcha: false/' "$HOMESERVER_CONFIG"
    fi
    
    log "INFO" "Перезапуск Synapse..."
    if restart_service "matrix-synapse"; then
        log "SUCCESS" "Регистрация по токенам настроена"
        echo
        safe_echo "${BOLD}${GREEN}Управление токенами:${NC}"
        safe_echo "• Создание токена: synapse_admin create_registration_token"
        safe_echo "• Просмотр токенов: synapse_admin list_registration_tokens"
        safe_echo "• Удаление токена: synapse_admin delete_registration_token <token>"
        echo
        safe_echo "${BOLD}${YELLOW}Секретный ключ сохранен в: ${NC}$CONFIG_DIR/secrets.conf"
    else
        log "ERROR" "Ошибка перезапуска службы"
        return 1
    fi
    
    return 0
}

# Полное отключение регистрации
disable_registration() {
    print_header "ОТКЛЮЧЕНИЕ РЕГИСТРАЦИИ" "$RED"
    
    if ask_confirmation "Вы уверены, что хотите полностью отключить регистрацию?"; then
        backup_registration_config
        
        log "INFO" "Отключение регистрации новых пользователей..."
        
        cat > "$REGISTRATION_CONFIG" <<EOL
# Registration Configuration - Disabled
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Отключить регистрацию новых пользователей
enable_registration: false

# Отключить регистрацию без верификации
enable_registration_without_verification: false

# Отключить гостевой доступ
allow_guest_access: false

# Политика паролей (для существующих пользователей)
password_config:
  enabled: true
  policy:
    enabled: true
    minimum_length: 8
    require_digit: true
    require_symbol: false
    require_lowercase: true
    require_uppercase: false
EOL

        # Обновляем основной конфиг
        if grep -q "enable_registration:" "$HOMESERVER_CONFIG"; then
            sed -i 's/enable_registration: true/enable_registration: false/' "$HOMESERVER_CONFIG"
        fi
        
        if grep -q "registration_requires_token:" "$HOMESERVER_CONFIG"; then
            sed -i 's/registration_requires_token: true/registration_requires_token: false/' "$HOMESERVER_CONFIG"
        fi
        
        log "INFO" "Перезапуск Synapse..."
        if restart_service "matrix-synapse"; then
            log "SUCCESS" "Регистрация полностью отключена"
            log "INFO" "Новые пользователи могут быть созданы только администратором"
        else
            log "ERROR" "Ошибка перезапуска службы"
            return 1
        fi
    else
        log "INFO" "Операция отменена пользователем"
    fi
    
    return 0
}

# Настройка автоматического присоединения к комнатам
configure_auto_join() {
    print_header "НАСТРОЙКА АВТОМАТИЧЕСКОГО ПРИСОЕДИНЕНИЯ К КОМНАТАМ" "$CYAN"
    
    echo
    safe_echo "${YELLOW}Введите комнаты для автоматического присоединения новых пользователей:${NC}"
    safe_echo "${DIM}(Формат: #room:domain.com, по одной комнате на строку, пустая строка для завершения)${NC}"
    
    local auto_join_rooms=()
    local room
    
    while true; do
        read -p "$(safe_echo "${CYAN}Комната: ${NC}")" room
        
        if [ -z "$room" ]; then
            break
        fi
        
        # Простая валидация формата комнаты
        if [[ "$room" =~ ^#[^:]+:[^:]+\.[^:]+$ ]]; then
            auto_join_rooms+=("$room")
            log "INFO" "Добавлена комната: $room"
        else
            log "WARN" "Неверный формат комнаты: $room (ожидается #room:domain.com)"
        fi
    done
    
    if [ ${#auto_join_rooms[@]} -eq 0 ]; then
        log "INFO" "Комнаты не добавлены"
        return 0
    fi
    
    # Создаем/обновляем конфигурацию
    local AUTO_JOIN_CONFIG="/etc/matrix-synapse/conf.d/auto_join.yaml"
    
    log "INFO" "Создание конфигурации автоматического присоединения..."
    
    {
        echo "# Auto-join rooms configuration"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "auto_join_rooms:"
        for room in "${auto_join_rooms[@]}"; do
            echo "  - '$room'"
        done
        echo ""
        echo "# Автоматически создавать комнаты если они не существуют"
        echo "autocreate_auto_join_rooms: true"
        echo ""
        echo "# Настройки создаваемых комнат"
        echo "autocreate_auto_join_rooms_federated: true"
        echo "autocreate_auto_join_room_preset: public_chat"
    } > "$AUTO_JOIN_CONFIG"
    
    log "INFO" "Перезапуск Synapse..."
    if restart_service "matrix-synapse"; then
        log "SUCCESS" "Автоматическое присоединение к комнатам настроено"
        echo
        safe_echo "${BOLD}${GREEN}Настроенные комнаты:${NC}"
        for room in "${auto_join_rooms[@]}"; do
            safe_echo "• $room"
        done
    else
        log "ERROR" "Ошибка перезапуска службы"
        return 1
    fi
    
    return 0
}

# Показ главного меню
show_main_menu() {
    while true; do
        print_header "УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ ПОЛЬЗОВАТЕЛЕЙ" "$MAGENTA"
        
        # Показываем текущий статус
        check_registration_status
        
        echo
        safe_echo "${BOLD}${CYAN}Доступные опции:${NC}"
        safe_echo "${GREEN}1.${NC} Включить открытую регистрацию"
        safe_echo "${GREEN}2.${NC} Настроить регистрацию с email верификацией"
        safe_echo "${GREEN}3.${NC} Настроить регистрацию по токенам"
        safe_echo "${GREEN}4.${NC} Отключить регистрацию"
        safe_echo "${GREEN}5.${NC} Настроить автоматическое присоединение к комнатам"
        safe_echo "${GREEN}6.${NC} Показать статус регистрации"
        safe_echo "${GREEN}7.${NC} Восстановить из резервной копии"
        safe_echo "${GREEN}8.${NC} Вернуться в главное меню"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию [1-8]: ${NC}")" choice
        
        case $choice in
            1)
                enable_open_registration
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            2)
                enable_email_registration
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            3)
                enable_token_registration
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            4)
                disable_registration
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            5)
                configure_auto_join
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            6)
                check_registration_status
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            7)
                restore_registration_config
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            8)
                log "INFO" "Возврат в главное меню"
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Попробуйте снова"
                sleep 2
                ;;
        esac
    done
}

# Восстановление конфигурации из резервной копии
restore_registration_config() {
    print_header "ВОССТАНОВЛЕНИЕ КОНФИГУРАЦИИ РЕГИСТРАЦИИ" "$YELLOW"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log "ERROR" "Директория резервных копий не найдена: $BACKUP_DIR"
        return 1
    fi
    
    # Поиск резервных копий
    local backups=($(find "$BACKUP_DIR" -name "registration_*.bak" -type f | sort -r))
    
    if [ ${#backups[@]} -eq 0 ]; then
        log "ERROR" "Резервные копии конфигурации регистрации не найдены"
        return 1
    fi
    
    echo
    safe_echo "${BOLD}${CYAN}Доступные резервные копии:${NC}"
    
    for i in "${!backups[@]}"; do
        local backup_file=$(basename "${backups[i]}")
        local backup_date=$(echo "$backup_file" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
        local formatted_date=$(echo "$backup_date" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
        
        safe_echo "${GREEN}$((i+1)).${NC} $backup_file (${formatted_date})"
    done
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите резервную копию для восстановления [1-${#backups[@]}]: ${NC}")" choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
        local selected_backup="${backups[$((choice-1))]}"
        
        log "INFO" "Восстановление из резервной копии: $(basename "$selected_backup")"
        
        if ask_confirmation "Вы уверены, что хотите восстановить конфигурацию?"; then
            # Создаем резервную копию текущей конфигурации
            backup_registration_config
            
            # Восстанавливаем из выбранной копии
            if restore_file "$selected_backup" "$REGISTRATION_CONFIG"; then
                log "INFO" "Перезапуск Synapse..."
                if restart_service "matrix-synapse"; then
                    log "SUCCESS" "Конфигурация успешно восстановлена"
                else
                    log "ERROR" "Ошибка перезапуска службы"
                    return 1
                fi
            else
                log "ERROR" "Ошибка восстановления конфигурации"
                return 1
            fi
        else
            log "INFO" "Операция отменена пользователем"
        fi
    else
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    return 0
}

# Главная функция модуля
main() {
    # Проверяем, что Synapse установлен
    if ! command -v synctl &>/dev/null; then
        log "ERROR" "Matrix Synapse не установлен"
        exit 1
    fi
    
    # Проверяем, что служба Synapse запущена
    if ! check_service "matrix-synapse"; then
        log "WARN" "Служба matrix-synapse не запущена"
        if ask_confirmation "Запустить службу matrix-synapse?"; then
            systemctl start matrix-synapse
            sleep 2
            if ! check_service "matrix-synapse"; then
                log "ERROR" "Не удалось запустить службу matrix-synapse"
                exit 1
            fi
        else
            log "ERROR" "Для работы модуля необходима запущенная служба Synapse"
            exit 1
        fi
    fi
    
    # Создаем необходимые директории
    mkdir -p "$(dirname "$REGISTRATION_CONFIG")"
    mkdir -p "$CONFIG_DIR"
    
    # Запускаем главное меню
    show_main_menu
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi