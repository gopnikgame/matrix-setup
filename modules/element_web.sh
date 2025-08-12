#!/bin/bash

# Element Web Installation Module
# Использует common_lib.sh для улучшенного логирования и обработки ошибок
# Версия: 4.0.0 - с поддержкой Proxmox архитектуры

# Настройки модуля
LIB_NAME="Element Web Installer"
LIB_VERSION="4.0.0"
MODULE_NAME="element_web"

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../common/common_lib.sh"

if [ ! -f "$COMMON_LIB" ]; then
    echo "ОШИБКА: Не найдена библиотека common_lib.sh по пути: $COMMON_LIB"
    exit 1
fi

source "$COMMON_LIB"

# Конфигурационные переменные
CONFIG_DIR="/opt/matrix-install"
ELEMENT_DIR="/var/www/element"
ELEMENT_CONFIG_FILE="$ELEMENT_DIR/config.json"
ELEMENT_BACKUP_DIR="$ELEMENT_DIR/backups"
ELEMENT_TEMP_DIR="/tmp/element-installation"
LATEST_VERSION=""

# Функция получения конфигурации домена
get_domain_config() {
    local domain_file="$CONFIG_DIR/domain"
    local element_domain_file="$CONFIG_DIR/element_domain"
    
    # Основной домен Matrix
    if [[ -f "$domain_file" ]]; then
        MATRIX_DOMAIN=$(cat "$domain_file")
        log "INFO" "Основной домен Matrix: $MATRIX_DOMAIN"
    else
        log "ERROR" "Не найден файл с доменом Matrix сервера"
        return 1
    fi
    
    # Домен Element Web
    if [[ -f "$element_domain_file" ]]; then
        ELEMENT_DOMAIN=$(cat "$element_domain_file")
        log "INFO" "Домен Element Web: $ELEMENT_DOMAIN"
    else
        # Автоматическое определение домена Element на основе типа сервера
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                ELEMENT_DOMAIN="element.${MATRIX_DOMAIN#*.}"
                ;;
            *)
                ELEMENT_DOMAIN="element.${MATRIX_DOMAIN}"
                ;;
        esac
        echo "$ELEMENT_DOMAIN" > "$element_domain_file"
        log "INFO" "Автоматически определён домен Element Web: $ELEMENT_DOMAIN"
    fi
    
    export MATRIX_DOMAIN ELEMENT_DOMAIN
}

# Функция проверки зависимостей Element Web
check_element_dependencies() {
    log "INFO" "Проверка зависимостей для Element Web..."
    
    local required_tools=("curl" "jq" "tar" "wget" "unzip")
    local missing_tools=()
    
    # Для хостинга добавляем nginx
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        required_tools+=("nginx")
    fi
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "INFO" "Установка отсутствующих зависимостей: ${missing_tools[*]}"
        if ! apt update && apt install -y "${missing_tools[@]}"; then
            log "ERROR" "Не удалось установить зависимости"
            return 1
        fi
    fi
    
    log "SUCCESS" "Все зависимости доступны"
    return 0
}

# Функция получения последней версии Element Web
get_latest_element_version() {
    log "INFO" "Получение информации о последней версии Element Web..."
    
    if ! check_internet; then
        log "ERROR" "Нет подключения к интернету"
        return 1
    fi
    
    # Попытка получить версию через GitHub API
    LATEST_VERSION=$(curl -s --connect-timeout 10 \
        "https://api.github.com/repos/element-hq/element-web/releases/latest" | \
        jq -r '.tag_name // empty' 2>/dev/null)
    
    # Если не удалось через API, пробуем альтернативный способ
    if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
        log "WARN" "GitHub API недоступен, пробуем альтернативный способ..."
        LATEST_VERSION=$(curl -s --connect-timeout 10 \
            "https://github.com/element-hq/element-web/releases/latest" | \
            grep -oP 'tag/\K[^"]+' | head -1)
    fi
    
    if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
        log "ERROR" "Не удалось получить информацию о последней версии"
        return 1
    fi
    
    log "INFO" "Последняя версия Element Web: $LATEST_VERSION"
    return 0
}

# Функция проверки установленной версии Element Web
check_installed_version() {
    local version_file="$ELEMENT_DIR/version"
    
    if [[ -f "$version_file" ]]; then
        local installed_version=$(cat "$version_file" 2>/dev/null)
        if [[ -n "$installed_version" ]]; then
            log "INFO" "Установленная версия Element Web: $installed_version"
            
            # Сравнение версий
            if [[ "$installed_version" == "$LATEST_VERSION" ]]; then
                log "INFO" "Установлена актуальная версия Element Web"
                return 0
            else
                log "INFO" "Доступно обновление: $installed_version → $LATEST_VERSION"
                return 1
            fi
        fi
    fi
    
    log "INFO" "Element Web не установлен или версия неизвестна"
    return 2
}

# Функция создания директорий
create_element_directories() {
    log "INFO" "Создание директорий для Element Web..."
    
    local dirs=(
        "$ELEMENT_DIR"
        "$ELEMENT_BACKUP_DIR"
        "$ELEMENT_TEMP_DIR"
        "/var/log/element"
    )
    
    for dir in "${dirs[@]}"; do
        if ! mkdir -p "$dir"; then
            log "ERROR" "Не удалось создать директорию: $dir"
            return 1
        fi
    done
    
    # Установка прав доступа
    chown -R www-data:www-data "$ELEMENT_DIR"
    chmod -R 755 "$ELEMENT_DIR"
    
    log "SUCCESS" "Директории созданы успешно"
    return 0
}

