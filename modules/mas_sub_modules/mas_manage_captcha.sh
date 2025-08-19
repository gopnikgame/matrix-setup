#!/bin/bash

# Matrix Authentication Service (MAS) - Модуль управления CAPTCHA
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

# Получение статуса CAPTCHA
get_mas_captcha_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local service=$(yq eval '.captcha.service' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$service" = "null" ] || [ "$service" = "~" ] || [ -z "$service" ]; then
        echo "disabled"
    else
        echo "$service"
    fi
}

# Установка CAPTCHA конфигурации
set_mas_captcha_config() {
    local service="$1"
    local site_key="$2"
    local secret_key="$3"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    if ! check_yq_dependency; then
        return 1
    fi
    
    log "INFO" "Настройка CAPTCHA сервиса $service..."
    
    # Создаем резервную копию
    backup_file "$MAS_CONFIG_FILE" "mas_config_captcha"
    
    # Устанавливаем сервис
    if [ "$service" = "disabled" ]; then
        log "INFO" "Отключение CAPTCHA..."
        yq eval -i '.captcha.service = null' "$MAS_CONFIG_FILE"
        yq eval -i 'del(.captcha.site_key)' "$MAS_CONFIG_FILE"
        yq eval -i 'del(.captcha.secret_key)' "$MAS_CONFIG_FILE"
        
        # Если секция captcha пустая, удаляем её полностью
        local captcha_content=$(yq eval '.captcha' "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$captcha_content" = "{}" ] || [ "$captcha_content" = "null" ]; then
            yq eval -i 'del(.captcha)' "$MAS_CONFIG_FILE"
        fi
    else
        log "INFO" "Настройка CAPTCHA провайдера: $service"
        yq eval -i '.captcha.service = "'"$service"'"' "$MAS_CONFIG_FILE"
        yq eval -i '.captcha.site_key = "'"$site_key"'"' "$MAS_CONFIG_FILE"
        yq eval -i '.captcha.secret_key = "'"$secret_key"'"' "$MAS_CONFIG_FILE"
    fi
    
    # Устанавливаем права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
    chmod 600 "$MAS_CONFIG_FILE"
    
    # Проверяем валидность YAML
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "YAML файл поврежден после изменений, восстанавливаю резервную копию..."
            local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_captcha_* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                restore_file "$latest_backup" "$MAS_CONFIG_FILE"
                chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
                chmod 600 "$MAS_CONFIG_FILE"
                log "INFO" "Конфигурация восстановлена из резервной копии"
            fi
            return 1
        fi
    fi
    
    log "INFO" "Перезапуск MAS для применения изменений..."
    if restart_service "matrix-auth-service"; then
        # Ждем небольшую паузу для запуска службы
        sleep 2
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "CAPTCHA конфигурация успешно обновлена"
            
            # Проверяем API если доступен
            local mas_port=""
            if [ -f "$CONFIG_DIR/mas.conf" ]; then
                mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
            fi
            
            if [ -n "$mas_port" ]; then
                local health_url="http://localhost:$mas_port/health"
                if curl -s -f --connect-timeout 5 "$health_url" >/dev/null 2>&1; then
                    log "SUCCESS" "MAS API доступен - настройки CAPTCHA применены успешно"
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

# Проверка конфигурации провайдера CAPTCHA
validate_captcha_config() {
    local service="$1"
    local site_key="$2"
    local secret_key="$3"
    
    # Базовая валидация
    if [ -z "$site_key" ] || [ -z "$secret_key" ]; then
        log "ERROR" "Site Key и Secret Key не могут быть пустыми"
        return 1
    fi
    
    # Валидация по типу провайдера
    case "$service" in
        "recaptcha_v2")
            # Google reCAPTCHA v2 keys обычно начинаются с "6L"
            if [[ ! "$site_key" =~ ^6L.*$ ]]; then
                log "WARN" "Site Key для Google reCAPTCHA v2 обычно начинается с '6L'"
            fi
            ;;
        "cloudflare_turnstile")
            # Cloudflare Turnstile keys имеют определенный формат
            if [[ ${#site_key} -lt 30 ]]; then
                log "WARN" "Site Key для Cloudflare Turnstile кажется слишком коротким"
            fi
            ;;
        "hcaptcha")
            # hCaptcha keys имеют определенный формат
            if [[ ${#site_key} -lt 30 ]]; then
                log "WARN" "Site Key для hCaptcha кажется слишком коротким"
            fi
            ;;
    esac
    
    log "SUCCESS" "Конфигурация CAPTCHA прошла валидацию"
    return 0
}

# Показ информации о провайдере CAPTCHA
show_captcha_provider_info() {
    local service="$1"
    
    case "$service" in
        "recaptcha_v2")
            safe_echo "${BOLD}${CYAN}Google reCAPTCHA v2${NC}"
            safe_echo "• ${BLUE}Официальный сайт:${NC} https://www.google.com/recaptcha/"
            safe_echo "• ${BLUE}Консоль управления:${NC} https://www.google.com/recaptcha/admin"
            safe_echo "• ${BLUE}Особенности:${NC} Бесплатный, широко поддерживается"
            safe_echo "• ${BLUE}Лимиты:${NC} 1 млн запросов/месяц бесплатно"
            ;;
        "cloudflare_turnstile")
            safe_echo "${BOLD}${CYAN}Cloudflare Turnstile${NC}"
            safe_echo "• ${BLUE}Официальный сайт:${NC} https://www.cloudflare.com/products/turnstile/"
            safe_echo "• ${BLUE}Консоль управления:${NC} https://dash.cloudflare.com/"
            safe_echo "• ${BLUE}Особенности:${NC} Более приватный, без раздражающих задач"
            safe_echo "• ${BLUE}Лимиты:${NC} 1 млн вызовов/месяц бесплатно"
            ;;
        "hcaptcha")
            safe_echo "${BOLD}${CYAN}hCaptcha${NC}"
            safe_echo "• ${BLUE}Официальный сайт:${NC} https://www.hcaptcha.com/"
            safe_echo "• ${BLUE}Консоль управления:${NC} https://dashboard.hcaptcha.com/"
            safe_echo "• ${BLUE}Особенности:${NC} Фокус на приватности, можно зарабатывать"
            safe_echo "• ${BLUE}Лимиты:${NC} 1000 запросов/месяц бесплатно"
            ;;
    esac
}

# Тестирование конфигурации CAPTCHA
test_captcha_config() {
    local service="$1"
    
    log "INFO" "Тестирование конфигурации CAPTCHA..."
    
    # Проверяем, что MAS запущен
    if ! systemctl is-active --quiet matrix-auth-service; then
        log "ERROR" "Служба matrix-auth-service не запущена"
        return 1
    fi
    
    # Проверяем API MAS
    local mas_port=""
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        mas_port=$(grep "MAS_PORT=" "$CONFIG_DIR/mas.conf" | cut -d'=' -f2 | tr -d '"')
    fi
    
    if [ -n "$mas_port" ]; then
        local health_url="http://localhost:$mas_port/health"
        if curl -s -f --connect-timeout 5 "$health_url" >/dev/null 2>&1; then
            log "SUCCESS" "MAS API доступен"
            
            # Проверяем конфигурацию с помощью mas doctor
            if command -v mas >/dev/null 2>&1; then
                log "INFO" "Запуск диагностики MAS..."
                if sudo -u "$MAS_USER" mas doctor --config "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
                    log "SUCCESS" "Конфигурация MAS корректна"
                else
                    log "WARN" "MAS doctor обнаружил проблемы в конфигурации"
                fi
            fi
        else
            log "ERROR" "MAS API недоступен"
            return 1
        fi
    else
        log "WARN" "Не удалось определить порт MAS для тестирования"
    fi
    
    log "SUCCESS" "Тестирование CAPTCHA завершено"
    return 0
}

# Управление настройками CAPTCHA
manage_captcha_settings() {
    print_header "УПРАВЛЕНИЕ НАСТРОЙКАМИ CAPTCHA" "$BLUE"

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
        # Показываем текущий статус
        local current_status=$(get_mas_captcha_status)
        
        safe_echo "Текущий статус CAPTCHA:"
        case "$current_status" in
            "disabled"|"null") 
                safe_echo "• CAPTCHA: ${RED}ОТКЛЮЧЕНА${NC}" 
                ;;
            "recaptcha_v2") 
                safe_echo "• CAPTCHA: ${GREEN}Google reCAPTCHA v2${NC}"
                local site_key=$(yq eval '.captcha.site_key' "$MAS_CONFIG_FILE" 2>/dev/null)
                if [ -n "$site_key" ] && [ "$site_key" != "null" ]; then
                    safe_echo "• Site Key: ${CYAN}${site_key:0:20}...${NC}"
                fi
                ;;
            "cloudflare_turnstile") 
                safe_echo "• CAPTCHA: ${GREEN}Cloudflare Turnstile${NC}"
                local site_key=$(yq eval '.captcha.site_key' "$MAS_CONFIG_FILE" 2>/dev/null)
                if [ -n "$site_key" ] && [ "$site_key" != "null" ]; then
                    safe_echo "• Site Key: ${CYAN}${site_key:0:20}...${NC}"
                fi
                ;;
            "hcaptcha") 
                safe_echo "• CAPTCHA: ${GREEN}hCaptcha${NC}"
                local site_key=$(yq eval '.captcha.site_key' "$MAS_CONFIG_FILE" 2>/dev/null)
                if [ -n "$site_key" ] && [ "$site_key" != "null" ]; then
                    safe_echo "• Site Key: ${CYAN}${site_key:0:20}...${NC}"
                fi
                ;;
            "unknown") 
                safe_echo "• CAPTCHA: ${YELLOW}СТАТУС НЕИЗВЕСТЕН${NC}" 
                ;;
            *) 
                safe_echo "• CAPTCHA: ${YELLOW}$current_status${NC}" 
                ;;
        esac
        
        echo
        safe_echo "Доступные провайдеры CAPTCHA:"
        safe_echo "1. ${RED}❌ Отключить CAPTCHA${NC}"
        safe_echo "2. ${BLUE}🔵 Настроить Google reCAPTCHA v2${NC}"
        safe_echo "3. ${CYAN}☁️  Настроить Cloudflare Turnstile${NC}"
        safe_echo "4. ${GREEN}🛡️  Настроить hCaptcha${NC}"
        safe_echo "5. ${YELLOW}ℹ️  Информация о провайдерах${NC}"
        safe_echo "6. ${MAGENTA}🧪 Тестировать текущую конфигурацию${NC}"
        safe_echo "7. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-7]: " action

        case $action in
            1)
                log "INFO" "Отключение CAPTCHA..."
                set_mas_captcha_config "disabled" "" ""
                ;;
            2)
                print_header "НАСТРОЙКА GOOGLE reCAPTCHA v2" "$CYAN"
                show_captcha_provider_info "recaptcha_v2"
                echo
                safe_echo "${BOLD}Инструкции по настройке:${NC}"
                safe_echo "1. Перейдите на https://www.google.com/recaptcha/admin"
                safe_echo "2. Нажмите 'CREATE CREDENTIALS' → 'OAuth client ID'"
                safe_echo "3. Выберите 'reCAPTCHA v2' → 'I'm not a robot Checkbox'"
                safe_echo "4. Добавьте ваш домен в список разрешенных доменов"
                safe_echo "5. Скопируйте 'Site Key' и 'Secret Key'"
                echo
                read -p "Введите Site Key: " site_key
                read -p "Введите Secret Key: " secret_key
                
                if validate_captcha_config "recaptcha_v2" "$site_key" "$secret_key"; then
                    set_mas_captcha_config "recaptcha_v2" "$site_key" "$secret_key"
                fi
                ;;
            3)
                print_header "НАСТРОЙКА CLOUDFLARE TURNSTILE" "$CYAN"
                show_captcha_provider_info "cloudflare_turnstile"
                echo
                safe_echo "${BOLD}Инструкции по настройке:${NC}"
                safe_echo "1. Перейдите в Cloudflare Dashboard → Turnstile"
                safe_echo "2. Создайте новый сайт"
                safe_echo "3. Добавьте ваш домен"
                safe_echo "4. Выберите подходящий режим (Managed, Non-interactive, Invisible)"
                safe_echo "5. Скопируйте 'Site Key' и 'Secret Key'"
                echo
                read -p "Введите Site Key: " site_key
                read -p "Введите Secret Key: " secret_key
                
                if validate_captcha_config "cloudflare_turnstile" "$site_key" "$secret_key"; then
                    set_mas_captcha_config "cloudflare_turnstile" "$site_key" "$secret_key"
                fi
                ;;
            4)
                print_header "НАСТРОЙКА hCAPTCHA" "$CYAN"
                show_captcha_provider_info "hcaptcha"
                echo
                safe_echo "${BOLD}Инструкции по настройке:${NC}"
                safe_echo "1. Перейдите на https://dashboard.hcaptcha.com/"
                safe_echo "2. Создайте новый сайт"
                safe_echo "3. Добавьте ваш домен"
                safe_echo "4. Настройте уровень сложности (Easy, Moderate, Difficult)"
                safe_echo "5. Скопируйте 'Site Key' и 'Secret Key'"
                echo
                read -p "Введите Site Key: " site_key
                read -p "Введите Secret Key: " secret_key
                
                if validate_captcha_config "hcaptcha" "$site_key" "$secret_key"; then
                    set_mas_captcha_config "hcaptcha" "$site_key" "$secret_key"
                fi
                ;;
            5)
                print_header "ИНФОРМАЦИЯ О ПРОВАЙДЕРАХ CAPTCHA" "$YELLOW"
                safe_echo "${BOLD}Сравнение провайдеров CAPTCHA:${NC}"
                echo
                show_captcha_provider_info "recaptcha_v2"
                echo
                show_captcha_provider_info "cloudflare_turnstile"
                echo
                show_captcha_provider_info "hcaptcha"
                echo
                safe_echo "${BOLD}Рекомендации:${NC}"
                safe_echo "• ${GREEN}Google reCAPTCHA v2${NC} - проверенное решение с широкой поддержкой"
                safe_echo "• ${CYAN}Cloudflare Turnstile${NC} - современная альтернатива с фокусом на UX"
                safe_echo "• ${BLUE}hCaptcha${NC} - приватная альтернатива с возможностью монетизации"
                ;;
            6)
                test_captcha_config "$current_status"
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
    
    manage_captcha_settings
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi