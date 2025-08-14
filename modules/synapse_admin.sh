#!/bin/bash

# Synapse Admin Module
# Matrix Setup & Management Tool v3.0
# Модуль установки и настройки Synapse Admin

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
SYNAPSE_ADMIN_DIR="/var/www/synapse-admin"
ADMIN_CONFIG_FILE="$SYNAPSE_ADMIN_DIR/config.json"
DOCKER_COMPOSE_FILE="$CONFIG_DIR/synapse-admin-docker-compose.yml"

# Проверка root прав
check_root

# Загрузка конфигурации
load_matrix_config() {
    if [ ! -f "$CONFIG_DIR/domain" ]; then
        log "ERROR" "Matrix домен не настроен. Сначала выполните установку Synapse"
        exit 1
    fi
    
    MATRIX_DOMAIN=$(cat "$CONFIG_DIR/domain" 2>/dev/null)
    MATRIX_SERVER_URL="https://$MATRIX_DOMAIN"
    
    # Загружаем admin домен если он существует
    if [ -f "$CONFIG_DIR/admin_domain" ]; then
        ADMIN_DOMAIN=$(cat "$CONFIG_DIR/admin_domain" 2>/dev/null)
    fi
    
    # Загружаем тип сервера
    load_server_type
    
    log "DEBUG" "Matrix домен: $MATRIX_DOMAIN"
    log "DEBUG" "Admin домен: ${ADMIN_DOMAIN:-не настроен}"
    log "DEBUG" "Тип сервера: ${SERVER_TYPE:-неопределен}"
    log "DEBUG" "Bind адрес: ${BIND_ADDRESS:-неопределен}"
}