# Функция загрузки Element Web
download_element_web() {
    log "INFO" "Загрузка Element Web версии $LATEST_VERSION..."
    
    local download_url="https://github.com/element-hq/element-web/releases/download/${LATEST_VERSION}/element-${LATEST_VERSION}.tar.gz"
    local archive_file="$ELEMENT_TEMP_DIR/element-${LATEST_VERSION}.tar.gz"
    
    # Очистка временной директории
    rm -rf "$ELEMENT_TEMP_DIR"/*
    
    # Загрузка с retry логикой
    local attempts=3
    for ((i=1; i<=attempts; i++)); do
        log "INFO" "Попытка загрузки $i/$attempts..."
        
        if wget --quiet --show-progress --timeout=30 --tries=3 \
               -O "$archive_file" "$download_url"; then
            log "SUCCESS" "Element Web успешно загружен"
            break
        elif [[ $i -eq $attempts ]]; then
            log "ERROR" "Не удалось загрузить Element Web после $attempts попыток"
            return 1
        fi
        
        log "WARN" "Попытка $i не удалась, повтор через 5 секунд..."
        sleep 5
    done
    
    # Проверка целостности архива
    if ! tar -tzf "$archive_file" >/dev/null 2>&1; then
        log "ERROR" "Загруженный архив повреждён"
        return 1
    fi
    
    log "SUCCESS" "Архив Element Web загружен и проверен"
    return 0
}

# Функция извлечения и установки Element Web
extract_element_web() {
    log "INFO" "Извлечение и установка Element Web..."
    
    local archive_file="$ELEMENT_TEMP_DIR/element-${LATEST_VERSION}.tar.gz"
    local extract_dir="$ELEMENT_TEMP_DIR/extracted"
    
    # Создание директории для извлечения
    mkdir -p "$extract_dir"
    
    # Извлечение архива
    if ! tar -xzf "$archive_file" -C "$extract_dir" --strip-components=1; then
        log "ERROR" "Ошибка извлечения архива Element Web"
        return 1
    fi
    
    # Резервная копия существующей установки
    if [[ -d "$ELEMENT_DIR" ]] && [[ -n "$(ls -A "$ELEMENT_DIR" 2>/dev/null)" ]]; then
        local backup_name="element-backup-$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Создание резервной копии: $backup_name"
        
        if ! cp -r "$ELEMENT_DIR" "$ELEMENT_BACKUP_DIR/$backup_name"; then
            log "WARN" "Не удалось создать резервную копию, продолжаем..."
        else
            log "SUCCESS" "Резервная копия создана: $ELEMENT_BACKUP_DIR/$backup_name"
        fi
    fi
    
    # Копирование новых файлов
    log "INFO" "Копирование файлов Element Web..."
    
    # Очистка старых файлов (кроме config.json и директории backups)
    find "$ELEMENT_DIR" -mindepth 1 -maxdepth 1 \
         ! -name "config.json" ! -name "backups" ! -name "version" \
         -exec rm -rf {} + 2>/dev/null || true
    
    # Копирование новых файлов
    if ! cp -r "$extract_dir"/* "$ELEMENT_DIR/"; then
        log "ERROR" "Ошибка копирования файлов Element Web"
        return 1
    fi
    
    # Сохранение информации о версии
    echo "$LATEST_VERSION" > "$ELEMENT_DIR/version"
    
    # Установка прав доступа
    chown -R www-data:www-data "$ELEMENT_DIR"
    find "$ELEMENT_DIR" -type d -exec chmod 755 {} \;
    find "$ELEMENT_DIR" -type f -exec chmod 644 {} \;
    
    log "SUCCESS" "Element Web успешно установлен"
    return 0
}

# Функция создания конфигурации Element Web
create_element_config() {
    log "INFO" "Создание конфигурации Element Web..."
    
    # Резервная копия существующей конфигурации
    if [[ -f "$ELEMENT_CONFIG_FILE" ]]; then
        backup_file "$ELEMENT_CONFIG_FILE" "element-config"
    fi
    
    # Определение homeserver URL в зависимости от типа сервера
    local homeserver_url="https://$MATRIX_DOMAIN"
    
    # Настройки в зависимости от типа сервера
    local room_directory_servers='["'$MATRIX_DOMAIN'"]'
    local mobile_guide_toast='true'
    local disable_custom_urls='false'
    local integrations_enabled='true'
    
    # Адаптация настроек для различных типов серверов
    case "$SERVER_TYPE" in
        "home_server"|"proxmox"|"docker"|"openvz")
            mobile_guide_toast='false'  # Отключаем для локальных серверов
            disable_custom_urls='true'  # Упрощаем для домашних установок
            integrations_enabled='false'  # Отключаем интеграции для локальных серверов
            log "INFO" "Настройки адаптированы для локального/домашнего сервера"
            ;;
        "hosting"|"vps")
            mobile_guide_toast='true'
            disable_custom_urls='false'
            integrations_enabled='true'
            log "INFO" "Настройки адаптированы для облачного хостинга"
            ;;
    esac
    
    # Создание конфигурации с учетом типа сервера
    cat > "$ELEMENT_CONFIG_FILE" <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "$homeserver_url",
            "server_name": "$MATRIX_DOMAIN"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "disable_custom_urls": $disable_custom_urls,
    "disable_guests": true,
    "disable_login_language_selector": false,
    "disable_3pid_login": false,
    "brand": "Element",
    "integrations_ui_url": $([ "$integrations_enabled" = "true" ] && echo '"https://scalar.vector.im/"' || echo 'null'),
    "integrations_rest_url": $([ "$integrations_enabled" = "true" ] && echo '"https://scalar.vector.im/api"' || echo 'null'),
    "integrations_widgets_urls": $([ "$integrations_enabled" = "true" ] && echo '[
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api"
    ]' || echo '[]'),
    "default_country_code": "RU",
    "show_labs_settings": true,
    "features": {
        "feature_pinning": true,
        "feature_custom_status": true,
        "feature_custom_tags": true,
        "feature_state_counters": true,
        "feature_many_integration_managers": $integrations_enabled,
        "feature_mjolnir": true,
        "feature_dm_verification": true,
        "feature_bridge_state": true,
        "feature_groups": true,
        "feature_custom_themes": true
    },
    "default_theme": "light",
    "room_directory": {
        "servers": $room_directory_servers
    },
    "enable_presence_by_hs_url": {
        "$homeserver_url": true
    },
    "terms_and_conditions_links": [
        {
            "text": "Privacy Policy",
            "url": "https://element.io/privacy"
        },
        {
            "text": "Cookie Policy", 
            "url": "https://element.io/cookie-policy"
        }
    ],
    "mobile_guide_toast": $mobile_guide_toast,
    "desktop_builds": {
        "available": true,
        "logo": "themes/element/img/logos/element-logo.svg",
        "url": "https://element.io/get-started"
    },
    "mobile_builds": {
        "ios": "https://apps.apple.com/app/vector/id1083446067",
        "android": "https://play.google.com/store/apps/details?id=im.vector.app",
        "fdroid": "https://f-droid.org/packages/im.vector.app/"
    },
    "jitsi": {
        "preferred_domain": "meet.element.io"
    },
    "element_call": {
        "use_exclusively": false,
        "participant_limit": 8,
        "brand": "Element Call"
    },
    "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=get_your_own_OpIi9ZULNHzrAhtHqqKZ",
    "setting_defaults": {
        "breadcrumbs": true,
        "MessageComposerInput.showStickersButton": true,
        "MessageComposerInput.showPollsButton": true,
        "showReadReceipts": true,
        "showTwelveHourTimestamps": false,
        "alwaysShowTimestamps": false,
        "showRedactions": true,
        "enableSyntaxHighlightLanguageDetection": true,
        "expandCodeByDefault": false,
        "scrollToBottomOnMessageSent": true,
        "Pill.shouldShowPillAvatar": true,
        "Pill.shouldShowTooltip": true,
        "TextualBody.enableBigEmoji": true,
        "VideoView.flipVideoHorizontally": false
    },
    "posthog": {
        "project_api_key": null,
        "api_host": null
    },
    "privacy_policy_url": "https://element.io/privacy",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "uisi_autorageshake_app": "element-auto-uisi",
    "showLabsSettings": true,
    "piwik": false
}
EOF

    # Проверка синтаксиса JSON
    if ! jq empty "$ELEMENT_CONFIG_FILE" 2>/dev/null; then
        log "ERROR" "Ошибка в синтаксе конфигурационного файла JSON"
        return 1
    fi
    
    # Установка прав доступа
    chown www-data:www-data "$ELEMENT_CONFIG_FILE"
    chmod 644 "$ELEMENT_CONFIG_FILE"
    
    log "SUCCESS" "Конфигурация Element Web создана для типа сервера: $SERVER_TYPE"
    return 0
}

# Функция генерации конфигурации Element Web для Proxmox
generate_proxmox_element_config() {
    print_header "ГЕНЕРАЦИЯ КОНФИГУРАЦИИ ELEMENT WEB ДЛЯ PROXMOX" "$CYAN"
    
    log "INFO" "Генерация конфигурации Element Web для Proxmox хоста..."
    
    # Создание директории для конфигураций
    mkdir -p "$CONFIG_DIR/proxmox"
    
    # Генерация Caddy конфигурации для хоста Proxmox
    local proxmox_caddy_config="$CONFIG_DIR/proxmox/caddy-element-web.conf"
    cat > "$proxmox_caddy_config" <<EOF
# Caddy Configuration for Element Web (Proxmox Host)
# Generated by Matrix Setup Tool v4.0
# Element VM IP: ${LOCAL_IP:-192.168.88.165}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Element Web Client
$ELEMENT_DOMAIN {
    tls /etc/letsencrypt/live/${MATRIX_DOMAIN#*.}/fullchain.pem /etc/letsencrypt/live/${MATRIX_DOMAIN#*.}/privkey.pem
    
    reverse_proxy ${LOCAL_IP:-192.168.88.165}:80 {
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Port {server_port}
        
        # Таймауты
        transport http {
            dial_timeout 30s
            response_header_timeout 30s
            read_timeout 30s
        }
    }
    
    # Cache control for static assets
    header /bundles/* Cache-Control "public, max-age=31536000, immutable"
    header /assets/* Cache-Control "public, max-age=31536000, immutable"
    header /index.html Cache-Control "no-cache, no-store, must-revalidate"
    header /config.json Cache-Control "no-cache"
    
    # Security headers for web client
    header {
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' https:; frame-src 'self'; worker-src 'self';"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Server-Type "proxmox-host"
        X-Element-VM "${LOCAL_IP:-192.168.88.165}"
    }
    
    # Логирование
    log {
        output file /var/log/caddy/element-access.log
    }
}
EOF

    # Также генерируем совместимую Nginx конфигурацию (на случай если пользователь предпочтет Nginx)
    local proxmox_nginx_config="$CONFIG_DIR/proxmox/nginx-element-web.conf"
    cat > "$proxmox_nginx_config" <<EOF
# Nginx Configuration for Element Web (Proxmox Host)
# Generated by Matrix Setup Tool v4.0
# Element VM IP: ${LOCAL_IP:-192.168.88.165}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# NOTE: Рекомендуется использовать Caddy конфигурацию вместо Nginx

server {
    listen 80;
    listen [::]:80;
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $ELEMENT_DOMAIN;
    
    # Redirect all HTTP requests to HTTPS
    if (\$scheme = http) {
        return 301 https://\$server_name\$request_uri;
    }
    
    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/${MATRIX_DOMAIN#*.}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MATRIX_DOMAIN#*.}/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    
    # Modern configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    
    # Server type identification
    add_header X-Server-Type "proxmox-host" always;
    add_header X-Element-VM "${LOCAL_IP:-192.168.88.165}" always;
    
    # Logs
    access_log /var/log/nginx/element-access.log;
    error_log /var/log/nginx/element-error.log warn;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        application/javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rss+xml
        application/vnd.geo+json
        application/vnd.ms-fontobject
        application/x-font-ttf
        application/x-web-app-manifest+json
        font/opentype
        image/bmp
        image/svg+xml
        image/x-icon
        text/cache-manifest
        text/css
        text/plain
        text/vcard
        text/vnd.rim.location.xloc
        text/vtt
        text/x-component
        text/x-cross-domain-policy;
    
    # Проксирование на Element Web VM
    location / {
        proxy_pass http://${LOCAL_IP:-192.168.88.165}:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # Таймауты
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        # Буферизация
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        
        # WebSocket поддержка (если нужно)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # Специальные заголовки для config.json
    location /config.json {
        proxy_pass http://${LOCAL_IP:-192.168.88.165}:80/config.json;
        proxy_set_header Host \$host;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    # Security: deny access to sensitive files
    location ~ /\.(ht|git|svn) {
        deny all;
        return 404;
    }
}
EOF

    # Генерация Element Web конфигурации для VM
    local element_config_for_vm="$CONFIG_DIR/proxmox/element-config.json"
    cat > "$element_config_for_vm" <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$MATRIX_DOMAIN",
            "server_name": "$MATRIX_DOMAIN"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "disable_custom_urls": true,
    "disable_guests": true,
    "disable_login_language_selector": false,
    "disable_3pid_login": false,
    "brand": "Element",
    "integrations_ui_url": null,
    "integrations_rest_url": null,
    "integrations_widgets_urls": [],
    "default_country_code": "RU",
    "show_labs_settings": true,
    "features": {
        "feature_pinning": true,
        "feature_custom_status": true,
        "feature_custom_tags": true,
        "feature_state_counters": true,
        "feature_many_integration_managers": false,
        "feature_mjolnir": true,
        "feature_dm_verification": true,
        "feature_bridge_state": true,
        "feature_groups": true,
        "feature_custom_themes": true
    },
    "default_theme": "light",
    "room_directory": {
        "servers": ["$MATRIX_DOMAIN"]
    },
    "enable_presence_by_hs_url": {
        "https://$MATRIX_DOMAIN": true
    },
    "terms_and_conditions_links": [
        {
            "text": "Privacy Policy",
            "url": "https://element.io/privacy"
        },
        {
            "text": "Cookie Policy", 
            "url": "https://element.io/cookie-policy"
        }
    ],
    "mobile_guide_toast": false,
    "desktop_builds": {
        "available": true,
        "logo": "themes/element/img/logos/element-logo.svg",
        "url": "https://element.io/get-started"
    },
    "mobile_builds": {
        "ios": "https://apps.apple.com/app/vector/id1083446067",
        "android": "https://play.google.com/store/apps/details?id=im.vector.app",
        "fdroid": "https://f-droid.org/packages/im.vector.app/"
    },
    "jitsi": {
        "preferred_domain": "meet.element.io"
    },
    "element_call": {
        "use_exclusively": false,
        "participant_limit": 8,
        "brand": "Element Call"
    },
    "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=get_your_own_OpIi9ZULNHzrAhtHqqKZ",
    "setting_defaults": {
        "breadcrumbs": true,
        "MessageComposerInput.showStickersButton": true,
        "MessageComposerInput.showPollsButton": true,
        "showReadReceipts": true,
        "showTwelveHourTimestamps": false,
        "alwaysShowTimestamps": false,
        "showRedactions": true,
        "enableSyntaxHighlightLanguageDetection": true,
        "expandCodeByDefault": false,
        "scrollToBottomOnMessageSent": true,
        "Pill.shouldShowPillAvatar": true,
        "Pill.shouldShowTooltip": true,
        "TextualBody.enableBigEmoji": true,
        "VideoView.flipVideoHorizontally": false
    },
    "posthog": {
        "project_api_key": null,
        "api_host": null
    },
    "privacy_policy_url": "https://element.io/privacy",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "uisi_autorageshake_app": "element-auto-uisi",
    "showLabsSettings": true,
    "piwik": false
}
EOF

    # Генерация простой Nginx конфигурации для VM
    local vm_nginx_config="$CONFIG_DIR/proxmox/vm-nginx-element.conf"
    cat > "$vm_nginx_config" <<EOF
# Nginx Configuration for Element Web VM (Simple HTTP server)
# This file should be placed as /etc/nginx/sites-available/element-web on VM
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    server_name $ELEMENT_DOMAIN localhost ${LOCAL_IP:-192.168.88.165};
    
    # Document root
    root $ELEMENT_DIR;
    index index.html;
    
    # Server identification
    add_header X-Server-Type "element-vm" always;
    add_header X-Element-Version "{{ELEMENT_VERSION}}" always;
    
    # Logs
    access_log /var/log/nginx/element-vm-access.log;
    error_log /var/log/nginx/element-vm-error.log warn;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        application/javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rss+xml
        application/vnd.geo+json
        application/vnd.ms-fontobject
        application/x-font-ttf
        application/x-web-app-manifest+json
        font/opentype
        image/bmp
        image/svg+xml
        image/x-icon
        text/cache-manifest
        text/css
        text/plain
        text/vcard
        text/vnd.rim.location.xloc
        text/vtt
        text/x-component
        text/x-cross-domain-policy;
    
    # Cache control for static assets
    location /bundles/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    location /config.json {
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    # Prevent caching of the service worker
    location /sw.js {
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
    }
    
    # Main location block
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
    }
    
    # Security: deny access to sensitive files
    location ~ /\.(ht|git|svn) {
        deny all;
        return 404;
    }
    
    # Security: deny access to backup files
    location ~ \.(bak|backup|old|orig|save)$ {
        deny all;
        return 404;
    }
}
EOF

    # Генерация инструкций по установке
    local instructions_file="$CONFIG_DIR/proxmox/element-web-setup-instructions.txt"
    cat > "$instructions_file" <<EOF
# ИНСТРУКЦИИ ПО НАСТРОЙКЕ ELEMENT WEB ДЛЯ PROXMOX

Дата генерации: $(date '+%Y-%m-%d %H:%M:%S')
Element VM IP: ${LOCAL_IP:-192.168.88.165}
Matrix домен: $MATRIX_DOMAIN
Element домен: $ELEMENT_DOMAIN

## АРХИТЕКТУРА

┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Пользователь  │    │  Proxmox хост   │    │   Matrix VM     │
│                 │───▶│   (Caddy SSL)   │───▶│ (Element HTTP)  │
│ element.domain  │    │ SSL терминация  │    │   простой HTTP  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        HTTPS                   Proxy                  HTTP

## ЭТАП 1: НАСТРОЙКА НА VM (этот сервер)

### 1.1. Установка Element Web на VM
# Продолжите установку Element Web обычным способом:
sudo ./modules/element_web.sh

### 1.2. Применение VM конфигурации
sudo cp $vm_nginx_config /etc/nginx/sites-available/element-web
sudo ln -sf /etc/nginx/sites-available/element-web /etc/nginx/sites-enabled/element-web
sudo cp $element_config_for_vm $ELEMENT_CONFIG_FILE

### 1.3. Настройка простого HTTP на VM
# Замените SSL конфигурацию на простой HTTP
sudo nginx -t && sudo systemctl reload nginx

### 1.4. Проверка работы на VM
curl -I http://${LOCAL_IP:-192.168.88.165}
curl http://${LOCAL_IP:-192.168.88.165}/config.json

## ЭТАП 2: НАСТРОЙКА НА PROXMOX ХОСТЕ

### 2.1. РЕКОМЕНДУЕТСЯ: Использование Caddy (интеграция с Matrix Setup)

#### 2.1.1. Добавьте конфигурацию Element Web в основной Caddyfile
sudo cat $proxmox_caddy_config >> /etc/caddy/Caddyfile

#### 2.1.2. Или добавьте в отдельный файл и включите в основную конфигурацию
sudo cp $proxmox_caddy_config /etc/caddy/sites/element-web.caddy
echo "import sites/*" >> /etc/caddy/Caddyfile

#### 2.1.3. Проверьте и перезагрузите Caddy
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

### 2.2. АЛЬТЕРНАТИВА: Использование Nginx (если нет Caddy)

#### 2.2.1. Установка Nginx на хосте (если не установлен)
sudo apt update
sudo apt install nginx

#### 2.2.2. Копирование конфигурации на хост
sudo cp $proxmox_nginx_config /etc/nginx/sites-available/element-web
sudo ln -sf /etc/nginx/sites-available/element-web /etc/nginx/sites-enabled/element-web

#### 2.2.3. Проверка и запуск Nginx
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl start nginx

### 2.3. Получение SSL сертификатов на хосте

Вариант A: Let's Encrypt (для Caddy автоматически)
# Caddy автоматически получит сертификаты при первом запросе

Вариант B: Let's Encrypt (для Nginx)
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d $ELEMENT_DOMAIN

Вариант C: Cloudflare wildcard
sudo apt install certbot python3-certbot-dns-cloudflare
sudo mkdir -p /etc/cloudflare
echo "dns_cloudflare_api_token = ВАШ_API_ТОКЕН" | sudo tee /etc/cloudflare/cloudflare.ini
sudo chmod 600 /etc/cloudflare/cloudflare.ini

sudo certbot certonly \\
  --dns-cloudflare \\
  --dns-cloudflare-credentials /etc/cloudflare/cloudflare.ini \\
  -d "${MATRIX_DOMAIN#*.}" \\
  -d "*.${MATRIX_DOMAIN#*.}" \\
  --register-unsafely-without-email

### 2.4. Настройка файрвола на хосте
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

## ЭТАП 3: НАСТРОЙКА DNS

### 3.1. A запись для Element Web
$ELEMENT_DOMAIN → IP_хоста_Proxmox

### 3.2. Проверка доступности
curl -I https://$ELEMENT_DOMAIN
curl https://$ELEMENT_DOMAIN/config.json

## ДИАГНОСТИКА

### На VM:
# Проверка Element Web
curl -I http://${LOCAL_IP:-192.168.88.165}
sudo systemctl status nginx
sudo ss -tlnp | grep :80

### На хосте (Caddy):
# Проверка проксирования
curl -I https://$ELEMENT_DOMAIN
sudo journalctl -u caddy -f
sudo ss -tlnp | grep -E ':(80|443)'

# Проверка доступности VM с хоста
curl -I http://${LOCAL_IP:-192.168.88.165}

### На хосте (Nginx):
# Проверка проксирования
curl -I https://$ELEMENT_DOMAIN
sudo journalctl -u nginx -f
sudo ss -tlnp | grep -E ':(80|443)'

### Проверка цепочки:
1. DNS: $ELEMENT_DOMAIN → IP хоста
2. Хост: HTTPS/SSL терминация (Caddy или Nginx)
3. Проксирование: хост → VM:80
4. VM: Простой HTTP с Element Web

## ИНТЕГРАЦИЯ С MATRIX SETUP

### Рекомендуемый способ: Использование caddy_config.sh
# Element Web будет автоматически интегрирован в общую конфигурацию Caddy
sudo ./modules/caddy_config.sh

### Ручное добавление в Caddyfile:
# Если используете caddy_config.sh, Element Web будет добавлен автоматически
# при настройке общей конфигурации Matrix сервера

## ВАЖНЫЕ ЗАМЕЧАНИЯ:

1. VM работает только по HTTP (порт 80)
2. Хост обеспечивает SSL терминацию (Caddy рекомендуется)
3. Проксирование происходит по внутренней сети
4. Element Web доступен только через хост
5. Конфигурация Element указывает на Matrix сервер
6. ⚡ CADDY ИНТЕГРИРУЕТСЯ С ОСНОВНОЙ НАСТРОЙКОЙ MATRIX

EOF

    log "SUCCESS" "Конфигурация Element Web для Proxmox сгенерирована:"
    safe_echo "${BLUE}   📄 Caddy для хоста: $proxmox_caddy_config${NC}"
    safe_echo "${BLUE}   📄 Nginx для хоста (альтернатива): $proxmox_nginx_config${NC}"
    safe_echo "${BLUE}   📄 Nginx для VM: $vm_nginx_config${NC}"
    safe_echo "${BLUE}   📄 Element config: $element_config_for_vm${NC}"
    safe_echo "${BLUE}   📋 Инструкции: $instructions_file${NC}"
    
    return 0
}

# Функция показа конфигурации для Proxmox
show_proxmox_element_config() {
    local instructions_file="$CONFIG_DIR/proxmox/element-web-setup-instructions.txt"
    
    if [[ ! -f "$instructions_file" ]]; then
        log "ERROR" "Конфигурация Element Web для Proxmox не найдена. Сгенерируйте её сначала."
        return 1
    fi
    
    print_header "НАСТРОЙКА ELEMENT WEB ДЛЯ PROXMOX" "$CYAN"
    
    safe_echo "${BOLD}🏗️ АРХИТЕКТУРА ELEMENT WEB В PROXMOX:${NC}"
    echo
    safe_echo "${GREEN}┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐${NC}"
    safe_echo "${GREEN}│   Пользователь  │    │  Proxmox хост   │    │   Matrix VM     │${NC}"
    safe_echo "${GREEN}│                 │───▶│   (Caddy SSL)   │───▶│ (Element HTTP)  │${NC}"
    safe_echo "${GREEN}│ element.domain  │    │ SSL терминация  │    │   простой HTTP  │${NC}"
    safe_echo "${GREEN}└─────────────────┘    └─────────────────┘    └─────────────────┘${NC}"
    safe_echo "${GREEN}        HTTPS                   Proxy                  HTTP${NC}"
    echo
    
    safe_echo "${YELLOW}📝 КЛЮЧЕВЫЕ ОСОБЕННОСТИ:${NC}"
    safe_echo "1. ${BOLD}Element Web устанавливается на VM${NC} (этот сервер)"
    safe_echo "2. ${BOLD}Nginx на VM работает только по HTTP${NC} (порт 80)"
    safe_echo "3. ${BOLD}Caddy на хосте Proxmox${NC} обеспечивает SSL и проксирование"
    safe_echo "4. ${BOLD}Доступ только через хост${NC} - прямого доступа к VM нет"
    safe_echo "5. ${BOLD}Интеграция с caddy_config.sh${NC} для единой настройки"
    echo
    
    safe_echo "${BLUE}📋 Домены:${NC}"
    safe_echo "   • Element Web: ${ELEMENT_DOMAIN}"
    safe_echo "   • VM IP: ${LOCAL_IP:-192.168.88.165}"
    safe_echo "   • Matrix: ${MATRIX_DOMAIN}"
    echo
    
    safe_echo "${BOLD}⚡ РЕКОМЕНДУЕМАЯ НАСТРОЙКА:${NC}"
    safe_echo "${GREEN}1. Используйте Caddy конфигурацию (совместимость с Matrix Setup)${NC}"
    safe_echo "${GREEN}2. Интегрируйте с основным Caddyfile через caddy_config.sh${NC}"
    safe_echo "${GREEN}3. Автоматическое получение SSL сертификатов${NC}"
    echo
    
    safe_echo "${YELLOW}💡 CADDY КОНФИГУРАЦИЯ ДЛЯ ХОСТА:${NC}"
    local caddy_config="$CONFIG_DIR/proxmox/caddy-element-web.conf"
    if [[ -f "$caddy_config" ]]; then
        safe_echo "${BLUE}   Добавьте в /etc/caddy/Caddyfile:${NC}"
        echo
        safe_echo "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        head -20 "$caddy_config" | tail -15
        safe_echo "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo
    fi
    
    safe_echo "${BOLD}📋 ИНСТРУКЦИИ СОХРАНЕНЫ В:${NC}"
    safe_echo "${BLUE}$instructions_file${NC}"
    echo
    safe_echo "${YELLOW}Используйте: cat $instructions_file${NC}"
    echo
    
    safe_echo "${BOLD}🔧 БЫСТРАЯ НАСТРОЙКА:${NC}"
    safe_echo "${BLUE}# На хосте Proxmox:${NC}"
    safe_echo "${YELLOW}sudo cat $CONFIG_DIR/proxmox/caddy-element-web.conf >> /etc/caddy/Caddyfile${NC}"
    safe_echo "${YELLOW}sudo caddy validate --config /etc/caddy/Caddyfile${NC}"
    safe_echo "${YELLOW}sudo systemctl reload caddy${NC}"
    
    return 0
}

# Функция настройки веб-сервера для Element Web
configure_web_server() {
    log "INFO" "Настройка веб-сервера для Element Web..."
    
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            # Для Proxmox настраиваем простой HTTP сервер на VM
            configure_vm_web_server
            ;;
        *)
            # Для хостинга стандартная конфигурация с SSL
            configure_hosting_web_server
            ;;
    esac
}

# Функция настройки простого веб-сервера для VM
configure_vm_web_server() {
    log "INFO" "Настройка простого HTTP сервера для Element Web на VM..."
    
    local nginx_config="/etc/nginx/sites-available/element-web"
    local nginx_enabled="/etc/nginx/sites-enabled/element-web"
    
    # Создание простой HTTP конфигурации для VM
    cat > "$nginx_config" <<EOF
# Nginx Configuration for Element Web VM (Simple HTTP server)
# Generated by Matrix Setup Tool v4.0
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    server_name $ELEMENT_DOMAIN localhost ${LOCAL_IP:-192.168.88.165};
    
    # Document root
    root $ELEMENT_DIR;
    index index.html;
    
    # Server identification
    add_header X-Server-Type "element-vm" always;
    add_header X-Element-Version "{{ELEMENT_VERSION}}" always;
    
    # Logs
    access_log /var/log/nginx/element-vm-access.log;
    error_log /var/log/nginx/element-vm-error.log warn;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        application/javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rss+xml
        application/vnd.geo+json
        application/vnd.ms-fontobject
        application/x-font-ttf
        application/x-web-app-manifest+json
        font/opentype
        image/bmp
        image/svg+xml
        image/x-icon
        text/cache-manifest
        text/css
        text/plain
        text/vcard
        text/vnd.rim.location.xloc
        text/vtt
        text/x-component
        text/x-cross-domain-policy;
    
    # Cache control for static assets
    location /bundles/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    location /config.json {
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    # Prevent caching of the service worker
    location /sw.js {
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
    }
    
    # Main location block
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
    }
    
    # Security: deny access to sensitive files
    location ~ /\.(ht|git|svn) {
        deny all;
        return 404;
    }
    
    # Security: deny access to backup files
    location ~ \.(bak|backup|old|orig|save)$ {
        deny all;
        return 404;
    }
}
EOF

    # Включение сайта
    if [[ ! -L "$nginx_enabled" ]]; then
        ln -s "$nginx_config" "$nginx_enabled"
    fi
    
    # Проверка конфигурации Nginx
    if ! nginx -t; then
        log "ERROR" "Ошибка в конфигурации Nginx"
        return 1
    fi
    
    log "SUCCESS" "Простой HTTP сервер настроен для Element Web на VM"
    return 0
}

# Функция настройки веб-сервера для хостинга
configure_hosting_web_server() {
    log "INFO" "Настройка веб-сервера для Element Web на хостинге..."
    
    local nginx_config="/etc/nginx/sites-available/element-web"
    local nginx_enabled="/etc/nginx/sites-enabled/element-web"
    
    # Создание конфигурации Nginx для хостинга
    cat > "$nginx_config" <<EOF
server {
    listen 80;
    listen [::]:80;
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $ELEMENT_DOMAIN;
    
    # Redirect all HTTP requests to HTTPS
    if (\$scheme = http) {
        return 301 https://\$server_name\$request_uri;
    }
    
    # SSL Configuration
    ssl_certificate /etc/ssl/certs/element.crt;
    ssl_certificate_key /etc/ssl/private/element.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    
    # Modern configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    
    # Server type identification
    add_header X-Server-Type "$SERVER_TYPE" always;
    
    # Document root
    root $ELEMENT_DIR;
    index index.html;
    
    # Logs
    access_log /var/log/nginx/element-access.log;
    error_log /var/log/nginx/element-error.log warn;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        application/javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rss+xml
        application/vnd.geo+json
        application/vnd.ms-fontobject
        application/x-font-ttf
        application/x-web-app-manifest+json
        font/opentype
        image/bmp
        image/svg+xml
        image/x-icon
        text/cache-manifest
        text/css
        text/plain
        text/vcard
        text/vnd.rim.location.xloc
        text/vtt
        text/x-component
        text/x-cross-domain-policy;
    
    # Cache control for static assets
    location /bundles/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    location /config.json {
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    # Prevent caching of the service worker
    location /sw.js {
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
    }
    
    # Main location block
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
    }
    
    # Security: deny access to .htaccess files
    location ~ /\.ht {
        deny all;
    }
    
    # Security: deny access to backup files
    location ~ \.(bak|backup|old|orig|save)$ {
        deny all;
        return 404;
    }
}
EOF

    # Включение сайта
    if [[ ! -L "$nginx_enabled" ]]; then
        ln -s "$nginx_config" "$nginx_enabled"
    fi
    
    # Проверка конфигурации Nginx
    if ! nginx -t; then
        log "ERROR" "Ошибка в конфигурации Nginx"
        return 1
    fi
    
    log "SUCCESS" "Конфигурация веб-сервера создана для хостинга"
    return 0
}

# Функция проверки работоспособности Element Web
test_element_web() {
    log "INFO" "Проверка работоспособности Element Web..."
    
    # Адаптируем URL для тестирования в зависимости от типа сервера
    local test_url
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            # Для VM тестируем только HTTP
            test_url="http://${LOCAL_IP:-127.0.0.1}"
            log "INFO" "Тестируется простой HTTP сервер на VM для проксирования с хоста"
            ;;
        *)
            # Для облачных серверов стандартный localhost
            test_url="http://localhost"
            ;;
    esac
    
    local max_attempts=10
    local attempt=1
    
    # Проверка Nginx
    if ! systemctl is-active --quiet nginx; then
        log "WARN" "Nginx не запущен, попытка запуска..."
        if ! systemctl start nginx; then
            log "ERROR" "Не удалось запустить Nginx"
            return 1
        fi
    fi
    
    # Ожидание запуска сервиса
    log "INFO" "Ожидание запуска веб-сервера..."
    sleep 5
    
    # Проверка доступности
    while [[ $attempt -le $max_attempts ]]; do
        log "INFO" "Попытка подключения $attempt/$max_attempts к $test_url..."
        
        if curl -sf --connect-timeout 5 "$test_url" >/dev/null 2>&1; then
            log "SUCCESS" "Element Web отвечает на запросы"
            break
        elif [[ $attempt -eq $max_attempts ]]; then
            log "ERROR" "Element Web недоступен после $max_attempts попыток"
            log "INFO" "Проверьте настройки сети для типа сервера: $SERVER_TYPE"
            if [[ "$SERVER_TYPE" =~ ^(proxmox|home_server|docker|openvz)$ ]]; then
                log "INFO" "Для Proxmox: Element Web должен быть доступен с хоста Proxmox"
            fi
            return 1
        fi
        
        sleep 3
        ((attempt++))
    done
    
    # Проверка конфигурационного файла
    if curl -sf "${test_url}/config.json" >/dev/null 2>&1; then
        log "SUCCESS" "Конфигурационный файл доступен"
    else
        log "WARN" "Конфигурационный файл недоступен"
    fi
    
    return 0
}

# Функция обновления Element Web
update_element_web() {
    print_header "ОБНОВЛЕНИЕ ELEMENT WEB" "$YELLOW"
    
    log "INFO" "Начинаем обновление Element Web..."
    
    # Проверка текущей установки
    if ! check_installed_version; then
        if [[ $? -eq 2 ]]; then
            log "ERROR" "Element Web не установлен. Используйте функцию установки"
            return 1
        fi
    fi
    
    # Получение последней версии
    get_latest_element_version || return 1
    
    # Проверка необходимости обновления
    if check_installed_version; then
        log "INFO" "Element Web уже обновлён до последней версии"
        return 0
    fi
    
    # Процесс обновления аналогичен установке
    log "INFO" "Выполняется обновление Element Web..."
    
    download_element_web || return 1
    extract_element_web || return 1
    
    # Перезагрузка веб-сервера
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
        log "INFO" "Nginx перезагружен"
    fi
    
    # Проверка работоспособности
    test_element_web || return 1
    
    log "SUCCESS" "Element Web успешно обновлён до версии $LATEST_VERSION"
    return 0
}

# Функция диагностики Element Web
diagnose_element_web() {
    print_header "ДИАГНОСТИКА ELEMENT WEB" "$CYAN"
    
    log "INFO" "Запуск диагностики Element Web..."
    
    # Проверка установки
    echo "1. Проверка установки:"
    if [[ -d "$ELEMENT_DIR" ]] && [[ -f "$ELEMENT_DIR/index.html" ]]; then
        safe_echo "${GREEN}   ✓ Element Web установлен${NC}"
        
        if [[ -f "$ELEMENT_DIR/version" ]]; then
            local version=$(cat "$ELEMENT_DIR/version")
            safe_echo "${BLUE}   ✓ Версия: $version${NC}"
        fi
    else
        safe_echo "${RED}   ✗ Element Web не установлен${NC}"
        return 1
    fi
    
    # Проверка типа сервера
    echo "2. Информация о сервере:"
    safe_echo "${BLUE}   ✓ Тип сервера: ${SERVER_TYPE:-не определен}${NC}"
    safe_echo "${BLUE}   ✓ Bind адрес: ${BIND_ADDRESS:-не определен}${NC}"
    [[ -n "${PUBLIC_IP:-}" ]] && safe_echo "${BLUE}   ✓ Публичный IP: $PUBLIC_IP${NC}"
    [[ -n "${LOCAL_IP:-}" ]] && safe_echo "${BLUE}   ✓ Локальный IP: $LOCAL_IP${NC}"
    
    # Проверка конфигурации
    echo "3. Проверка конфигурации:"
    if [[ -f "$ELEMENT_CONFIG_FILE" ]]; then
        safe_echo "${GREEN}   ✓ Конфигурационный файл существует${NC}"
        
        if jq empty "$ELEMENT_CONFIG_FILE" 2>/dev/null; then
            safe_echo "${GREEN}   ✓ JSON синтаксис корректен${NC}"
            
            # Проверяем специфичные настройки для типа сервера
            local homeserver_url=$(jq -r '.default_server_config["m.homeserver"].base_url' "$ELEMENT_CONFIG_FILE" 2>/dev/null)
            safe_echo "${BLUE}   ✓ Homeserver URL: $homeserver_url${NC}"
            
            local mobile_guide=$(jq -r '.mobile_guide_toast' "$ELEMENT_CONFIG_FILE" 2>/dev/null)
            safe_echo "${BLUE}   ✓ Mobile guide: $mobile_guide${NC}"
        else
            safe_echo "${RED}   ✗ Ошибка в JSON синтаксисе${NC}"
        fi
    else
        safe_echo "${RED}   ✗ Конфигурационный файл отсутствует${NC}"
    fi
    
    # Проверка веб-сервера
    echo "4. Проверка веб-сервера:"
    if systemctl is-active --quiet nginx; then
        safe_echo "${GREEN}   ✓ Nginx запущен${NC}"
        
        if nginx -t 2>/dev/null; then
            safe_echo "${GREEN}   ✓ Конфигурация Nginx корректна${NC}"
        else
            safe_echo "${RED}   ✗ Ошибка в конфигурации Nginx${NC}"
        fi
    else
        safe_echo "${RED}   ✗ Nginx не запущен${NC}"
    fi
    
    # Проверка портов с учетом типа сервера
    echo "5. Проверка портов:"
    local ports_to_check=()
    case "$SERVER_TYPE" in
        "home_server"|"proxmox"|"docker"|"openvz")
            ports_to_check=(80 443)
            ;;
        *)
            ports_to_check=(80 443)
            ;;
    esac
    
    for port in "${ports_to_check[@]}"; do
        if check_port "$port"; then
            safe_echo "${YELLOW}   ! Порт $port свободен${NC}"
        else
            safe_echo "${GREEN}   ✓ Порт $port используется${NC}"
        fi
    done
    
    # Проверка доступности с учетом типа сервера
    echo "6. Проверка доступности:"
    local test_urls=()
    case "$SERVER_TYPE" in
        "home_server"|"proxmox"|"docker"|"openvz")
            test_urls=("http://localhost" "http://${LOCAL_IP:-127.0.0.1}")
            ;;
        *)
            test_urls=("http://localhost")
            ;;
    esac
    
    for url in "${test_urls[@]}"; do
        if curl -sf --connect-timeout 5 "$url" >/dev/null 2>&1; then
            safe_echo "${GREEN}   ✓ Element Web отвечает на $url${NC}"
        else
            safe_echo "${RED}   ✗ Element Web недоступен на $url${NC}"
        fi
    done
    
    # Проверка логов
    echo "7. Последние записи в логах Nginx:"
    if [[ -f "/var/log/nginx/element-error.log" ]]; then
        tail -n 5 "/var/log/nginx/element-error.log" 2>/dev/null || safe_echo "${YELLOW}   Лог ошибок пуст${NC}"
    else
        safe_echo "${YELLOW}   Лог файл не найден${NC}"
    fi
    
    return 0
}

# Функция показа статуса Element Web
show_element_status() {
    print_header "СТАТУС ELEMENT WEB" "$CYAN"
    
    # Основная информация
    echo "Домен Element Web: $ELEMENT_DOMAIN"
    echo "Директория установки: $ELEMENT_DIR"
    echo "Тип сервера: ${SERVER_TYPE:-не определен}"
    echo "Bind адрес: ${BIND_ADDRESS:-не определен}"
    [[ -n "${PUBLIC_IP:-}" ]] && echo "Публичный IP: $PUBLIC_IP"
    [[ -n "${LOCAL_IP:-}" ]] && echo "Локальный IP: $LOCAL_IP"
    
    # Версия
    if [[ -f "$ELEMENT_DIR/version" ]]; then
        echo "Установленная версия: $(cat "$ELEMENT_DIR/version")"
    else
        echo "Версия: неизвестна"
    fi
    
    # Статус служб
    echo
    echo "Статус служб:"
    if systemctl is-active --quiet nginx; then
        safe_echo "${GREEN}• Nginx: запущен${NC}"
    else
        safe_echo "${RED}• Nginx: остановлен${NC}"
    fi
    
    if systemctl is-active --quiet element-web; then
        safe_echo "${GREEN}• Element Web Service: активен${NC}"
    else
        safe_echo "${YELLOW}• Element Web Service: неактивен${NC}"
    fi
    
    # Использование диска
    echo
    echo "Использование диска:"
    local element_size=$(du -sh "$ELEMENT_DIR" 2>/dev/null | cut -f1)
    echo "Element Web: ${element_size:-неизвестно}"
    
    if [[ -d "$ELEMENT_BACKUP_DIR" ]]; then
        local backup_size=$(du -sh "$ELEMENT_BACKUP_DIR" 2>/dev/null | cut -f1)
        echo "Резервные копии: ${backup_size:-0}"
    fi
    
    return 0
}

# Функция удаления Element Web
remove_element_web() {
    print_header "УДАЛЕНИЕ ELEMENT WEB" "$RED"
    
    if ! ask_confirmation "Вы уверены, что хотите удалить Element Web?"; then
        log "INFO" "Удаление отменено пользователем"
        return 0
    fi
    
    log "INFO" "Начинаем удаление Element Web..."
    
    # Создание финальной резервной копии
    if [[ -d "$ELEMENT_DIR" ]]; then
        local final_backup="$ELEMENT_BACKUP_DIR/final-backup-$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Создание финальной резервной копии..."
        cp -r "$ELEMENT_DIR" "$final_backup" 2>/dev/null || true
    fi
    
    # Остановка служб
    systemctl stop element-web.service 2>/dev/null || true
    systemctl disable element-web.service 2>/dev/null || true
    
    # Удаление конфигурации Nginx
    rm -f /etc/nginx/sites-enabled/element-web
    rm -f /etc/nginx/sites-available/element-web
    
    # Перезагрузка Nginx
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    fi
    
    # Удаление файлов
    rm -rf "$ELEMENT_DIR"
    rm -f /etc/systemd/system/element-web.service
    
    # Очистка systemd
    systemctl daemon-reload
    
    log "SUCCESS" "Element Web успешно удалён"
    log "INFO" "Резервные копии сохранены в: $ELEMENT_BACKUP_DIR"
    
    return 0
}

# Функция главного меню модуля
element_web_menu() {
    while true; do
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                show_menu "УПРАВЛЕНИЕ ELEMENT WEB (PROXMOX)" \
                    "Установить Element Web на VM" \
                    "Показать конфигурацию для хоста" \
                    "Генерировать конфигурации для хоста" \
                    "Показать статус" \
                    "Диагностика" \
                    "Обновить Element Web" \
                    "Переконфигурировать" \
                    "Удалить Element Web" \
                    "Назад в главное меню"
                ;;
            *)
                show_menu "УПРАВЛЕНИЕ ELEMENT WEB (ХОСТИНГ)" \
                    "Установить Element Web" \
                    "Обновить Element Web" \
                    "Показать статус" \
                    "Диагностика" \
                    "Переконфигурировать" \
                    "Удалить Element Web" \
                    "Назад в главное меню"
                ;;
        esac
        
        local choice=$?
        
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                case $choice in
                    1) install_element_web ;;
                    2) show_proxmox_element_config ;;
                    3) generate_proxmox_element_config ;;
                    4) show_element_status ;;
                    5) diagnose_element_web ;;
                    6) update_element_web ;;
                    7) create_element_config ;;
                    8) remove_element_web ;;
                    9) break ;;
                    *) log "ERROR" "Неверный выбор" ;;
                esac
                ;;
            *)
                case $choice in
                    1) install_element_web ;;
                    2) update_element_web ;;
                    3) show_element_status ;;
                    4) diagnose_element_web ;;
                    5) create_element_config ;;
                    6) remove_element_web ;;
                    7) break ;;
                    *) log "ERROR" "Неверный выбор" ;;
                esac
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Основная функция установки Element Web
install_element_web() {
    print_header "УСТАНОВКА ELEMENT WEB" "$BLUE"
    
    # Проверка прав root
    check_root || return 1
    
    # Загрузка или определение типа сервера
    load_server_type || return 1
    
    # Получение конфигурации доменов
    get_domain_config || return 1
    
    # Ветвление по типу сервера
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            # Для Proxmox: генерация конфигураций и инструкций + установка на VM
            log "INFO" "Установка Element Web для Proxmox: VM часть + генерация конфигураций для хоста"
            
            # Генерируем конфигурации для хоста
            generate_proxmox_element_config || return 1
            
            # Продолжаем установку на VM
            ;;
    esac
    
    # Проверка зависимостей
    check_element_dependencies || return 1
    
    # Создание директорий
    create_element_directories || return 1
    
    # Получение последней версии
    get_latest_element_version || return 1
    
    # Проверка установленной версии
    if check_installed_version; then
        log "INFO" "Element Web уже установлен и обновлён"
        if ! ask_confirmation "Переустановить Element Web?"; then
            return 0
        fi
    fi
    
    # Загрузка Element Web
    download_element_web || return 1
    log "INFO" "Элемент загружен"
    # Извлечение и установка
    extract_element_web || return 1
    log "INFO" "Элемент извлечён и установлен"
    # Создание конфигурации
    create_element_config || return 1
    log "INFO" "Элемент конфигурирован"

    # Настройка веб-сервера (разная для разных типов)
    configure_web_server || return 1

    # Генерация SSL сертификата (только для хостинга)
    if [[ "$SERVER_TYPE" == "hosting" ]] && [[ ! -f "/etc/ssl/certs/element.crt" ]]; then
        generate_ssl_certificate || return 1
    fi
    
    # Создание сервиса
    create_element_service || return 1
    
    # Обновление версии в nginx конфигурации
    if [[ -f "/etc/nginx/sites-available/element-web" ]]; then
        sed -i "s/{{ELEMENT_VERSION}}/$LATEST_VERSION/g" "/etc/nginx/sites-available/element-web"
        systemctl reload nginx 2>/dev/null || true
    fi
    
    # Проверка работоспособности
    test_element_web || return 1
    
    # Очистка временных файлов
    rm -rf "$ELEMENT_TEMP_DIR"
    
    # Сохранение информации об установке
    set_config_value "$CONFIG_DIR/element.conf" "ELEMENT_VERSION" "$LATEST_VERSION"
    set_config_value "$CONFIG_DIR/element.conf" "ELEMENT_DOMAIN" "$ELEMENT_DOMAIN"
    set_config_value "$CONFIG_DIR/element.conf" "SERVER_TYPE" "$SERVER_TYPE"
    set_config_value "$CONFIG_DIR/element.conf" "BIND_ADDRESS" "$BIND_ADDRESS"
    set_config_value "$CONFIG_DIR/element.conf" "INSTALL_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
    
    print_header "УСТАНОВКА ЗАВЕРШЕНА" "$GREEN"
    
    log "SUCCESS" "Element Web успешно установлен!"
    echo
    safe_echo "${BOLD}${GREEN}Информация о установке:${NC}"
    safe_echo "${BLUE}• Версия: ${LATEST_VERSION}${NC}"
    safe_echo "${BLUE}• Домен: ${ELEMENT_DOMAIN}${NC}"
    safe_echo "${BLUE}• Директория: ${ELEMENT_DIR}${NC}"
    safe_echo "${BLUE}• Тип сервера: ${SERVER_TYPE}${NC}"
    safe_echo "${BLUE}• Bind адрес: ${BIND_ADDRESS}${NC}"
    [[ -n "${PUBLIC_IP:-}" ]] && safe_echo "${BLUE}• Публичный IP: ${PUBLIC_IP}${NC}"
    [[ -n "${LOCAL_IP:-}" ]] && safe_echo "${BLUE}• Локальный IP: ${LOCAL_IP}${NC}"
    echo
    safe_echo "${BOLD}${YELLOW}Следующие шаги:${NC}"
    
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            safe_echo "${YELLOW}1. Element Web установлен на VM как простой HTTP сервер${NC}"
            safe_echo "${YELLOW}2. Настройте Nginx на хосте Proxmox для SSL терминации${NC}"
            safe_echo "${YELLOW}3. Используйте готовые конфигурации:${NC}"
            safe_echo "${BLUE}   cat $CONFIG_DIR/proxmox/element-web-setup-instructions.txt${NC}"
            safe_echo "${YELLOW}4. Проверьте доступность с хоста: curl http://${LOCAL_IP:-192.168.88.165}${NC}"
            show_proxmox_element_config
            ;;
        *)
            safe_echo "${YELLOW}1. Настройте DNS для домена ${ELEMENT_DOMAIN}${NC}"
            safe_echo "${YELLOW}2. Установите SSL сертификат от Let's Encrypt${NC}"
            safe_echo "${YELLOW}3. Настройте файрвол (порты 80, 443)${NC}"
            safe_echo "${YELLOW}4. Протестируйте доступ к https://${ELEMENT_DOMAIN}${NC}"
            ;;
    esac
    
    return 0
}

# Функция генерации самоподписанного SSL сертификата (только для хостинга)
generate_ssl_certificate() {
    log "INFO" "Генерация самоподписанного SSL сертификата для Element Web..."
    
    local ssl_dir="/etc/ssl"
    local cert_file="/etc/ssl/certs/element.crt"
    local key_file="/etc/ssl/private/element.key"
    
    # Создание директорий
    mkdir -p "$ssl_dir/certs" "$ssl_dir/private"
    
    # Генерация самоподписанного сертификата с учетом типа сервера
    local subject_alt_names="DNS.1 = $ELEMENT_DOMAIN"
    
    # Добавляем дополнительные домены для локальных серверов
    if [[ "$SERVER_TYPE" =~ ^(home_server|proxmox|docker|openvz)$ ]]; then
        subject_alt_names="${subject_alt_names}\nDNS.2 = *.${ELEMENT_DOMAIN}"
        if [[ -n "${LOCAL_IP:-}" ]]; then
            subject_alt_names="${subject_alt_names}\nIP.1 = ${LOCAL_IP}"
        fi
        subject_alt_names="${subject_alt_names}\nDNS.3 = localhost"
        subject_alt_names="${subject_alt_names}\nIP.2 = 127.0.0.1"
    fi
    
    if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/C=RU/ST=Moscow/L=Moscow/O=Matrix Server ($SERVER_TYPE)/CN=$ELEMENT_DOMAIN" \
        -extensions v3_req \
        -config <(cat <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C=RU
ST=Moscow
L=Moscow
O=Matrix Server ($SERVER_TYPE)
CN=$ELEMENT_DOMAIN

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
$(echo -e "$subject_alt_names")
EOF
); then
        log "ERROR" "Ошибка генерации SSL сертификата"
        return 1
    fi
    
    # Установка прав доступа
    chmod 644 "$cert_file"
    chmod 600 "$key_file"
    chown root:root "$cert_file" "$key_file"
    
    log "SUCCESS" "SSL сертификат для Element Web создан (тип сервера: $SERVER_TYPE)"
    log "WARN" "Используется самоподписанный сертификат. Рекомендуется использовать Let's Encrypt"
    return 0
}

# Функция создания systemd сервиса для Element Web
create_element_service() {
    log "INFO" "Создание systemd сервиса для Element Web..."
    
    # Element Web - статические файлы, сервис не нужен
    # Но создадим сервис для проверки статуса
    cat > "/etc/systemd/system/element-web.service" <<EOF
[Unit]
Description=Element Web Status Check Service
After=nginx.service
Wants=nginx.service

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable element-web.service
    systemctl start element-web.service
    
    log "SUCCESS" "Сервис Element Web создан"
    return 0
}

# Экспорт функций для использования в других скриптах
export -f install_element_web
export -f update_element_web
export -f show_element_status
export -f diagnose_element_web
export -f element_web_menu
export -f generate_ssl_certificate
export -f create_element_service
export -f generate_proxmox_element_config
export -f show_proxmox_element_config
export -f get_domain_config

# Функция для интеграции с caddy_config.sh
get_element_web_backend() {
    local element_domain_file="$CONFIG_DIR/element_domain"
    local element_config_dir="$CONFIG_DIR/proxmox"
    
    # Проверяем, установлен ли Element Web для Proxmox
    if [[ -f "$element_domain_file" ]] && [[ -d "$element_config_dir" ]]; then
        local element_domain=$(cat "$element_domain_file" 2>/dev/null)
        local element_backend="${LOCAL_IP:-192.168.88.165}:80"
        
        if [[ -n "$element_domain" ]]; then
            export ELEMENT_DOMAIN="$element_domain"
            export ELEMENT_BACKEND="$element_backend"
            echo "ELEMENT_WEB_AVAILABLE=true"
            echo "ELEMENT_DOMAIN=$element_domain"
            echo "ELEMENT_BACKEND=$element_backend"
            return 0
        fi
    fi
    
    echo "ELEMENT_WEB_AVAILABLE=false"
    return 1
}

# Функция получения Caddy конфигурации Element Web
get_element_web_caddy_config() {
    local caddy_config_file="$CONFIG_DIR/proxmox/caddy-element-web.conf"
    
    if [[ -f "$caddy_config_file" ]]; then
        cat "$caddy_config_file"
        return 0
    else
        return 1
    fi
}

# Экспорт функций интеграции
export -f get_element_web_backend
export -f get_element_web_caddy_config

# Если скрипт запущен напрямую, показываем меню
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    element_web_menu
fi