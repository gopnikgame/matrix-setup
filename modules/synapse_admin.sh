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
ADMIN_CONFIG_FILE="$CONFIG_DIR/synapse-admin-config.json"
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

# Установку Synapse Admin из готовой сборки
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
    
    # Очищаем конфликтующие пути
    if ! clean_conflicting_paths; then
        log "ERROR" "Не удалось устранить конфликты путей"
        return 1
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
    
    # Создаем конфигурационный файл если он не существует
    if [ ! -f "$ADMIN_CONFIG_FILE" ]; then
        log "INFO" "Создание базового конфигурационного файла..."
        if ! create_config "auto"; then
            log "ERROR" "Не удалось создать конфигурацию"
            return 1
        fi
    fi
    
    # Устанавливаем правильные права доступа
    chown -R www-data:www-data "$SYNAPSE_ADMIN_DIR" 2>/dev/null || true
    chmod -R 755 "$SYNAPSE_ADMIN_DIR"
    
    log "SUCCESS" "Synapse Admin v$LATEST_VERSION успешно установлен"
    log "INFO" "Конфигурационный файл: $ADMIN_CONFIG_FILE"
    return 0
}

# Установка через Docker
install_docker() {
    print_header "УСТАНОВКА SYNAPSE ADMIN (DOCKER)" "$BLUE"
    
    # Проверяем и останавливаем существующие контейнеры
    if docker ps -q --filter "name=synapse-admin" >/dev/null 2>&1; then
        log "INFO" "Остановка существующего контейнера..."
        docker stop synapse-admin >/dev/null 2>&1 || true
    fi
    
    if docker ps -aq --filter "name=synapse-admin" >/dev/null 2>&1; then
        log "INFO" "Удаление старого контейнера..."
        docker rm synapse-admin >/dev/null 2>&1 || true
    fi
    
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
    
    # Проверяем Docker окружение
    if ! check_docker_environment; then
        log "ERROR" "Проблемы с Docker окружением"
        return 1
    fi
    
    # Очищаем конфликтующие пути
    if ! clean_conflicting_paths; then
        log "ERROR" "Не удалось устранить конфликты путей"
        return 1
    fi
    
    # Создаем конфигурационный файл если он не существует
    if [ ! -f "$ADMIN_CONFIG_FILE" ]; then
        log "INFO" "Создание базового конфигурационного файла..."
        if ! create_config "auto"; then
            log "ERROR" "Не удалось создать конфигурацию"
            return 1
        fi
    else
        log "INFO" "Используется существующий конфигурационный файл"
    fi
    
    # Проверяем корректность конфигурации
    if ! validate_config; then
        log "ERROR" "Некорректная конфигурация"
        return 1
    fi
    
    # Определяем порты в зависимости от типа сервера
    local docker_ports
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        # Для локальных VPS привязываем к 0.0.0.0 для доступа с хоста
        docker_ports="0.0.0.0:8080:80"
        log "INFO" "Настройка для локальной VPS - Synapse Admin будет доступен на всех интерфейсах"
    else
        # Для хостинга привязываем только к localhost
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
    
    # Пробуем запустить контейнер
    log "DEBUG" "Выполнение: docker-compose -f $DOCKER_COMPOSE_FILE up -d"
    
    if docker-compose -f "$DOCKER_COMPOSE_FILE" up -d; then
        # Ждем немного чтобы контейнер запустился
        sleep 5
        
        # Проверяем статус контейнера
        local container_status=$(docker ps --filter "name=synapse-admin" --format "{{.Status}}" 2>/dev/null)
        
        if [ -n "$container_status" ]; then
            log "SUCCESS" "Synapse Admin запущен через Docker"
            log "INFO" "Статус контейнера: $container_status"
            
            if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
                log "INFO" "Доступен по адресу: http://${LOCAL_IP:-localhost}:8080"
                log "INFO" "Для доступа с хоста Proxmox используйте: http://${LOCAL_IP}:8080"
            else
                log "INFO" "Доступен по адресу: http://localhost:8080"
            fi
            
            # Тестируем доступность
            log "INFO" "Тестирование доступности..."
            sleep 3
            
            local test_url="http://localhost:8080"
            local response_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$test_url" 2>/dev/null || echo "000")
            
            if [[ "$response_code" == "200" ]] || [[ "$response_code" == "404" ]] || [[ "$response_code" == "302" ]]; then
                log "SUCCESS" "Synapse Admin отвечает на запросы (HTTP $response_code)"
            else
                log "WARN" "Synapse Admin не отвечает (HTTP $response_code)"
                log "INFO" "Проверьте логи: docker logs synapse-admin"
            fi
        else
            log "ERROR" "Контейнер не запустился"
            log "INFO" "Проверьте логи: docker logs synapse-admin"
            return 1
        fi
    else
        log "ERROR" "Ошибка запуска Docker контейнера"
        log "INFO" "Проверьте логи: docker-compose -f $DOCKER_COMPOSE_FILE logs"
        
        # Показываем логи для диагностики
        echo
        log "INFO" "Логи Docker Compose:"
        docker-compose -f "$DOCKER_COMPOSE_FILE" logs --tail=20
        
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
    
    # Если функция вызвана с параметром "auto", создаем базовую конфигурацию
    if [[ "$1" == "auto" ]]; then
        log "INFO" "Создание базовой конфигурации по умолчанию..."
        
        mkdir -p "$(dirname "$ADMIN_CONFIG_FILE")"
        
        cat > "$ADMIN_CONFIG_FILE" <<EOF
{
  "defaultTheme": "auto",
  "developmentMode": false,
  "locale": "ru"
}
EOF
        
        log "SUCCESS" "Базовый конфигурационный файл создан: $ADMIN_CONFIG_FILE"
        return 0
    fi
    
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

# Проверка конфигурационного файла
validate_config() {
    if [ ! -f "$ADMIN_CONFIG_FILE" ]; then
        log "ERROR" "Конфигурационный файл не найден: $ADMIN_CONFIG_FILE"
        return 1
    fi
    
    # Проверяем синтаксис JSON
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -m json.tool "$ADMIN_CONFIG_FILE" >/dev/null 2>&1; then
            log "ERROR" "Неверный синтаксис JSON в конфигурационном файле"
            return 1
        fi
    elif command -v jq >/dev/null 2>&1; then
        if ! jq . "$ADMIN_CONFIG_FILE" >/dev/null 2>&1; then
            log "ERROR" "Неверный синтаксис JSON в конфигурационном файле"
            return 1
        fi
    else
        log "WARN" "Не удалось проверить синтаксис JSON (нет python3 или jq)"
    fi
    
    # Проверяем права доступа
    if [ ! -r "$ADMIN_CONFIG_FILE" ]; then
        log "ERROR" "Нет прав на чтение конфигурационного файла"
        return 1
    fi
    
    log "SUCCESS" "Конфигурационный файл корректен"
    return 0
}

# Очистка проблемных файлов и директорий
clean_conflicting_paths() {
    log "INFO" "Проверка и очистка конфликтующих путей..."
    
    # Проверяем, есть ли директория config.json в /var/www/synapse-admin/
    local old_config_path="/var/www/synapse-admin/config.json"
    
    if [ -d "$old_config_path" ]; then
        log "WARN" "Найдена директория $old_config_path, которая мешает созданию файла конфигурации"
        
        if ask_confirmation "Удалить проблемную директорию $old_config_path?"; then
            log "INFO" "Удаление проблемной директории..."
            rm -rf "$old_config_path"
            log "SUCCESS" "Проблемная директория удалена"
        else
            log "ERROR" "Невозможно продолжить установку без удаления проблемной директории"
            return 1
        fi
    fi
    
    # Проверяем, есть ли файл config.json как файл в неправильном месте
    if [ -f "$old_config_path" ]; then
        log "INFO" "Найден старый конфигурационный файл, перемещаем его..."
        
        # Создаем директорию для нового конфига если нужно
        mkdir -p "$(dirname "$ADMIN_CONFIG_FILE")"
        
        # Перемещаем старый конфиг
        mv "$old_config_path" "$ADMIN_CONFIG_FILE"
        log "SUCCESS" "Конфигурация перемещена в правильное место: $ADMIN_CONFIG_FILE"
    fi
    
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
        safe_echo "${GREEN}8.${NC} Просмотр логов Docker"
        safe_echo "${GREEN}9.${NC} Мигрировать конфигурацию"
        safe_echo "${GREEN}10.${NC} Вернуться в главное меню"
        echo
        
        read -p "$(safe_echo "${YELLOW}Выберите опцию [1-10]: ${NC}")" choice
        
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
                show_docker_logs
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            9)
                migrate_config
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            10)
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
        
        # Показываем размер и права доступа
        local config_size=$(du -h "$ADMIN_CONFIG_FILE" 2>/dev/null | cut -f1)
        local config_perms=$(ls -la "$ADMIN_CONFIG_FILE" 2>/dev/null | cut -d' ' -f1)
        safe_echo "   ├─ Размер: ${config_size:-неизвестен}"
        safe_echo "   └─ Права: ${config_perms:-неизвестны}"
    else
        safe_echo "└─ Конфиг файл: ${YELLOW}не найден${NC}"
        
        # Проверяем старое расположение
        local old_config_path="/var/www/synapse-admin/config.json"
        if [ -f "$old_config_path" ] || [ -d "$old_config_path" ]; then
            safe_echo "   └─ ${YELLOW}Найден старый конфиг: $old_config_path${NC}"
            safe_echo "      ${YELLOW}Рекомендуется переустановка для миграции${NC}"
        fi
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

