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
    
    log "DEBUG" "Matrix домен: $MATRIX_DOMAIN"
    log "DEBUG" "Admin домен: ${ADMIN_DOMAIN:-не настроен}"
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
    
    # Проверяем доступность админ API
    local api_url="$MATRIX_SERVER_URL/_synapse/admin/v1/server_version"
    log "DEBUG" "Проверка доступности админ API: $api_url"
    
    if command -v curl >/dev/null 2>&1; then
        local response=$(curl -s -f "$api_url" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local version=$(echo "$response" | grep -o '"server_version":"[^"]*' | cut -d'"' -f4)
            log "SUCCESS" "Synapse Admin API доступен (версия: ${version:-неизвестна})"
        else
            log "WARN" "Synapse Admin API недоступен извне. Проверьте конфигурацию reverse proxy"
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
    
    log "INFO" "Создание docker-compose конфигурации..."
    
    cat > "$DOCKER_COMPOSE_FILE" <<EOF
version: '3.8'

services:
  synapse-admin:
    image: awesometechnologies/synapse-admin:latest
    container_name: synapse-admin
    hostname: synapse-admin
    ports:
      - "8080:80"
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
        log "INFO" "Доступен по адресу: http://localhost:8080"
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
            echo
            safe_echo "${YELLOW}Введите список разрешенных серверов (по одному на строку, пустая строка для завершения):${NC}"
            local servers=()
            local server
            
            # Добавляем текущий сервер по умолчанию
            servers+=("$MATRIX_SERVER_URL")
            log "INFO" "Добавлен текущий сервер: $MATRIX_SERVER_URL"
            
            while true; do
                read -p "$(safe_echo "${CYAN}Сервер (https://domain.com): ${NC}")" server
                
                if [ -z "$server" ]; then
                    break
                fi
                
                # Простая валидация URL
                if [[ "$server" =~ ^https://[^/]+$ ]]; then
                    servers+=("$server")
                    log "INFO" "Добавлен сервер: $server"
                else
                    log "WARN" "Неверный формат URL: $server (ожидается https://domain.com)"
                fi
            done
            
            # Формируем JSON массив
            local servers_json=""
            for i in "${!servers[@]}"; do
                if [ $i -eq 0 ]; then
                    servers_json="\"${servers[i]}\""
                else
                    servers_json="$servers_json, \"${servers[i]}\""
                fi
            done
            
            base_url_config="\"restrictBaseUrl\": [$servers_json],"
            ;;
        *)
            log "WARN" "Неверный выбор, настройка без ограничений"
            base_url_config=""
            ;;
    esac
    
    # Дополнительные настройки
    echo
    safe_echo "${BOLD}${CYAN}Дополнительные настройки:${NC}"
    
    local theme="auto"
    if ask_confirmation "Включить темную тему по умолчанию?"; then
        theme="dark"
    fi
    
    local privacy_policy=""
    read -p "$(safe_echo "${YELLOW}URL политики конфиденциальности (опционально): ${NC}")" privacy_url
    if [ -n "$privacy_url" ]; then
        privacy_policy="\"privacyPolicyUrl\": \"$privacy_url\","
    fi
    
    local terms_of_service=""
    read -p "$(safe_echo "${YELLOW}URL пользовательского соглашения (опционально): ${NC}")" terms_url
    if [ -n "$terms_url" ]; then
        terms_of_service="\"termsOfServiceUrl\": \"$terms_url\","
    fi
    
    log "INFO" "Создание конфигурационного файла..."
    
    # Создаем директорию если её нет
    mkdir -p "$(dirname "$ADMIN_CONFIG_FILE")"
    
    cat > "$ADMIN_CONFIG_FILE" <<EOF
{
  $base_url_config
  "defaultTheme": "$theme",
  $privacy_policy
  $terms_of_service
  "developmentMode": false,
  "locale": "en"
}
EOF
    
    # Устанавливаем права доступа
    chmod 644 "$ADMIN_CONFIG_FILE"
    chown www-data:www-data "$ADMIN_CONFIG_FILE" 2>/dev/null || true
    
    log "SUCCESS" "Конфигурационный файл создан: $ADMIN_CONFIG_FILE"
    
    # Показываем содержимое
    echo
    safe_echo "${BOLD}${GREEN}Созданная конфигурация:${NC}"
    cat "$ADMIN_CONFIG_FILE"
    
    return 0
}

# Настройка веб-сервера
configure_webserver() {
    print_header "НАСТРОЙКА ВЕБ-СЕРВЕРА" "$MAGENTA"
    
    # Проверяем, какой веб-сервер используется
    local webserver=""
    
    if systemctl is-active --quiet nginx; then
        webserver="nginx"
    elif systemctl is-active --quiet apache2; then
        webserver="apache"
    elif systemctl is-active --quiet caddy; then
        webserver="caddy"
    else
        log "WARN" "Активный веб-сервер не найден"
        
        echo
        safe_echo "${YELLOW}Выберите веб-сервер для настройки:${NC}"
        safe_echo "1. Nginx"
        safe_echo "2. Apache"
        safe_echo "3. Caddy"
        
        read -p "$(safe_echo "${YELLOW}Выберите [1-3]: ${NC}")" ws_choice
        
        case $ws_choice in
            1) webserver="nginx" ;;
            2) webserver="apache" ;;
            3) webserver="caddy" ;;
            *) log "ERROR" "Неверный выбор"; return 1 ;;
        esac
    fi
    
    # Получаем домен для админки
    if [ -z "$ADMIN_DOMAIN" ]; then
        read -p "$(safe_echo "${YELLOW}Введите домен для Synapse Admin (например, admin.example.com): ${NC}")" ADMIN_DOMAIN
        
        if [ -z "$ADMIN_DOMAIN" ]; then
            log "ERROR" "Домен не может быть пустым"
            return 1
        fi
        
        # Сохраняем домен
        echo "$ADMIN_DOMAIN" > "$CONFIG_DIR/admin_domain"
    fi
    
    log "INFO" "Настройка $webserver для домена $ADMIN_DOMAIN"
    
    case $webserver in
        "nginx")
            configure_nginx
            ;;
        "apache")
            configure_apache
            ;;
        "caddy")
            configure_caddy
            ;;
    esac
    
    return $?
}