# Проверка системных требований
check_requirements() {
    log "INFO" "Проверка системных требований..."
    
    # Проверяем интернет соединение
    if ! check_internet; then
        log "ERROR" "Отсутствует подключение к интернету"
        return 1
    fi
    
    # Проверяем, что Synapse запущен
    if ! check_service "matrix-synapse"; then
        log "ERROR" "Synapse не запущен. Запустите сначала Matrix Synapse"
        return 1
    fi
    
    # Проверяем доступность админ API в зависимости от типа сервера
    local api_url
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        # Для локальных установок проверяем напрямую
        api_url="http://localhost:8008/_synapse/admin/v1/server_version"
    else
        # Для хостинга используем внешний URL
        api_url="$MATRIX_SERVER_URL/_synapse/admin/v1/server_version"
    fi
    
    log "DEBUG" "Проверка доступности админ API: $api_url"
    
    if command -v curl >/dev/null 2>&1; then
        local response=$(curl -s -f "$api_url" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local version=$(echo "$response" | grep -o '"server_version":"[^"]*' | cut -d'"' -f4)
            log "SUCCESS" "Synapse Admin API доступен (версия: ${version:-неизвестна})"
        else
            log "WARN" "Synapse Admin API недоступен. Проверьте конфигурацию Synapse"
        fi
    fi
    
    return 0
}

# Получение последней версии Synapse Admin
get_latest_version() {
    log "INFO" "Получение информации о последней версии..."
    
    local api_url="https://api.github.com/repos/Awesome-Technologies/synapse-admin/releases/latest"
    local temp_file=$(mktemp)
    
    if ! download_file "$api_url" "$temp_file"; then
        log "ERROR" "Не удалось получить информацию о релизах"
        rm -f "$temp_file"
        return 1
    fi
    
    # Извлекаем информацию о релизе
    LATEST_VERSION=$(grep '"tag_name"' "$temp_file" | cut -d'"' -f4)
    LATEST_URL=$(grep '"browser_download_url".*\.tar\.gz"' "$temp_file" | cut -d'"' -f4)
    RELEASE_NOTES=$(grep '"body"' "$temp_file" | cut -d'"' -f4 | head -c 200)
    
    rm -f "$temp_file"
    
    if [ -z "$LATEST_VERSION" ] || [ -z "$LATEST_URL" ]; then
        log "ERROR" "Не удалось получить информацию о последней версии"
        return 1
    fi
    
    log "SUCCESS" "Последняя версия: $LATEST_VERSION"
    return 0
}

# Проверка текущей установленной версии
check_installed_version() {
    if [ -f "$SYNAPSE_ADMIN_DIR/package.json" ]; then
        INSTALLED_VERSION=$(grep '"version"' "$SYNAPSE_ADMIN_DIR/package.json" | cut -d'"' -f4)
        log "INFO" "Установленная версия: ${INSTALLED_VERSION:-неизвестна}"
    elif [ -f "$SYNAPSE_ADMIN_DIR/index.html" ]; then
        # Пытаемся найти версию в HTML
        INSTALLED_VERSION=$(grep -o 'version[^0-9]*[0-9]\+\.[0-9]\+\.[0-9]\+' "$SYNAPSE_ADMIN_DIR/index.html" | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
        log "INFO" "Установленная версия: ${INSTALLED_VERSION:-неизвестна}"
    else
        INSTALLED_VERSION=""
        log "INFO" "Synapse Admin не установлен"
    fi
}

# Установка Synapse Admin из готовой сборки
install_prebuilt() {
    print_header "УСТАНОВКА SYNAPSE ADMIN (ГОТОВАЯ СБОРКА)" "$GREEN"
    
    if ! get_latest_version; then
        return 1
    fi
    
    check_installed_version
    
    # Проверяем, нужно ли обновление
    if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
        log "INFO" "У вас установлена последняя версия ($LATEST_VERSION)"
        if ! ask_confirmation "Переустановить?"; then
            return 0
        fi
    fi
    
    log "INFO" "Создание резервной копии..."
    if [ -d "$SYNAPSE_ADMIN_DIR" ]; then
        backup_file "$SYNAPSE_ADMIN_DIR" "synapse-admin"
    fi
    
    log "INFO" "Создание директории для Synapse Admin..."
    mkdir -p "$SYNAPSE_ADMIN_DIR"
    cd "$SYNAPSE_ADMIN_DIR" || return 1
    
    log "INFO" "Загрузка Synapse Admin v$LATEST_VERSION..."
    local temp_file=$(mktemp)
    
    if ! download_file "$LATEST_URL" "$temp_file"; then
        log "ERROR" "Ошибка загрузки файла"
        return 1
    fi
    
    log "INFO" "Распаковка архива..."
    if ! tar -xzf "$temp_file" --strip-components=1; then
        log "ERROR" "Ошибка распаковки архива"
        rm -f "$temp_file"
        return 1
    fi
    
    rm -f "$temp_file"
    
    # Устанавливаем правильные права доступа
    chown -R www-data:www-data "$SYNAPSE_ADMIN_DIR" 2>/dev/null || true
    chmod -R 755 "$SYNAPSE_ADMIN_DIR"
    
    log "SUCCESS" "Synapse Admin v$LATEST_VERSION успешно установлен"
    return 0
}

# Установка через Docker
install_docker() {
    print_header "УСТАНОВКА SYNAPSE ADMIN (DOCKER)" "$BLUE"
    
    # Проверяем наличие Docker
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR" "Docker не установлен"
        if ask_confirmation "Установить Docker?"; then
            install_docker_engine
        else
            return 1
        fi
    fi
    
    # Проверяем наличие docker-compose
    if ! command -v docker-compose >/dev/null 2>&1; then
        log "ERROR" "Docker Compose не установлен"
        if ask_confirmation "Установить Docker Compose?"; then
            install_docker_compose
        else
            return 1
        fi
    fi
    
    # Определяем порты в зависимости от типа сервера
    local docker_ports
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        # Для локальных VPS привязываемся к 0.0.0.0 для доступа с хоста
        docker_ports="0.0.0.0:8080:80"
        log "INFO" "Настройка для локальной VPS - Synapse Admin будет доступен на всех интерфейсах"
    else
        # Для хостинга привязываемся только к localhost
        docker_ports="127.0.0.1:8080:80"
        log "INFO" "Настройка для хостинга - Synapse Admin будет доступен только локально"
    fi
    
    log "INFO" "Создание docker-compose конфигурации..."
    
    cat > "$DOCKER_COMPOSE_FILE" <<EOF
version: '3.8'

services:
  synapse-admin:
    image: awesometechnologies/synapse-admin:latest
    container_name: synapse-admin
    hostname: synapse-admin
    ports:
      - "$docker_ports"
    volumes:
      - "$ADMIN_CONFIG_FILE:/app/config.json:ro"
    restart: unless-stopped
    environment:
      - TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:80"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

networks:
  default:
    name: synapse-admin-network
EOF

    log "INFO" "Запуск Synapse Admin через Docker..."
    
    cd "$(dirname "$DOCKER_COMPOSE_FILE")" || return 1
    
    if docker-compose -f "$DOCKER_COMPOSE_FILE" up -d; then
        log "SUCCESS" "Synapse Admin запущен через Docker"
        
        if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
            log "INFO" "Доступен по адресу: http://${LOCAL_IP:-localhost}:8080"
            log "INFO" "Для доступа с хоста Proxmox используйте: http://${LOCAL_IP}:8080"
        else
            log "INFO" "Доступен по адресу: http://localhost:8080"
        fi
    else
        log "ERROR" "Ошибка запуска Docker контейнера"
        return 1
    fi
    
    return 0
}

# Установка Docker Engine
install_docker_engine() {
    log "INFO" "Установка Docker Engine..."
    
    # Обновляем пакеты
    apt-get update
    
    # Устанавливаем зависимости
    apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Добавляем официальный GPG ключ Docker
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Добавляем репозиторий
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Устанавливаем Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Запускаем и включаем Docker
    systemctl start docker
    systemctl enable docker
    
    log "SUCCESS" "Docker Engine установлен"
}

# Установка Docker Compose
install_docker_compose() {
    log "INFO" "Установка Docker Compose..."
    
    local compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    
    curl -L "https://github.com/docker/compose/releases/download/$compose_version/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # Создаем симлинк для удобства
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    log "SUCCESS" "Docker Compose установлен"
}

# Создание конфигурационного файла
create_config() {
    print_header "СОЗДАНИЕ КОНФИГУРАЦИИ SYNAPSE ADMIN" "$CYAN"
    
    echo
    safe_echo "${BOLD}${CYAN}Настройка ограничений homeserver:${NC}"
    safe_echo "1. Разрешить подключение к любому серверу"
    safe_echo "2. Ограничить только текущим сервером ($MATRIX_DOMAIN)"
    safe_echo "3. Настроить список разрешенных серверов"
    
    echo
    read -p "$(safe_echo "${YELLOW}Выберите вариант [1-3]: ${NC}")" restriction_choice
    
    local base_url_config=""
    
    case $restriction_choice in
        1)
            log "INFO" "Настройка без ограничений homeserver"
            base_url_config=""
            ;;
        2)
            log "INFO" "Ограничение только текущим сервером"
            base_url_config="\"restrictBaseUrl\": \"$MATRIX_SERVER_URL\","
            ;;
        3)
            log "INFO" "Настройка списка разрешенных серверов"
            
            # Запрашиваем у пользователя список серверов
            local allowed_servers
            while true; do
                read -p "$(safe_echo "${YELLOW}Введите разрешенные серверы (через запятую): ${NC}")" allowed_servers
                
                # Проверяем, что хотя бы один сервер введен
                if [ -n "$allowed_servers" ]; then
                    break
                fi
                
                echo "Список серверов не может быть пустым"
            done
            
            # Форматируем в массив
            IFS=',' read -r -a server_array <<< "$allowed_servers"
            
            # Генерируем конфиг
            local restrict_entries=""
            for server in "${server_array[@]}"; do
                server=$(echo "$server" | xargs) # Убираем пробелы
                restrict_entries+="\"$server\", "
            done
            
            # Убираем последнее ", "
            restrict_entries=${restrict_entries%, }
            
            base_url_config="\"restrictBaseUrl\": [$restrict_entries],"
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    # Создаем конфиг
    log "INFO" "Создание конфигурационного файла..."
    
    mkdir -p "$(dirname "$ADMIN_CONFIG_FILE")"
    
    cat > "$ADMIN_CONFIG_FILE" <<EOF
{
  $base_url_config
  "defaultTheme": "auto",
  "developmentMode": false,
  "locale": "ru"
}
EOF

    log "SUCCESS" "Конфигурационный файл создан: $ADMIN_CONFIG_FILE"
    
    return 0
}