# Проверка Docker окружения
check_docker_environment() {
    log "INFO" "Проверка Docker окружения..."
    
    # Проверяем статус Docker daemon
    if ! docker info >/dev/null 2>&1; then
        log "ERROR" "Docker daemon не запущен"
        log "INFO" "Попытка запуска Docker..."
        systemctl start docker
        sleep 3
        
        if ! docker info >/dev/null 2>&1; then
            log "ERROR" "Не удалось запустить Docker daemon"
            return 1
        fi
    fi
    
    # Проверяем свободное место
    local free_space=$(df /var/lib/docker 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    if [ "$free_space" -lt 1048576 ]; then  # Меньше 1GB
        log "WARN" "Мало свободного места для Docker: $(( free_space / 1024 ))MB"
    fi
    
    # Проверяем доступность порта
    if netstat -tlnp 2>/dev/null | grep -q ":8080 "; then
        log "WARN" "Порт 8080 уже используется"
        local process=$(netstat -tlnp 2>/dev/null | grep ":8080 " | awk '{print $7}')
        log "INFO" "Процесс использующий порт: ${process:-неизвестен}"
        
        if ask_confirmation "Попробовать остановить процесс?"; then
            local pid=$(echo "$process" | cut -d'/' -f1)
            if [ -n "$pid" ] && [ "$pid" != "-" ]; then
                kill "$pid" 2>/dev/null || true
                sleep 2
            fi
        fi
    fi
    
    log "SUCCESS" "Docker окружение готово"
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
    
    # Останавливаем и удаляем Docker контейнер
    if command -v docker >/dev/null 2>&1; then
        if docker ps -q --filter "name=synapse-admin" >/dev/null 2>&1; then
            log "INFO" "Остановка Docker контейнера..."
            docker stop synapse-admin >/dev/null 2>&1 || true
        fi
        
        if docker ps -aq --filter "name=synapse-admin" >/dev/null 2>&1; then
            log "INFO" "Удаление Docker контейнера..."
            docker rm synapse-admin >/dev/null 2>&1 || true
        fi
        
        # Удаляем Docker Compose файл
        if [ -f "$DOCKER_COMPOSE_FILE" ]; then
            log "INFO" "Остановка через Docker Compose..."
            docker-compose -f "$DOCKER_COMPOSE_FILE" down >/dev/null 2>&1 || true
            rm -f "$DOCKER_COMPOSE_FILE"
        fi
        
        # Удаляем сеть если она пустая
        if docker network ls --filter "name=synapse-admin-network" --format "{{.Name}}" | grep -q "synapse-admin-network"; then
            log "INFO" "Удаление Docker сети..."
            docker network rm synapse-admin-network >/dev/null 2>&1 || true
        fi
    fi
    
    # Удаляем файлы
    if [ -d "$SYNAPSE_ADMIN_DIR" ]; then
        log "INFO" "Создание резервной копии перед удалением..."
        backup_file "$SYNAPSE_ADMIN_DIR" "synapse-admin-before-removal"
        
        log "INFO" "Удаление файлов..."
        rm -rf "$SYNAPSE_ADMIN_DIR"
    fi
    
    # Удаляем конфигурационный файл
    if [ -f "$ADMIN_CONFIG_FILE" ]; then
        log "INFO" "Удаление конфигурационного файла..."
        rm -f "$ADMIN_CONFIG_FILE"
    fi
    
    # Удаляем старый конфигурационный файл если он есть
    local old_config_path="/var/www/synapse-admin/config.json"
    if [ -f "$old_config_path" ] || [ -d "$old_config_path" ]; then
        log "INFO" "Удаление старого конфигурационного файла..."
        rm -rf "$old_config_path"
    fi
    
    # Удаляем сохраненный домен
    rm -f "$CONFIG_DIR/admin_domain"
    
    log "SUCCESS" "Synapse Admin удален"
}

# Просмотр логов Docker контейнера
show_docker_logs() {
    print_header "ЛОГИ SYNAPSE ADMIN DOCKER" "$BLUE"
    
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR" "Docker не установлен"
        return 1
    fi
    
    local container_name="synapse-admin"
    
    # Проверяем существование контейнера
    if ! docker ps -a --filter "name=$container_name" --format "{{.Names}}" | grep -q "^$container_name$"; then
        log "ERROR" "Контейнер '$container_name' не найден"
        return 1
    fi
    
    # Показываем информацию о контейнере
    echo
    safe_echo "${BOLD}${CYAN}Информация о контейнере:${NC}"
    
    local container_status=$(docker ps -a --filter "name=$container_name" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}")
    echo "$container_status"
    
    echo
    safe_echo "${BOLD}${CYAN}Последние 50 строк логов:${NC}"
    echo "────────────────────────────────────────"
    
    docker logs --tail=50 --timestamps "$container_name" 2>&1 || {
        log "ERROR" "Не удалось получить логи контейнера"
        return 1
    }
    
    echo "────────────────────────────────────────"
    echo
    
    if ask_confirmation "Показать полные логи?"; then
        echo
        safe_echo "${BOLD}${CYAN}Полные логи контейнера:${NC}"
        echo "────────────────────────────────────────"
        docker logs --timestamps "$container_name" 2>&1
        echo "────────────────────────────────────────"
    fi
    
    if ask_confirmation "Следить за логами в реальном времени?"; then
        echo
        safe_echo "${BOLD}${CYAN}Логи в реальном времени (нажмите Ctrl+C для выхода):${NC}"
        echo "────────────────────────────────────────"
        docker logs -f --timestamps "$container_name" 2>&1
    fi
}

# Миграция конфигурации
migrate_config() {
    print_header "МИГРАЦИЯ КОНФИГУРАЦИИ SYNAPSE ADMIN" "$CYAN"
    
    local old_config_path="/var/www/synapse-admin/config.json"
    
    echo
    safe_echo "${BOLD}${CYAN}Проверка существующих конфигураций:${NC}"
    
    # Проверяем новую конфигурацию
    if [ -f "$ADMIN_CONFIG_FILE" ]; then
        safe_echo "├─ Новая конфигурация: ${GREEN}найдена${NC} ($ADMIN_CONFIG_FILE)"
    else
        safe_echo "├─ Новая конфигурация: ${YELLOW}не найдена${NC}"
    fi
    
    # Проверяем старую конфигурацию
    if [ -f "$old_config_path" ]; then
        safe_echo "├─ Старая конфигурация: ${GREEN}найдена${NC} ($old_config_path)"
    elif [ -d "$old_config_path" ]; then
        safe_echo "├─ Старая конфигурация: ${RED}найдена директория вместо файла${NC} ($old_config_path)"
    else
        safe_echo "├─ Старая конфигурация: ${YELLOW}не найдена${NC}"
    fi
    
    echo
    
    # Если есть проблемная директория
    if [ -d "$old_config_path" ]; then
        log "WARN" "Найдена директория $old_config_path, которая блокирует создание конфигурации"
        
        if ask_confirmation "Удалить проблемную директорию?"; then
            rm -rf "$old_config_path"
            log "SUCCESS" "Проблемная директория удалена"
        else
            log "INFO" "Миграция отменена"
            return 0
        fi
    fi
    
    # Если есть старый файл конфигурации
    if [ -f "$old_config_path" ]; then
        log "INFO" "Найден старый конфигурационный файл"
        
        # Создаем директорию для нового конфига
        mkdir -p "$(dirname "$ADMIN_CONFIG_FILE")"
        
        # Показываем содержимое старого конфига
        echo
        safe_echo "${BOLD}${CYAN}Содержимое старой конфигурации:${NC}"
        echo "────────────────────────────────────────"
        cat "$old_config_path" 2>/dev/null || echo "Не удалось прочитать файл"
        echo "────────────────────────────────────────"
        echo
        
        if ask_confirmation "Перенести эту конфигурацию в новое место?"; then
            # Проверяем, есть ли уже новая конфигурация
            if [ -f "$ADMIN_CONFIG_FILE" ]; then
                if ! ask_confirmation "Новая конфигурация уже существует. Перезаписать?"; then
                    log "INFO" "Миграция отменена"
                    return 0
                fi
                
                # Создаем резервную копию
                backup_file "$ADMIN_CONFIG_FILE" "synapse-admin-config"
            fi
            
            # Перемещаем конфигурацию
            mv "$old_config_path" "$ADMIN_CONFIG_FILE"
            log "SUCCESS" "Конфигурация перемещена в: $ADMIN_CONFIG_FILE"
            
            # Проверяем корректность
            if validate_config; then
                log "SUCCESS" "Миграция завершена успешно"
            else
                log "WARN" "Конфигурация перемещена, но может содержать ошибки"
            fi
        else
            log "INFO" "Миграция отменена"
        fi
    else
        # Создаем новую конфигурацию если ничего нет
        if [ ! -f "$ADMIN_CONFIG_FILE" ]; then
            log "INFO" "Старая конфигурация не найдена, создаем новую"
            
            if ask_confirmation "Создать новую конфигурацию?"; then
                create_config
            else
                log "INFO" "Создание конфигурации отменено"
            fi
        else
            log "INFO" "Конфигурация уже находится в правильном месте"
        fi
    fi
}