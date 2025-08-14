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
    
    log "INFO" "Создание резервной копии..."`
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

# Генерация конфигурации для хоста Proxmox
generate_proxmox_host_config() {
    print_header "ГЕНЕРАЦИЯ КОНФИГУРАЦИИ ДЛЯ ХОСТА PROXMOX" "$YELLOW"
    
    if [[ "$SERVER_TYPE" != "proxmox" ]] && [[ "$SERVER_TYPE" != "home_server" ]]; then
        log "WARN" "Эта функция предназначена только для Proxmox/домашних серверов"
        return 1
    fi
    
    if [ -z "$ADMIN_DOMAIN" ]; then
        read -p "$(safe_echo "${YELLOW}Введите домен для Synapse Admin (например, admin.example.com): ${NC}")" ADMIN_DOMAIN
        if [ -z "$ADMIN_DOMAIN" ]; then
            log "ERROR" "Домен не может быть пустым"
            return 1
        fi
    fi
    
    local vm_ip="${LOCAL_IP:-192.168.1.100}"
    read -p "$(safe_echo "${YELLOW}IP адрес VPS в локальной сети [$vm_ip]: ${NC}")" input_ip
    vm_ip="${input_ip:-$vm_ip}"
    
    log "INFO" "Создание конфигурационных файлов для хоста Proxmox..."
    
    # Создаем директорию для конфигов хоста
    mkdir -p "$CONFIG_DIR/host-configs"
    
    # Caddy конфигурация
    cat > "$CONFIG_DIR/host-configs/synapse-admin-caddy.txt" <<EOF
# ========================================
# Synapse Admin - Caddy конфигурация для хоста Proxmox
# ========================================
# Добавьте этот блок в /etc/caddy/Caddyfile на хосте Proxmox:

$ADMIN_DOMAIN {
    reverse_proxy $vm_ip:80 {
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
    
    encode gzip
    
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
    
    # Логирование
    log {
        output file /var/log/caddy/synapse-admin.log {
            roll_size 100mb
            roll_keep 3
        }
        format console
    }
}

# Если используете Docker версию Synapse Admin:
# $ADMIN_DOMAIN {
#     reverse_proxy $vm_ip:8080 {
#         header_up Host {upstream_hostport}
#         header_up X-Real-IP {remote_host}
#         header_up X-Forwarded-For {remote_host}
#         header_up X-Forwarded-Proto {scheme}
#         header_up X-Forwarded-Host {host}
#     }
# }
EOF

    # Nginx конфигурация
    cat > "$CONFIG_DIR/host-configs/synapse-admin-nginx.conf" <<EOF
# ========================================  
# Synapse Admin - Nginx конфигурация для хоста Proxmox
# ========================================
# Сохраните как /etc/nginx/sites-available/synapse-admin на хосте Proxmox

server {
    listen 80;
    server_name $ADMIN_DOMAIN;
    
    # Редирект на HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $ADMIN_DOMAIN;
    
    # SSL сертификаты (настройте путь к вашим сертификатам)
    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOMAIN/privkey.pem;
    
    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # Заголовки безопасности
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # Проксирование на VPS
    location / {
        proxy_pass http://$vm_ip:80;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_cache_bypass \$http_upgrade;
        
        # Таймауты
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
    
    # Логирование
    access_log /var/log/nginx/synapse-admin-access.log;
    error_log /var/log/nginx/synapse-admin-error.log;
}

# Если используете Docker версию (порт 8080):
# location / {
#     proxy_pass http://$vm_ip:8080;
#     # ... остальные настройки такие же
# }
EOF

    # Apache конфигурация
    cat > "$CONFIG_DIR/host-configs/synapse-admin-apache.conf" <<EOF
# ========================================
# Synapse Admin - Apache конфигурация для хоста Proxmox  
# ========================================
# Сохраните как /etc/apache2/sites-available/synapse-admin.conf на хосте Proxmox

<VirtualHost *:80>
    ServerName $ADMIN_DOMAIN
    Redirect permanent / https://$ADMIN_DOMAIN/
</VirtualHost>

<VirtualHost *:443>
    ServerName $ADMIN_DOMAIN
    
    # SSL настройки (настройте путь к вашим сертификатам)
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$ADMIN_DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$ADMIN_DOMAIN/privkey.pem
    
    # Заголовки безопасности
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    
    # Проксирование на VPS
    ProxyPreserveHost On
    ProxyRequests Off
    ProxyPass / http://$vm_ip:80/
    ProxyPassReverse / http://$vm_ip:80/
    
    # Заголовки для проксирования
    ProxyPassReverse / http://$vm_ip:80/
    ProxyPassReverseAdjust On
    
    # Установка заголовков
    ProxyPassReverse / http://$vm_ip:80/
    ProxyAddHeaders On
    
    # Логирование
    LogLevel warn
    ErrorLog \${APACHE_LOG_DIR}/synapse-admin-error.log
    CustomLog \${APACHE_LOG_DIR}/synapse-admin-access.log combined
</VirtualHost>

# Включите необходимые модули:
# a2enmod ssl headers proxy proxy_http
# a2ensite synapse-admin
# systemctl reload apache2
EOF

    # Docker Compose для хоста
    cat > "$CONFIG_DIR/host-configs/docker-compose-host.yml" <<EOF
# ========================================
# Synapse Admin - Docker Compose для хоста Proxmox
# ========================================
# Если вы хотите запустить Synapse Admin на хосте вместо VPS

version: '3.8'

services:
  synapse-admin:
    image: awesometechnologies/synapse-admin:latest
    container_name: synapse-admin-host
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"  # Только локальный доступ
    volumes:
      - ./config.json:/app/config.json:ro
    environment:
      - TZ=Europe/Moscow
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:80"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  default:
    name: synapse-admin-host-network
EOF

    # Конфигурация для Synapse Admin на хосте
    cat > "$CONFIG_DIR/host-configs/config.json" <<EOF
{
  "restrictBaseUrl": "https://$MATRIX_DOMAIN",
  "defaultTheme": "auto",
  "developmentMode": false,
  "locale": "en"
}
EOF

    # Скрипт установки для хоста
    cat > "$CONFIG_DIR/host-configs/install-on-host.sh" <<'EOF'
#!/bin/bash

# Скрипт установки Synapse Admin на хосте Proxmox

echo "=== Установка Synapse Admin на хосте Proxmox ==="

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен с правами root" 
   exit 1
fi

CONFIG_DIR="/opt/synapse-admin"
mkdir -p "$CONFIG_DIR"

echo "Выберите способ установки:"
echo "1. Docker (рекомендуется)"
echo "2. Caddy reverse proxy"
echo "3. Nginx reverse proxy"  
echo "4. Apache reverse proxy"

read -p "Выберите [1-4]: " choice

case $choice in
    1)
        echo "Установка через Docker..."
        
        # Проверяем Docker
        if ! command -v docker &> /dev/null; then
            echo "Установка Docker..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sh get-docker.sh
        fi
        
        # Проверяем docker-compose
        if ! command -v docker-compose &> /dev/null; then
            echo "Установка Docker Compose..."
            curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        fi
        
        # Копируем файлы
        cp docker-compose-host.yml "$CONFIG_DIR/docker-compose.yml"
        cp config.json "$CONFIG_DIR/"
        
        # Запускаем
        cd "$CONFIG_DIR"
        docker-compose up -d
        
        echo "Synapse Admin запущен на http://localhost:8080"
        ;;
    2)
        echo "Настройка Caddy..."
        echo "Скопируйте содержимое synapse-admin-caddy.txt в /etc/caddy/Caddyfile"
        echo "Затем выполните: systemctl reload caddy"
        ;;
    3)  
        echo "Настройка Nginx..."
        echo "Скопируйте synapse-admin-nginx.conf в /etc/nginx/sites-available/"
        echo "Затем выполните:"
        echo "  ln -s /etc/nginx/sites-available/synapse-admin /etc/nginx/sites-enabled/"
        echo "  nginx -t && systemctl reload nginx"
        ;;
    4)
        echo "Настройка Apache..."
        echo "Скопируйте synapse-admin-apache.conf в /etc/apache2/sites-available/"
        echo "Затем выполните:"
        echo "  a2enmod ssl headers proxy proxy_http"
        echo "  a2ensite synapse-admin"
        echo "  systemctl reload apache2"
        ;;
    *)
        echo "Неверный выбор"
        exit 1
        ;;
esac

echo "Установка завершена!"
EOF

    chmod +x "$CONFIG_DIR/host-configs/install-on-host.sh"

    # Создаем README
    cat > "$CONFIG_DIR/host-configs/README.md" <<EOF
# Конфигурация Synapse Admin для хоста Proxmox

Этот каталог содержит файлы конфигурации для настройки доступа к Synapse Admin с хоста Proxmox.

## Сценарий 1: Synapse Admin на VPS + Reverse Proxy на хосте

### Caddy (рекомендуется)
1. Скопируйте содержимое \`synapse-admin-caddy.txt\` в \`/etc/caddy/Caddyfile\` на хосте
2. Выполните: \`systemctl reload caddy\`

### Nginx
1. Скопируйте \`synapse-admin-nginx.conf\` в \`/etc/nginx/sites-available/\` на хосте
2. Создайте симлинк: \`ln -s /etc/nginx/sites-available/synapse-admin /etc/nginx/sites-enabled/\`
3. Проверьте и перезагрузите: \`nginx -t && systemctl reload nginx\`

### Apache
1. Скопируйте \`synapse-admin-apache.conf\` в \`/etc/apache2/sites-available/\` на хосте
2. Включите модули: \`a2enmod ssl headers proxy proxy_http\`
3. Включите сайт: \`a2ensite synapse-admin\`
4. Перезагрузите: \`systemctl reload apache2\`

## Сценарий 2: Synapse Admin на хосте

Запустите скрипт \`install-on-host.sh\` на хосте Proxmox.

## Настройки

- **VPS IP**: $vm_ip
- **Домен**: $ADMIN_DOMAIN
- **Matrix домен**: $MATRIX_DOMAIN

## Проверка

После настройки:
1. Убедитесь, что Synapse Admin работает на VPS: http://$vm_ip:80
2. Проверьте доступность через домен: https://$ADMIN_DOMAIN
3. Проверьте логи на хосте

## Безопасность

Для production использования:
1. Настройте правильные SSL сертификаты
2. Ограничьте доступ по IP если необходимо
3. Настройте мониторинг и логирование
4. Регулярно обновляйте компоненты
EOF

    log "SUCCESS" "Конфигурационные файлы созданы в $CONFIG_DIR/host-configs/"
    echo
    safe_echo "${BOLD}${GREEN}Созданные файлы:${NC}"
    safe_echo "├─ ${CYAN}synapse-admin-caddy.txt${NC} - Конфигурация для Caddy"
    safe_echo "├─ ${CYAN}synapse-admin-nginx.conf${NC} - Конфигурация для Nginx"
    safe_echo "├─ ${CYAN}synapse-admin-apache.conf${NC} - Конфигурация для Apache"
    safe_echo "├─ ${CYAN}docker-compose-host.yml${NC} - Docker Compose для хоста"
    safe_echo "├─ ${CYAN}config.json${NC} - Конфигурация Synapse Admin"
    safe_echo "├─ ${CYAN}install-on-host.sh${NC} - Скрипт установки на хосте"
    safe_echo "└─ ${CYAN}README.md${NC} - Подробные инструкции"
    
    echo
    safe_echo "${BOLD}${YELLOW}Следующие шаги:${NC}"
    safe_echo "1. Скопируйте файлы на хост Proxmox"
    safe_echo "2. Выберите подходящий веб-сервер (Caddy рекомендуется)"
    safe_echo "3. Настройте SSL сертификаты"
    safe_echo "4. Проверьте доступность: https://$ADMIN_DOMAIN"
    
    return 0
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
    
    # Проверяем веб-сервер
    local webserver_running=false
    if systemctl is-active --quiet nginx; then
        safe_echo "├─ Nginx: ${GREEN}работает${NC}"
        webserver_running=true
    elif systemctl is-active --quiet apache2; then
        safe_echo "├─ Apache: ${GREEN}работает${NC}"
        webserver_running=true
    elif systemctl is-active --quiet caddy; then
        safe_echo "├─ Caddy: ${GREEN}работает${NC}"
        webserver_running=true
    else
        safe_echo "├─ Веб-сервер: ${RED}не запущен${NC}"
    fi
    
    # Проверяем Docker контейнер
    if command -v docker >/dev/null 2>&1; then
        local container_running=$(docker ps --filter "name=synapse-admin" --format "{{.Names}}" 2>/dev/null)
        if [ -n "$container_running" ]; then
            safe_echo "├─ Docker контейнер: ${GREEN}запущен${NC}"
            webserver_running=true
        else
            safe_echo "├─ Docker контейнер: ${YELLOW}не запущен${NC}"
        fi
    fi
    
    if ! $webserver_running; then
        safe_echo "└─ ${RED}Ни один веб-сервер не работает${NC}"
        return 1
    fi
    
    # Тестируем доступность в зависимости от типа сервера
    echo
    safe_echo "${BOLD}${CYAN}Тестирование HTTP доступности:${NC}"
    
    local test_urls=()
    local success_count=0
    local total_tests=0
    
    case "$SERVER_TYPE" in
        "proxmox"|"home_server")
            # Для локальных VPS тестируем локальные адреса
            test_urls+=("http://localhost:80")
            test_urls+=("http://127.0.0.1:80")
            if [ -n "$LOCAL_IP" ]; then
                test_urls+=("http://$LOCAL_IP:80")
            fi
            
            # Если есть Docker контейнер
            if docker ps --filter "name=synapse-admin" --format "{{.Names}}" >/dev/null 2>&1; then
                test_urls+=("http://localhost:8080")
                test_urls+=("http://127.0.0.1:8080")
                if [ -n "$LOCAL_IP" ]; then
                    test_urls+=("http://$LOCAL_IP:8080")
                fi
            fi
            ;;
        "hosting")
            # Для хостинга тестируем внешние адреса
            test_urls+=("http://localhost:80")
            if [ -n "$ADMIN_DOMAIN" ]; then
                test_urls+=("http://$ADMIN_DOMAIN")
                test_urls+=("https://$ADMIN_DOMAIN")
            fi
            ;;
        *)
            # Универсальные тесты
            test_urls+=("http://localhost:80")
            test_urls+=("http://127.0.0.1:80")
            ;;
    esac
    
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
    
    # Дополнительные проверки для Proxmox
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        echo
        safe_echo "${BOLD}${CYAN}Настройка доступа извне:${NC}"
        
        if [ -n "$LOCAL_IP" ]; then
            safe_echo "├─ IP VPS в локальной сети: ${GREEN}$LOCAL_IP${NC}"
            
            # Проверяем, можно ли подключиться с хоста
            if command -v nc >/dev/null 2>&1; then
                if timeout 3 nc -z "$LOCAL_IP" 80 2>/dev/null; then
                    safe_echo "├─ Порт 80 доступен с хоста: ${GREEN}да${NC}"
                else
                    safe_echo "├─ Порт 80 доступен с хоста: ${RED}нет${NC}"
                fi
                
                if docker ps --filter "name=synapse-admin" --format "{{.Names}}" >/dev/null 2>&1; then
                    if timeout 3 nc -z "$LOCAL_IP" 8080 2>/dev/null; then
                        safe_echo "├─ Порт 8080 доступен с хоста: ${GREEN}да${NC}"
                    else
                        safe_echo "├─ Порт 8080 доступен с хоста: ${RED}нет${NC}"
                    fi
                fi
            fi
        fi
        
        safe_echo "├─ Файлы конфигурации: $CONFIG_DIR/host-configs/"
        safe_echo "└─ ${YELLOW}Для внешнего доступа настройте reverse proxy на хосте${NC}"
    fi
    
    # Проверка API подключения
    echo
    safe_echo "${BOLD}${CYAN}Проверка API подключения:${NC}"
    
    if [ -f "$ADMIN_CONFIG_FILE" ]; then
        safe_echo "├─ Конфигурация: ${GREEN}найдена${NC}"
        
        # Пытаемся извлечь настройки из конфигурации
        local restricted_url=$(grep -o '"restrictBaseUrl"[^"]*"[^"]*"' "$ADMIN_CONFIG_FILE" 2>/dev/null | cut -d'"' -f4)
        if [ -n "$restricted_url" ]; then
            safe_echo "├─ Ограничен сервером: ${YELLOW}$restricted_url${NC}"
            
            # Проверяем доступность API
            local api_url="$restricted_url/_synapse/admin/v1/server_version"
            local api_response=$(curl -s -f "$api_url" 2>/dev/null)
            if [ $? -eq 0 ]; then
                local version=$(echo "$api_response" | grep -o '"server_version":"[^"]*' | cut -d'"' -f4)
                safe_echo "└─ API доступен: ${GREEN}да${NC} (версия: ${version:-неизвестна})"
            else
                safe_echo "└─ API доступен: ${RED}нет${NC}"
            fi
        else
            safe_echo "└─ Ограничения сервера: ${GREEN}нет${NC}"
        fi
    else
        safe_echo "└─ Конфигурация: ${YELLOW}не найдена${NC}"
    fi
    
    # Итоговый результат
    echo
    safe_echo "${BOLD}${CYAN}Результат диагностики:${NC}"
    
    local success_rate=$((success_count * 100 / total_tests))
    
    if [ $success_rate -gt 80 ]; then
        safe_echo "└─ Статус: ${GREEN}Synapse Admin работает корректно${NC} ($success_count/$total_tests тестов прошли)"
    elif [ $success_rate -gt 50 ]; then
        safe_echo "└─ Статус: ${YELLOW}Частичные проблемы${NC} ($success_count/$total_tests тестов прошли)"
    else
        safe_echo "└─ Статус: ${RED}Требуется диагностика${NC} ($success_count/$total_tests тестов прошли)"
    fi
    
    # Рекомендации
    echo
    safe_echo "${BOLD}${CYAN}Рекомендации:${NC}"
    
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        safe_echo "├─ Для доступа извне используйте reverse proxy на хосте"
        safe_echo "├─ Сгенерируйте конфигурацию (опция 7 в меню)"
        safe_echo "└─ Настройте SSL сертификаты на хосте"
    else
        safe_echo "├─ Убедитесь, что домен указывает на этот сервер"
        safe_echo "├─ Настройте SSL сертификаты"
        safe_echo "└─ Проверьте настройки файрвола"
    fi
    
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
    
    # Определяем backend в зависимости от типа сервера
    local nginx_backend
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        # Для локальной VPS - backend должен слушать на всех интерфейсах
        nginx_backend="0.0.0.0"
    else
        # Для хостинга - только localhost
        nginx_backend="127.0.0.1"
    fi
    
    cat > "$nginx_config" <<EOF
server {
    listen ${BIND_ADDRESS:-0.0.0.0}:80;
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
    
    # Restrict access to admin interface for production
    $(if [[ "$SERVER_TYPE" == "hosting" ]]; then
        echo "    # Uncomment to restrict access by IP"
        echo "    # location / {"
        echo "    #     allow 192.168.1.0/24;"
        echo "    #     allow 10.0.0.0/8;"
        echo "    #     deny all;"
        echo "    # }"
    fi)
}
EOF
    
    # Для Proxmox добавляем дополнительную конфигурацию для проксирования с хоста
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        log "INFO" "Добавление информации для настройки проксирования с хоста Proxmox"
        
        cat > "$CONFIG_DIR/nginx-proxmox-example.conf" <<EOF
# Пример конфигурации для хоста Proxmox
# Добавьте этот блок в Caddyfile на хосте Proxmox:

$ADMIN_DOMAIN {
    reverse_proxy ${LOCAL_IP}:80 {
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
    
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
        
        log "INFO" "Пример конфигурации сохранен в: $CONFIG_DIR/nginx-proxmox-example.conf"
    fi
    
    # Включаем сайт
    ln -sf "$nginx_config" "/etc/nginx/sites-enabled/"
    
    # Проверяем конфигурацию
    if nginx -t; then
        systemctl reload nginx
        log "SUCCESS" "Nginx настроен для $ADMIN_DOMAIN"
        
        if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
            log "INFO" "Для доступа извне настройте reverse proxy на хосте Proxmox"
            log "INFO" "Synapse Admin работает на: http://${LOCAL_IP}:80"
        fi
    else
        log "ERROR" "Ошибка в конфигурации Nginx"
        return 1
    fi
    
    # Настраиваем SSL только для хостинга
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        setup_ssl_nginx
    else
        log "INFO" "SSL настройка пропущена для локальной VPS - используйте SSL терминацию на хосте Proxmox"
    fi
}

# Настройка Apache  
configure_apache() {
    local apache_config="/etc/apache2/sites-available/synapse-admin.conf"
    
    log "INFO" "Создание конфигурации Apache..."
    
    # Определяем адрес прослушивания
    local listen_directive
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        listen_directive="*:80"
    else
        listen_directive="127.0.0.1:80"
    fi
    
    cat > "$apache_config" <<EOF
<VirtualHost $listen_directive>
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
        
        if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
            log "INFO" "Для доступа извне настройте reverse proxy на хосте Proxmox"
        fi
    else
        log "ERROR" "Ошибка в конфигурации Apache"
        return 1
    fi
    
    # Настраиваем SSL только для хостинга
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        setup_ssl_apache
    else
        log "INFO" "SSL настройка пропущена для локальной VPS"
    fi
}

# Настройка Caddy
configure_caddy() {
    local caddy_config="/etc/caddy/Caddyfile"
    
    log "INFO" "Обновление конфигурации Caddy..."
    
    # Для Proxmox не настраиваем Caddy на VPS - он должен быть на хосте
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        log "WARN" "Для Proxmox/домашнего сервера Caddy должен быть настроен на хосте, а не на VPS"
        log "INFO" "Создание примера конфигурации для хоста..."
        
        cat > "$CONFIG_DIR/caddy-proxmox-example.conf" <<EOF
# Добавьте этот блок в Caddyfile на хосте Proxmox:

$ADMIN_DOMAIN {
    reverse_proxy ${LOCAL_IP}:80 {
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
    
    encode gzip
    
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
        
        log "SUCCESS" "Пример конфигурации сохранен в: $CONFIG_DIR/caddy-proxmox-example.conf"
        log "INFO" "Скопируйте содержимое этого файла в Caddyfile на хосте Proxmox"
        return 0
    fi
    
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
    
    # Показываем тип сервера
    echo
    safe_echo "${BOLD}${CYAN}Тип развертывания:${NC}"
    case "$SERVER_TYPE" in
        "proxmox")
            safe_echo "├─ Тип: ${YELLOW}Proxmox VE${NC}"
            safe_echo "├─ Режим: Локальная VPS за NAT"
            safe_echo "└─ Рекомендация: Используйте reverse proxy на хосте"
            ;;
        "home_server")
            safe_echo "├─ Тип: ${YELLOW}Домашний сервер${NC}"
            safe_echo "├─ Режим: Локальная сеть"
            safe_echo "└─ Рекомендация: Настройте проброс портов"
            ;;
        "hosting")
            safe_echo "├─ Тип: ${GREEN}Облачный хостинг${NC}"
            safe_echo "├─ Режим: Прямой доступ из интернета"
            safe_echo "└─ SSL: Настройка автоматическая"
            ;;
        *)
            safe_echo "└─ Тип: ${RED}Не определен${NC}"
            ;;
    esac
    
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
        
        if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
            # Для локальных VPS проверяем локальный доступ
            local local_urls=("http://${LOCAL_IP}:80" "http://${LOCAL_IP}:8080")
            
            for url in "${local_urls[@]}"; do
                if command -v curl >/dev/null 2>&1; then
                    if curl -s -f "$url" >/dev/null 2>&1; then
                        safe_echo "├─ $url: ${GREEN}доступен${NC}"
                    else
                        safe_echo "├─ $url: ${RED}недоступен${NC}"
                    fi
                fi
            done
            
            safe_echo "└─ Внешний доступ: ${YELLOW}настройте reverse proxy на хосте${NC}"
        else
            # Для хостинга проверяем внешний доступ
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
        fi
    else
        safe_echo "└─ Домен: ${YELLOW}не настроен${NC}"
    fi
    
    # Проверяем Docker контейнер
    echo
    safe_echo "${BOLD}${CYAN}Docker контейнер:${NC}"
    
    if command -v docker >/dev/null 2>&1; then
        local container_status=$(docker ps --filter "name=synapse-admin" --format "{{.Status}}" 2>/dev/null)
        
        if [ -n "$container_status" ]; then
            safe_echo "├─ Статус: ${GREEN}$container_status${NC}"
            
            # Показываем порты в зависимости от типа сервера
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
    
    # Показываем примеры конфигурации для Proxmox
    if [[ "$SERVER_TYPE" == "proxmox" ]] || [[ "$SERVER_TYPE" == "home_server" ]]; then
        echo
        safe_echo "${BOLD}${CYAN}Настройка доступа извне:${NC}"
        safe_echo "├─ Конфигурационные файлы в: ${YELLOW}$CONFIG_DIR/${NC}"
        safe_echo "├─ Caddy пример: ${YELLOW}caddy-proxmox-example.conf${NC}"
        safe_echo "└─ Nginx пример: ${YELLOW}nginx-proxmox-example.conf${NC}"
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