# Показ главного меню
show_main_menu() {
    while true; do
        print_header "УПРАВЛЕНИЕ SYNAPSE ADMIN" "$MAGENTA"
        
        echo
        safe_echo "${BOLD}${CYAN}Доступные опции:${NC}"
        safe_echo "${GREEN}1.${NC} Установить Synapse Admin (готовая сборка)"
        safe_echo "${GREEN}2.${NC} Установить через Docker"
        safe_echo "${GREEN}3.${NC} Создать/изменить конфигурацию"
        safe_echo "${GREEN}4.${NC} Проверить статус"
        safe_echo "${GREEN}5.${NC} Тестировать доступность"
        safe_echo "${GREEN}6.${NC} Обновить до последней версии"
        safe_echo "${GREEN}7.${NC} Удалить Synapse Admin"
        safe_echo "${GREEN}8.${NC} Вернуться в главное меню"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию [1-8]: ${NC}")" choice
        
        case $choice in
            1)
                if check_requirements; then
                    install_prebuilt
                    read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                fi
                ;;
            2)
                if check_requirements; then
                    install_docker
                    read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                fi
                ;;
            3)
                create_config
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            4)
                check_status
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            5)
                test_accessibility
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            6)
                if check_requirements && get_latest_version; then
                    install_prebuilt
                    read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                fi
                ;;
            7)
                uninstall
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