# Настройка Nginx
configure_nginx() {
    local nginx_config="/etc/nginx/sites-available/synapse-admin"
    
    log "INFO" "Создание конфигурации Nginx..."
    
    cat > "$nginx_config" <<EOF
server {
    listen 80;
    server_name $ADMIN_DOMAIN;
    
    root $SYNAPSE_ADMIN_DIR;
    index index.html;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
    
    location / {
        try_files \$uri \$uri/ /index.html;
        
        # Cache static assets
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }
    
    # Deny access to sensitive files
    location ~ /\.(ht|git) {
        deny all;
    }
    
    # Restrict access to admin interface (optional)
    # location / {
    #     allow 192.168.1.0/24;
    #     allow 10.0.0.0/8;
    #     deny all;
    # }
}
EOF
    
    # Включаем сайт
    ln -sf "$nginx_config" "/etc/nginx/sites-enabled/"
    
    # Проверяем конфигурацию
    if nginx -t; then
        systemctl reload nginx
        log "SUCCESS" "Nginx настроен для $ADMIN_DOMAIN"
    else
        log "ERROR" "Ошибка в конфигурации Nginx"
        return 1
    fi
    
    # Настраиваем SSL
    setup_ssl_nginx
}

# Настройка Apache
configure_apache() {
    local apache_config="/etc/apache2/sites-available/synapse-admin.conf"
    
    log "INFO" "Создание конфигурации Apache..."
    
    cat > "$apache_config" <<EOF
<VirtualHost *:80>
    ServerName $ADMIN_DOMAIN
    DocumentRoot $SYNAPSE_ADMIN_DIR
    
    <Directory $SYNAPSE_ADMIN_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    # Security headers
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    
    # Gzip compression
    LoadModule deflate_module modules/mod_deflate.so
    <Location />
        SetOutputFilter DEFLATE
        SetEnvIfNoCase Request_URI \
            \.(?:gif|jpe?g|png)$ no-gzip dont-vary
        SetEnvIfNoCase Request_URI \
            \.(?:exe|t?gz|zip|bz2|sit|rar)$ no-gzip dont-vary
    </Location>
    
    # Cache static assets
    <LocationMatch "\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$">
        ExpiresActive On
        ExpiresDefault "access plus 1 year"
        Header set Cache-Control "public, immutable"
    </LocationMatch>
    
    ErrorLog \${APACHE_LOG_DIR}/synapse-admin_error.log
    CustomLog \${APACHE_LOG_DIR}/synapse-admin_access.log combined
</VirtualHost>
EOF
    
    # Включаем необходимые модули
    a2enmod rewrite headers expires deflate
    
    # Включаем сайт
    a2ensite synapse-admin
    
    # Проверяем конфигурацию
    if apache2ctl configtest; then
        systemctl reload apache2
        log "SUCCESS" "Apache настроен для $ADMIN_DOMAIN"
    else
        log "ERROR" "Ошибка в конфигурации Apache"
        return 1
    fi
    
    # Настраиваем SSL
    setup_ssl_apache
}

# Настройка Caddy
configure_caddy() {
    local caddy_config="/etc/caddy/Caddyfile"
    
    log "INFO" "Обновление конфигурации Caddy..."
    
    # Проверяем, есть ли уже конфигурация для админки
    if ! grep -q "$ADMIN_DOMAIN" "$caddy_config"; then
        cat >> "$caddy_config" <<EOF

$ADMIN_DOMAIN {
    root * $SYNAPSE_ADMIN_DIR
    file_server
    
    encode gzip
    
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
    
    @static {
        path *.js *.css *.png *.jpg *.jpeg *.gif *.ico *.svg *.woff *.woff2 *.ttf *.eot
    }
    header @static Cache-Control "public, max-age=31536000, immutable"
    
    # SPA fallback
    try_files {path} /index.html
    
    # Optional: Restrict access by IP
    # @restricted {
    #     not remote_ip 192.168.1.0/24 10.0.0.0/8
    # }
    # respond @restricted "Access denied" 403
}
EOF
    fi
    
    # Проверяем и перезагружаем конфигурацию
    if caddy validate --config "$caddy_config"; then
        systemctl reload caddy
        log "SUCCESS" "Caddy настроен для $ADMIN_DOMAIN"
        log "INFO" "SSL сертификат будет получен автоматически"
    else
        log "ERROR" "Ошибка в конфигурации Caddy"
        return 1
    fi
}

# Настройка SSL для Nginx
setup_ssl_nginx() {
    if command -v certbot >/dev/null 2>&1; then
        log "INFO" "Настройка SSL сертификата через Certbot..."
        
        if ask_confirmation "Получить SSL сертификат от Let's Encrypt?"; then
            if certbot --nginx -d "$ADMIN_DOMAIN" --non-interactive --agree-tos --redirect; then
                log "SUCCESS" "SSL сертификат настроен"
            else
                log "WARN" "Ошибка получения SSL сертификата"
            fi
        fi
    else
        log "WARN" "Certbot не установлен, SSL не настроен"
    fi
}

# Настройка SSL для Apache
setup_ssl_apache() {
    if command -v certbot >/dev/null 2>&1; then
        log "INFO" "Настройка SSL сертификата через Certbot..."
        
        if ask_confirmation "Получить SSL сертификат от Let's Encrypt?"; then
            # Включаем SSL модуль
            a2enmod ssl
            
            if certbot --apache -d "$ADMIN_DOMAIN" --non-interactive --agree-tos --redirect; then
                log "SUCCESS" "SSL сертификат настроен"
            else
                log "WARN" "Ошибка получения SSL сертификата"
            fi
        fi
    else
        log "WARN" "Certbot не установлен, SSL не настроен"
    fi
}

# Проверка статуса установки
check_status() {
    print_header "СТАТУС SYNAPSE ADMIN" "$BLUE"
    
    # Проверяем установку
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
            safe_echo "├─ Версия: ${GREEN}$INSTALLED_VERSION${NC}"
        else
            safe_echo "├─ Версия: ${YELLOW}неопределена${NC}"
        fi
    else
        safe_echo "├─ Директория: ${RED}не существует${NC}"
    fi
    
    # Проверяем конфигурацию
    echo
    safe_echo "${BOLD}${CYAN}Конфигурация:${NC}"
    
    if [ -f "$ADMIN_CONFIG_FILE" ]; then
        safe_echo "├─ Конфиг файл: ${GREEN}найден${NC}"
        safe_echo "└─ Путь: $ADMIN_CONFIG_FILE"
    else
        safe_echo "└─ Конфиг файл: ${YELLOW}не найден${NC}"
    fi
    
    # Проверяем веб-сервер
    echo
    safe_echo "${BOLD}${CYAN}Веб-сервер:${NC}"
    
    local configured_servers=()
    
    # Nginx
    if systemctl is-active --quiet nginx && [ -f "/etc/nginx/sites-enabled/synapse-admin" ]; then
        configured_servers+=("nginx")
    fi
    
    # Apache
    if systemctl is-active --quiet apache2 && [ -f "/etc/apache2/sites-enabled/synapse-admin.conf" ]; then
        configured_servers+=("apache")
    fi
    
    # Caddy
    if systemctl is-active --quiet caddy && [ -n "$ADMIN_DOMAIN" ] && grep -q "$ADMIN_DOMAIN" "/etc/caddy/Caddyfile" 2>/dev/null; then
        configured_servers+=("caddy")
    fi
    
    if [ ${#configured_servers[@]} -gt 0 ]; then
        safe_echo "├─ Настроенные серверы: ${GREEN}${configured_servers[*]}${NC}"
    else
        safe_echo "├─ Настроенные серверы: ${RED}не найдены${NC}"
    fi
    
    # Проверяем домен
    if [ -n "$ADMIN_DOMAIN" ]; then
        safe_echo "└─ Домен: ${GREEN}$ADMIN_DOMAIN${NC}"
        
        # Проверяем доступность
        echo
        safe_echo "${BOLD}${CYAN}Доступность:${NC}"
        
        local urls=("http://$ADMIN_DOMAIN" "https://$ADMIN_DOMAIN")
        
        for url in "${urls[@]}"; do
            if command -v curl >/dev/null 2>&1; then
                if curl -s -f "$url" >/dev/null 2>&1; then
                    safe_echo "├─ $url: ${GREEN}доступен${NC}"
                else
                    safe_echo "├─ $url: ${RED}недоступен${NC}"
                fi
            fi
        done
    else
        safe_echo "└─ Домен: ${YELLOW}не настроен${NC}"
    fi
    
    # Проверяем Docker контейнер
    echo
    safe_echo "${BOLD}${CYAN}Docker контейнер:${NC}"
    
    if command -v docker >/dev/null 2>&1; then
        local container_status=$(docker ps --filter "name=synapse-admin" --format "{{.Status}}" 2>/dev/null)
        
        if [ -n "$container_status" ]; then
            safe_echo "└─ Статус: ${GREEN}$container_status${NC}"
        else
            safe_echo "└─ Статус: ${YELLOW}не запущен${NC}"
        fi
    else
        safe_echo "└─ Docker: ${YELLOW}не установлен${NC}"
    fi
    
    echo
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
    
    # Удаляем конфигурацию веб-сервера
    log "INFO" "Удаление конфигурации веб-сервера..."
    
    # Nginx
    if [ -f "/etc/nginx/sites-enabled/synapse-admin" ]; then
        rm -f "/etc/nginx/sites-enabled/synapse-admin"
        rm -f "/etc/nginx/sites-available/synapse-admin"
        systemctl reload nginx 2>/dev/null || true
    fi
    
    # Apache
    if [ -f "/etc/apache2/sites-enabled/synapse-admin.conf" ]; then
        a2dissite synapse-admin 2>/dev/null || true
        rm -f "/etc/apache2/sites-available/synapse-admin.conf"
        systemctl reload apache2 2>/dev/null || true
    fi
    
    # Caddy (удаляем только блок для админки)
    if [ -n "$ADMIN_DOMAIN" ] && [ -f "/etc/caddy/Caddyfile" ]; then
        # Создаем временный файл без блока админки
        awk -v domain="$ADMIN_DOMAIN" '
        BEGIN { skip = 0 }
        $0 ~ "^" domain " {" { skip = 1; next }
        skip && /^}$/ { skip = 0; next }
        !skip { print }
        ' "/etc/caddy/Caddyfile" > "/etc/caddy/Caddyfile.tmp"
        
        mv "/etc/caddy/Caddyfile.tmp" "/etc/caddy/Caddyfile"
        systemctl reload caddy 2>/dev/null || true
    fi
    
    # Удаляем сохраненный домен
    rm -f "$CONFIG_DIR/admin_domain"
    
    log "SUCCESS" "Synapse Admin удален"
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
        safe_echo "${GREEN}4.${NC} Настроить веб-сервер"
        safe_echo "${GREEN}5.${NC} Проверить статус"
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
                configure_webserver
                read -p "$(safe_echo "${CYAN}Нажмите Enter для продолжения...${NC}")"
                ;;
            5)
                check_status
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