# Проверка статуса установки
check_status() {
    print_header "СТАТУС SYNAPSE ADMIN" "$BLUE"
    
    echo
    safe_echo "${BOLD}${CYAN}Файлы установки:${NC}"
    
    if [ -d "$SYNAPSE_ADMIN_DIR" ]; then
        local size=$(du -sh "$SYNAPSE_ADMIN_DIR" 2>/dev/null | cut -f1)
        safe_echo "├─ Директория: ${GREEN}$SYNAPSE_ADMIN_DIR${NC} (${size:-неизвестно})"
        
        if [ -f "$SYNAPSE_ADMIN_DIR/index.html" ]; then
            safe_echo "├─ Основные файлы: ${GREEN}найдены${NC}"
        else
            safe_echo "├─ Основные файлы: ${RED}не найдены${NC}"
        fi
        
        check_installed_version
        if [ -n "$INSTALLED_VERSION" ]; then
            safe_echo "└─ Версия: ${GREEN}$INSTALLED_VERSION${NC}"
        else
            safe_echo "└─ Версия: ${YELLOW}неопределена${NC}"
        fi
    else
        safe_echo "└─ Директория: ${RED}не существует${NC}"
    fi
    
    echo
    safe_echo "${BOLD}${CYAN}Конфигурация:${NC}"
    
    if [ -f "$ADMIN_CONFIG_FILE" ]; then
        safe_echo "├─ Конфиг файл: ${GREEN}найден${NC}"
        safe_echo "└─ Путь: $ADMIN_CONFIG_FILE"
    else
        safe_echo "└─ Конфиг файл: ${YELLOW}не найден${NC}"
    fi
    
    echo
    safe_echo "${BOLD}${CYAN}Docker контейнер:${NC}"
    
    if command -v docker >/dev/null 2>&1; then
        local container_status=$(docker ps --filter "name=synapse-admin" --format "{{.Status}}" 2>/dev/null)
        
        if [ -n "$container_status" ]; then
            safe_echo "├─ Статус: ${GREEN}$container_status${NC}"
            
            local ports=$(docker port synapse-admin 2>/dev/null | grep "80/tcp")
            if [ -n "$ports" ]; then
                safe_echo "└─ Порты: ${GREEN}$ports${NC}"
            fi
        else
            safe_echo "└─ Статус: ${YELLOW}не запущен${NC}"
        fi
    else
        safe_echo "└─ Docker: ${YELLOW}не установлен${NC}"
    fi
    
    echo
}

# Тестирование доступности Synapse Admin
test_accessibility() {
    print_header "ТЕСТИРОВАНИЕ ДОСТУПНОСТИ SYNAPSE ADMIN" "$BLUE"
    
    log "INFO" "Запуск диагностики доступности..."
    
    # Проверяем локальную доступность
    echo
    safe_echo "${BOLD}${CYAN}Локальная доступность:${NC}"
    
    # Проверяем файлы
    if [ -d "$SYNAPSE_ADMIN_DIR" ] && [ -f "$SYNAPSE_ADMIN_DIR/index.html" ]; then
        safe_echo "├─ Файлы приложения: ${GREEN}найдены${NC}"
    else
        safe_echo "├─ Файлы приложения: ${RED}не найдены${NC}"
        safe_echo "└─ ${YELLOW}Рекомендация: Сначала установите Synapse Admin${NC}"
        return 1
    fi
    
    # Проверяем Docker контейнер
    if command -v docker >/dev/null 2>&1; then
        local container_running=$(docker ps --filter "name=synapse-admin" --format "{{.Names}}" 2>/dev/null)
        if [ -n "$container_running" ]; then
            safe_echo "├─ Docker контейнер: ${GREEN}запущен${NC}"
        else
            safe_echo "├─ Docker контейнер: ${YELLOW}не запущен${NC}"
        fi
    fi
    
    # Тестируем доступность
    echo
    safe_echo "${BOLD}${CYAN}Тестирование HTTP доступности:${NC}"
    
    local test_urls=("http://localhost:8080" "http://127.0.0.1:8080")
    local success_count=0
    local total_tests=0
    
    for url in "${test_urls[@]}"; do
        ((total_tests++))
        if command -v curl >/dev/null 2>&1; then
            local response_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null)
            if [[ "$response_code" == "200" ]] || [[ "$response_code" == "404" ]] || [[ "$response_code" == "302" ]]; then
                safe_echo "├─ $url: ${GREEN}доступен${NC} (HTTP $response_code)"
                ((success_count++))
            else
                safe_echo "├─ $url: ${RED}недоступен${NC} (HTTP ${response_code:-timeout})"
            fi
        else
            safe_echo "├─ $url: ${YELLOW}не проверен${NC} (curl не установлен)"
        fi
    done
    
    # Итоговый результат
    echo
    safe_echo "${BOLD}${CYAN}Результат диагностики:${NC}"
    
    if [ $success_count -gt 0 ]; then
        safe_echo "└─ Статус: ${GREEN}Synapse Admin работает корректно${NC} ($success_count/$total_tests тестов прошли)"
    else
        safe_echo "└─ Статус: ${RED}Требуется диагностика${NC} ($success_count/$total_tests тестов прошли)"
    fi
    
    return 0
}

# Удаление Synapse Admin
uninstall() {
    print_header "УДАЛЕНИЕ SYNAPSE ADMIN" "$RED"
    
    log "WARN" "Это действие удалит все файлы Synapse Admin"
    
    if ! ask_confirmation "Вы уверены, что хотите удалить Synapse Admin?"; then
        log "INFO" "Операция отменена"
        return 0
    fi
    
    # Останавливаем Docker контейнер
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        log "INFO" "Остановка Docker контейнера..."
        docker-compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true
        rm -f "$DOCKER_COMPOSE_FILE"
    fi
    
    # Удаляем файлы
    if [ -d "$SYNAPSE_ADMIN_DIR" ]; then
        log "INFO" "Создание резервной копии перед удалением..."
        backup_file "$SYNAPSE_ADMIN_DIR" "synapse-admin-before-removal"
        
        log "INFO" "Удаление файлов..."
        rm -rf "$SYNAPSE_ADMIN_DIR"
    fi
    
    # Удаляем сохраненный домен
    rm -f "$CONFIG_DIR/admin_domain"
    
    log "SUCCESS" "Synapse Admin удален"
}

# Главная функция модуля
main() {
    # Загружаем конфигурацию Matrix
    load_matrix_config
    
    # Создаем необходимые директории
    mkdir -p "$CONFIG_DIR"
    
    # Запускаем главное меню
    show_main_menu
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi