#!/bin/bash

# Caddy Configuration Module for Matrix Setup
# Версия: 4.1.0 - Доработанный подход на основе рабочей конфигурации

# Настройки модуля
LIB_NAME="Caddy Configuration Manager"
LIB_VERSION="4.1.0"
MODULE_NAME="caddy_config"

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
CADDY_CONFIG_DIR="/etc/caddy"
CADDY_CONFIG_FILE="$CADDY_CONFIG_DIR/Caddyfile"

# Функция получения конфигурации доменов
get_domain_config() {
    local domain_file="$CONFIG_DIR/domain"
    local element_domain_file="$CONFIG_DIR/element_domain"
    local admin_domain_file="$CONFIG_DIR/admin_domain"
    
    # Основной домен Matrix
    if [[ -f "$domain_file" ]]; then
        MATRIX_DOMAIN=$(cat "$domain_file")
        log "INFO" "Основной домен Matrix: $MATRIX_DOMAIN"
    else
        log "ERROR" "Не найден файл с доменом Matrix сервера в $domain_file"
        return 1
    fi
    
    # Домен Element Web
    if [[ -f "$element_domain_file" ]]; then
        ELEMENT_DOMAIN=$(cat "$element_domain_file")
    else
        # Автоматическое определение домена Element
        case "$SERVER_TYPE" in
            "proxmox"|"home_server"|"docker"|"openvz")
                ELEMENT_DOMAIN="element.${MATRIX_DOMAIN#*.}"
                ;;
            *)
                ELEMENT_DOMAIN="element.${MATRIX_DOMAIN}"
                ;;
        esac
        echo "$ELEMENT_DOMAIN" > "$element_domain_file"
    fi
    
    # Для новой схемы - не используем отдельный домен для админки
    # Админка будет доступна на /admin основного домена
    ADMIN_DOMAIN="$MATRIX_DOMAIN"
    
    log "INFO" "Домены: Matrix=$MATRIX_DOMAIN, Element=$ELEMENT_DOMAIN, Admin=на /admin основного домена"
    export MATRIX_DOMAIN ELEMENT_DOMAIN ADMIN_DOMAIN
    return 0
}

# Функция определения SSL сертификатов (только для хостинга)
detect_ssl_certificates() {
    if [[ "$SERVER_TYPE" != "hosting" ]]; then
        return 0  # Для Proxmox SSL не нужен здесь
    fi
    
    local cert_path=""
    local key_path=""
    local root_domain="${MATRIX_DOMAIN#*.}"
    
    # Поиск wildcard сертификатов Cloudflare (приоритет)
    local cloudflare_paths=(
        "/etc/letsencrypt/live/${root_domain}"
        "/etc/ssl/certs"
    )
    
    for path in "${cloudflare_paths[@]}"; do
        if [[ -f "$path/fullchain.pem" ]] && [[ -f "$path/privkey.pem" ]]; then
            cert_path="$path/fullchain.pem"
            key_path="$path/privkey.pem"
            log "INFO" "Найдены wildcard сертификаты: $path"
            break
        fi
    done
    
    # Поиск обычных Let's Encrypt сертификатов
    if [[ -z "$cert_path" ]]; then
        local letsencrypt_paths=(
            "/etc/letsencrypt/live/${MATRIX_DOMAIN}"
            "/etc/letsencrypt/live/${root_domain}"
        )
        
        for path in "${letsencrypt_paths[@]}"; do
            if [[ -f "$path/fullchain.pem" ]] && [[ -f "$path/privkey.pem" ]]; then
                cert_path="$path/fullchain.pem"
                key_path="$path/privkey.pem"
                log "INFO" "Найдены сертификаты Let's Encrypt: $path"
                break
            fi
        done
    fi
    
    # Если сертификаты не найдены
    if [[ -z "$cert_path" ]]; then
        log "WARN" "SSL сертификаты не найдены"
        log "INFO" "Рекомендуется установить wildcard сертификаты Cloudflare"
        show_ssl_help
        return 1
    fi
    
    export SSL_CERT_PATH="$cert_path"
    export SSL_KEY_PATH="$key_path"
    return 0
}

# Функция показа помощи по SSL сертификатам
show_ssl_help() {
    print_header "НАСТРОЙКА SSL СЕРТИФИКАТОВ" "$YELLOW"
    
    safe_echo "${BLUE}📋 Для работы Matrix на хостинге необходимы SSL сертификаты${NC}"
    echo
    safe_echo "${BOLD}Рекомендуемый вариант: Cloudflare wildcard (БЕСПЛАТНО)${NC}"
    safe_echo "${GREEN}1. Получите API токен в Cloudflare:${NC}"
    safe_echo "   • Откройте dash.cloudflare.com"
    safe_echo "   • Профиль → API Tokens → Create Token"
    safe_echo "   • Выберите 'Edit zone DNS' template"
    safe_echo "   • Zone:Zone Read, Zone:DNS Edit для всех зон"
    echo
    safe_echo "${GREEN}2. Установите certbot для Cloudflare:${NC}"
    safe_echo "   sudo apt update"
    safe_echo "   sudo apt install certbot python3-certbot-dns-cloudflare"
    safe_echo "   sudo mkdir -p /etc/cloudflare"
    echo
    safe_echo "${GREEN}3. Создайте файл с токеном:${NC}"
    safe_echo "   sudo nano /etc/cloudflare/cloudflare.ini"
    safe_echo "   dns_cloudflare_api_token = ВАШ_API_ТОКЕН"
    safe_echo "   sudo chmod 600 /etc/cloudflare/cloudflare.ini"
    echo
    safe_echo "${GREEN}4. Получите wildcard сертификат:${NC}"
    safe_echo "   sudo certbot certonly \\\\"
    safe_echo "     --dns-cloudflare \\\\"
    safe_echo "     --dns-cloudflare-credentials /etc/cloudflare/cloudflare.ini \\\\"
    safe_echo "     -d \"${MATRIX_DOMAIN#*.}\" \\\\"
    safe_echo "     -d \"*.${MATRIX_DOMAIN#*.}\" \\\\"
    safe_echo "     --register-unsafely-without-email"
    echo
    safe_echo "${RED}⚠️ ВАЖНО: Caddy работает только с .pem сертификатами!${NC}"
}

# Функция определения backend адресов
detect_backend_addresses() {
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            # Для Proxmox используем IP локальной машины Matrix
            MATRIX_BACKEND="${LOCAL_IP:-192.168.88.165}:8008"
            FEDERATION_BACKEND="${LOCAL_IP:-192.168.88.165}:8448"
            ELEMENT_BACKEND="${LOCAL_IP:-192.168.88.165}:80"
            ADMIN_BACKEND="${LOCAL_IP:-192.168.88.165}:8080"
            log "INFO" "Backend адреса для Proxmox/локального сервера: Matrix=$MATRIX_BACKEND"
            ;;
        *)
            # Для хостинга используем localhost
            MATRIX_BACKEND="127.0.0.1:8008"
            FEDERATION_BACKEND="127.0.0.1:8448"
            ELEMENT_BACKEND="127.0.0.1:80"
            ADMIN_BACKEND="127.0.0.1:8080"
            log "INFO" "Backend адреса для хостинга: Matrix=$MATRIX_BACKEND"
            ;;
    esac
    
    export MATRIX_BACKEND FEDERATION_BACKEND ELEMENT_BACKEND ADMIN_BACKEND
}

# Функция установки Caddy (только для хостинга)
install_caddy() {
    if [[ "$SERVER_TYPE" != "hosting" ]]; then
        log "INFO" "Пропуск установки Caddy для типа сервера: $SERVER_TYPE"
        return 0
    fi
    
    print_header "УСТАНОВКА CADDY" "$BLUE"
    
    log "INFO" "Проверка установки Caddy..."
    
    if command -v caddy >/dev/null 2>&1; then
        local caddy_version=$(caddy version 2>/dev/null | head -1)
        log "INFO" "Caddy уже установлен: $caddy_version"
        return 0
    fi
    
    log "INFO" "Установка Caddy из официального репозитория..."
    
    # Установка зависимостей
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    
    # Добавление ключа и репозитория Caddy
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list
    
    # Обновление списка пакетов и установка
    apt update
    if ! apt install -y caddy; then
        log "ERROR" "Ошибка установки Caddy"
        return 1
    fi
    
    # Проверка установки
    if ! command -v caddy >/dev/null 2>&1; then
        log "ERROR" "Caddy не установился корректно"
        return 1
    fi
    
    local caddy_version=$(caddy version 2>/dev/null | head -1)
    log "SUCCESS" "Caddy установлен: $caddy_version"
    return 0
}

# Функция создания конфигурации для хостинга
create_hosting_config() {
    print_header "СОЗДАНИЕ КОНФИГУРАЦИИ CADDY ДЛЯ ХОСТИНГА" "$CYAN"
    
    log "INFO" "Создание конфигурации Caddy для хостинга (по образцу рабочей схемы)..."
    
    # Резервная копия существующей конфигурации
    if [[ -f "$CADDY_CONFIG_FILE" ]]; then
        backup_file "$CADDY_CONFIG_FILE" "caddy-config"
    fi
    
    # Создание директории для конфигурации
    mkdir -p "$CADDY_CONFIG_DIR"
    
    local root_domain="${MATRIX_DOMAIN#*.}"
    
    # Создание Caddyfile для хостинга по образцу рабочей конфигурации
    cat > "$CADDY_CONFIG_FILE" <<EOF
# Caddy Configuration for Matrix Server (Hosting)
# Generated by Matrix Setup Tool v4.1 - Based on working configuration
# Server Type: $SERVER_TYPE
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Global options
{
    email admin@${root_domain}
    default_sni $MATRIX_DOMAIN
}

# Основной домен с well-known endpoints (на root домене)
$root_domain {
    tls $SSL_CERT_PATH $SSL_KEY_PATH

    # .well-known endpoints for Matrix federation discovery
    handle /.well-known/matrix/server {
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond \`{"m.server": "$MATRIX_DOMAIN:8448"}\` 200
    }

    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond \`{
            "m.homeserver": {"base_url": "https://$MATRIX_DOMAIN"},
            "m.identity_server": {"base_url": "https://vector.im"}
        }\` 200
    }

    # Default response
    respond "Matrix federation endpoints available" 200
}

# Matrix Federation (порт 8448)
$MATRIX_DOMAIN:8448 {
    tls $SSL_CERT_PATH $SSL_KEY_PATH
    
    reverse_proxy $FEDERATION_BACKEND {
        transport http {
            tls_insecure_skip_verify
            keepalive 1h
        }
    }
}

# Matrix Homeserver - объединенная конфигурация (Matrix API + Synapse Admin)
$MATRIX_DOMAIN {
    tls $SSL_CERT_PATH $SSL_KEY_PATH

    # Synapse Admin на /admin (с удалением префикса)
    route /admin/* {
        uri strip_prefix /admin
        reverse_proxy $ADMIN_BACKEND
    }

    # Matrix API
    route /_matrix/* {
        reverse_proxy $MATRIX_BACKEND
    }

    # Synapse Admin API
    route /_synapse/* {
        reverse_proxy $MATRIX_BACKEND
    }

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
    }

    # Default response
    respond "Matrix Server is running. Access admin at /admin or use a Matrix client." 200
}

# Element Web Client (отдельный домен)
$ELEMENT_DOMAIN {
    tls $SSL_CERT_PATH $SSL_KEY_PATH
    
    reverse_proxy $ELEMENT_BACKEND {
        header_up Host {upstream_hostport}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
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
    }
}
EOF

    # Проверка синтаксиса конфигурации
    if ! caddy validate --config "$CADDY_CONFIG_FILE"; then
        log "ERROR" "Ошибка в конфигурации Caddy"
        return 1
    fi
    
    # Установка прав доступа
    chown root:root "$CADDY_CONFIG_FILE"
    chmod 644 "$CADDY_CONFIG_FILE"
    
    log "SUCCESS" "Конфигурация Caddy для хостинга создана: $CADDY_CONFIG_FILE"
    return 0
}

# Функция генерации конфигурации для Proxmox
generate_proxmox_config() {
    print_header "ГЕНЕРАЦИЯ КОНФИГУРАЦИИ ДЛЯ PROXMOX" "$CYAN"
    
    log "INFO" "Генерация конфигурации Caddy для Proxmox (по образцу рабочей схемы)..."
    
    # Создание директории для конфигураций
    mkdir -p "$CONFIG_DIR/proxmox"
    
    local root_domain="${MATRIX_DOMAIN#*.}"
    
    # Генерация Caddyfile для хоста Proxmox
    local proxmox_config="$CONFIG_DIR/proxmox/Caddyfile"
    cat > "$proxmox_config" <<EOF
# Caddy Configuration for Matrix Server (Proxmox Host)
# Generated by Matrix Setup Tool v4.1 - Based on working configuration
# Matrix VM IP: $MATRIX_BACKEND
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Основной домен с well-known endpoints (на root домене)
$root_domain {
    tls /etc/letsencrypt/live/$root_domain/fullchain.pem /etc/letsencrypt/live/$root_domain/privkey.pem

    # .well-known endpoints for Matrix federation discovery
    handle /.well-known/matrix/server {
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond \`{"m.server": "$MATRIX_DOMAIN:8448"}\` 200
    }

    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond \`{
            "m.homeserver": {"base_url": "https://$MATRIX_DOMAIN"},
            "m.identity_server": {"base_url": "https://vector.im"}
        }\` 200
    }

    # Default response
    respond "Matrix federation endpoints available" 200
}

# Matrix Federation (порт 8448)
$MATRIX_DOMAIN:8448 {
    tls /etc/letsencrypt/live/$root_domain/fullchain.pem /etc/letsencrypt/live/$root_domain/privkey.pem
    
    reverse_proxy $FEDERATION_BACKEND {
        transport http {
            tls_insecure_skip_verify
            keepalive 1h
        }
    }
}

# Matrix Homeserver - объединенная конфигурация (Matrix API + Synapse Admin)
$MATRIX_DOMAIN {
    tls /etc/letsencrypt/live/$root_domain/fullchain.pem /etc/letsencrypt/live/$root_domain/privkey.pem

    # Synapse Admin на /admin (с удалением префикса)
    route /admin/* {
        uri strip_prefix /admin
        reverse_proxy $ADMIN_BACKEND
    }

    # Matrix API
    route /_matrix/* {
        reverse_proxy $MATRIX_BACKEND
    }

    # Synapse Admin API
    route /_synapse/* {
        reverse_proxy $MATRIX_BACKEND
    }

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
    }

    # Default response
    respond "Matrix Server on Proxmox VM. Access admin at /admin or use a Matrix client." 200
}

# Element Web Client (отдельный домен, если установлен)
$ELEMENT_DOMAIN {
    tls /etc/letsencrypt/live/$root_domain/fullchain.pem /etc/letsencrypt/live/$root_domain/privkey.pem
    
    reverse_proxy $ELEMENT_BACKEND {
        header_up Host {upstream_hostport}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
    }
    
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
    }
}
EOF

    # Генерация инструкций по установке
    local instructions_file="$CONFIG_DIR/proxmox/setup-instructions.txt"
    cat > "$instructions_file" <<EOF
# ИНСТРУКЦИИ ПО НАСТРОЙКЕ CADDY НА PROXMOX ХОСТЕ

Дата генерации: $(date '+%Y-%m-%d %H:%M:%S')
Matrix VM IP: $MATRIX_BACKEND
Root домен: $root_domain
Matrix домен: $MATRIX_DOMAIN

## 1. УСТАНОВИТЕ CADDY НА ХОСТЕ PROXMOX

sudo apt update
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \\\\
    sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \\\\
    sudo tee /etc/apt/sources.list.d/caddy-stable.list

sudo apt update
sudo apt install -y caddy

## 2. СКОПИРУЙТЕ КОНФИГУРАЦИЮ

sudo cp $proxmox_config /etc/caddy/Caddyfile

## 3. НАСТРОЙТЕ DNS ЗАПИСИ

Для корневого домена $root_domain создайте SRV запись для федерации:

Тип записи:    SRV
Услуга:       _matrix._tcp
Домен:        $root_domain. (с точкой в конце!)
Приоритет:    10
Вес:          5
Порт:         8448
TTL:          3600

Пример для dig проверки:
dig SRV _matrix._tcp.$root_domain +short

Ожидаемый результат:
10 5 8448 $MATRIX_DOMAIN.

## 4. ПОЛУЧИТЕ SSL СЕРТИФИКАТЫ (РЕКОМЕНДУЕТСЯ WILDCARD CLOUDFLARE)

Вариант A: Cloudflare (бесплатный wildcard) - РЕКОМЕНДУЕТСЯ
sudo apt install python3-certbot-dns-cloudflare
sudo mkdir -p /etc/cloudflare
sudo nano /etc/cloudflare/cloudflare.ini

Содержимое cloudflare.ini:
dns_cloudflare_api_token = ВАШ_API_ТОКЕН

sudo chmod 600 /etc/cloudflare/cloudflare.ini

sudo certbot certonly \\\\
  --dns-cloudflare \\\\
  --dns-cloudflare-credentials /etc/cloudflare/cloudflare.ini \\\\
  -d "$root_domain" \\\\
  -d "*.$root_domain" \\\\
  --register-unsafely-without-email

Вариант B: Let's Encrypt для публичного домена
sudo apt install certbot
sudo certbot certonly --standalone -d $root_domain -d $MATRIX_DOMAIN -d $ELEMENT_DOMAIN

## 5. ЗАПУСТИТЕ CADDY

sudo systemctl enable caddy
sudo systemctl start caddy
sudo systemctl status caddy

## 6. ПРОВЕРЬТЕ РАБОТУ

curl -I https://$MATRIX_DOMAIN
curl https://$root_domain/.well-known/matrix/server
curl https://$MATRIX_DOMAIN/admin

## 7. НАСТРОЙКА ФАЙРВОЛА НА ХОСТЕ

sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 8448/tcp

## ВАЖНЫЕ ЗАМЕЧАНИЯ:

1. IP адрес VM: $MATRIX_BACKEND
2. Убедитесь что Matrix VM доступна с хоста по этому IP
3. Проверьте что на VM запущен Matrix Synapse на порту 8008
4. Synapse Admin доступен на порту 8080 VM
5. Админка будет доступна по адресу: https://$MATRIX_DOMAIN/admin

## ДОСТУП К СЕРВИСАМ:

- Matrix API: https://$MATRIX_DOMAIN/_matrix/...
- Synapse Admin: https://$MATRIX_DOMAIN/admin
- Element Web: https://$ELEMENT_DOMAIN (если установлен)
- Federation: https://$MATRIX_DOMAIN:8448

## ДИАГНОСТИКА ПРОБЛЕМ:

- Логи Caddy: sudo journalctl -u caddy -f
- Проверка портов: sudo ss -tlnp | grep -E ':(80|443|8448)'
- Проверка доступности VM: curl http://$MATRIX_BACKEND/_matrix/client/versions
- Проверка админки: curl http://$ADMIN_BACKEND
- Проверка DNS: dig $MATRIX_DOMAIN
- Проверка федерации: curl https://$root_domain/.well-known/matrix/server
- Проверка SRV: dig SRV _matrix._tcp.$root_domain +short
EOF

    log "SUCCESS" "Конфигурация для Proxmox сгенерирована:"
    safe_echo "${BLUE}   📄 Caddyfile: $proxmox_config${NC}"
    safe_echo "${BLUE}   📋 Инструкции: $instructions_file${NC}"
    
    return 0
}

# Функция показа конфигурации для Proxmox
show_proxmox_config() {
    local proxmox_config="$CONFIG_DIR/proxmox/Caddyfile"
    
    if [[ ! -f "$proxmox_config" ]]; then
        log "ERROR" "Конфигурация для Proxmox не найдена. Сгенерируйте её сначала."
        return 1
    fi
    
    print_header "КОНФИГУРАЦИЯ CADDY ДЛЯ PROXMOX ХОСТА" "$CYAN"
    
    safe_echo "${BOLD}Скопируйте эту конфигурацию в /etc/caddy/Caddyfile на хосте Proxmox:${NC}"
    echo
    safe_echo "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    cat "$proxmox_config"
    safe_echo "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    local root_domain="${MATRIX_DOMAIN#*.}"
    
    safe_echo "${YELLOW}📝 ВАЖНЫЕ ИНСТРУКЦИИ:${NC}"
    safe_echo "1. ${BOLD}DNS SRV запись:${NC}"
    safe_echo "   Тип: SRV | Услуга: _matrix._tcp | Домен: $root_domain."
    safe_echo "   Приоритет: 10 | Вес: 5 | Порт: 8448 | TTL: 3600"
    echo
    safe_echo "2. ${BOLD}Проверка SRV записи:${NC}"
    safe_echo "   dig SRV _matrix._tcp.$root_domain +short"
    safe_echo "   Ожидаемый результат: 10 5 8448 $MATRIX_DOMAIN."
    echo
    safe_echo "3. ${BOLD}Доступ к сервисам:${NC}"
    safe_echo "   • Matrix API: https://$MATRIX_DOMAIN/_matrix/..."
    safe_echo "   • Synapse Admin: https://$MATRIX_DOMAIN/admin"
    safe_echo "   • Element Web: https://$ELEMENT_DOMAIN"
    safe_echo "   • Federation: https://$MATRIX_DOMAIN:8448"
    echo
    safe_echo "4. ${BOLD}IP адрес Matrix VM:${NC} $MATRIX_BACKEND"
    echo
    
    # Показываем инструкции
    local instructions_file="$CONFIG_DIR/proxmox/setup-instructions.txt"
    if [[ -f "$instructions_file" ]]; then
        safe_echo "${BLUE}📋 Полные инструкции сохранены в: $instructions_file${NC}"
        safe_echo "${BLUE}Используйте: cat $instructions_file${NC}"
    fi
    
    return 0
}

# Функция настройки системного сервиса Caddy (только для хостинга)
configure_caddy_service() {
    if [[ "$SERVER_TYPE" != "hosting" ]]; then
        return 0
    fi
    
    log "INFO" "Настройка службы Caddy..."
    
    # Включение автозапуска
    if ! systemctl enable caddy; then
        log "ERROR" "Ошибка включения автозапуска Caddy"
        return 1
    fi
    
    # Проверка статуса службы
    if systemctl is-active --quiet caddy; then
        log "INFO" "Перезапуск службы Caddy..."
        if ! systemctl restart caddy; then
            log "ERROR" "Ошибка перезапуска Caddy"
            return 1
        fi
    else
        log "INFO" "Запуск службы Caddy..."
        if ! systemctl start caddy; then
            log "ERROR" "Ошибка запуска Caddy"
            return 1
        fi
    fi
    
    # Ожидание запуска
    sleep 3
    
    # Проверка статуса
    if ! systemctl is-active --quiet caddy; then
        log "ERROR" "Caddy не запустился корректно"
        log "INFO" "Проверьте логи: journalctl -u caddy -n 20"
        return 1
    fi
    
    log "SUCCESS" "Служба Caddy настроена и запущена"
    return 0
}

# Функция тестирования конфигурации (только для хостинга)
test_caddy_configuration() {
    if [[ "$SERVER_TYPE" != "hosting" ]]; then
        return 0
    fi
    
    print_header "ТЕСТИРОВАНИЕ КОНФИГУРАЦИИ CADDY" "$GREEN"
    
    log "INFO" "Тестирование конфигурации Caddy..."
    
    # Проверка портов
    local ports=(80 443 8448)
    for port in "${ports[@]}"; do
        if check_port "$port"; then
            log "WARN" "Порт $port свободен (может потребоваться время для запуска)"
        else
            log "INFO" "Порт $port используется"
        fi
    done
    
    # Проверка доступности endpoints
    local root_domain="${MATRIX_DOMAIN#*.}"
    local endpoints=(
        "http://localhost/.well-known/matrix/server"
        "http://localhost/.well-known/matrix/client"
        "http://localhost/_matrix/client/versions"
        "http://localhost/admin"
    )
    
    log "INFO" "Ожидание готовности Caddy..."
    sleep 5
    
    for endpoint in "${endpoints[@]}"; do
        log "INFO" "Тестирование: $endpoint"
        if curl -sf --connect-timeout 5 "$endpoint" >/dev/null 2>&1; then
            log "SUCCESS" "✓ $endpoint доступен"
        else
            log "WARN" "✗ $endpoint недоступен"
        fi
    done
    
    return 0
}

# Функция диагностики Caddy
diagnose_caddy() {
    print_header "ДИАГНОСТИКА CADDY" "$CYAN"
    
    log "INFO" "Запуск диагностики Caddy..."
    
    # Проверка типа сервера
    echo "0. Тип сервера: $SERVER_TYPE"
    echo
    
    # Проверка установки
    echo "1. Установка Caddy:"
    if command -v caddy >/dev/null 2>&1; then
        local version=$(caddy version 2>/dev/null | head -1)
        safe_echo "${GREEN}   ✓ Caddy установлен: $version${NC}"
    else
        safe_echo "${RED}   ✗ Caddy не установлен${NC}"
        if [[ "$SERVER_TYPE" == "hosting" ]]; then
            safe_echo "${YELLOW}   ! Требуется установка для хостинга${NC}"
        else
            safe_echo "${BLUE}   i Для Proxmox Caddy устанавливается на хосте${NC}"
        fi
    fi
    
    # Проверка конфигурации
    echo "2. Конфигурация:"
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        if [[ -f "$CADDY_CONFIG_FILE" ]]; then
            safe_echo "${GREEN}   ✓ Конфигурационный файл существует${NC}"
            if caddy validate --config "$CADDY_CONFIG_FILE" >/dev/null 2>&1; then
                safe_echo "${GREEN}   ✓ Синтаксис конфигурации корректен${NC}"
            else
                safe_echo "${RED}   ✗ Ошибка в синтаксе конфигурации${NC}"
            fi
        else
            safe_echo "${RED}   ✗ Конфигурационный файл отсутствует${NC}"
        fi
    else
        local proxmox_config="$CONFIG_DIR/proxmox/Caddyfile"
        if [[ -f "$proxmox_config" ]]; then
            safe_echo "${GREEN}   ✓ Конфигурация для Proxmox сгенерирована${NC}"
        else
            safe_echo "${YELLOW}   ! Конфигурация для Proxmox не сгенерирована${NC}"
        fi
    fi
    
    # Проверка службы (только для хостинга)
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        echo "3. Служба Caddy:"
        if systemctl is-active --quiet caddy; then
            safe_echo "${GREEN}   ✓ Caddy запущен${NC}"
        else
            safe_echo "${RED}   ✗ Caddy не запущен${NC}"
        fi
        
        if systemctl is-enabled --quiet caddy; then
            safe_echo "${GREEN}   ✓ Автозапуск включен${NC}"
        else
            safe_echo "${YELLOW}   ! Автозапуск отключен${NC}"
        fi
        
        # Проверка портов
        echo "4. Сетевые порты:"
        local ports=(80 443 8448)
        for port in "${ports[@]}"; do
            if ss -tlnp | grep -q ":$port "; then
                safe_echo "${GREEN}   ✓ Порт $port прослушивается${NC}"
            else
                safe_echo "${RED}   ✗ Порт $port не прослушивается${NC}"
            fi
        done
        
        # Проверка сертификатов
        echo "5. SSL сертификаты:"
        if [[ -f "${SSL_CERT_PATH:-}" ]] && [[ -f "${SSL_KEY_PATH:-}" ]]; then
            safe_echo "${GREEN}   ✓ SSL сертификаты найдены${NC}"
            safe_echo "${BLUE}   ✓ Сертификат: ${SSL_CERT_PATH}${NC}"
            safe_echo "${BLUE}   ✓ Ключ: ${SSL_KEY_PATH}${NC}"
        else
            safe_echo "${RED}   ✗ SSL сертификаты не найдены${NC}"
        fi
        
        # Проверка логов
        echo "6. Последние записи в логах:"
        journalctl -u caddy -n 5 --no-pager -o cat 2>/dev/null || safe_echo "${YELLOW}   Логи недоступны${NC}"
    fi
    
    return 0
}

# Функция показа статуса Caddy
show_caddy_status() {
    print_header "СТАТУС CADDY" "$CYAN"
    
    echo "Тип сервера: ${SERVER_TYPE:-не определен}"
    echo
    
    # Домены
    echo "Настроенные домены:"
    echo "  Matrix сервер: ${MATRIX_DOMAIN:-не определен}"
    echo "  Element Web: ${ELEMENT_DOMAIN:-не определен}"
    echo "  Synapse Admin: на /admin основного домена"
    
    # Backend адреса
    echo
    echo "Backend адреса:"
    echo "  Matrix API: ${MATRIX_BACKEND:-не определен}"
    echo "  Federation: ${FEDERATION_BACKEND:-не определен}"
    echo "  Element Web: ${ELEMENT_BACKEND:-не определен}"
    echo "  Synapse Admin: ${ADMIN_BACKEND:-не определен}"
    
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        echo
        echo "Конфигурационный файл: $CADDY_CONFIG_FILE"
        
        # SSL сертификаты
        echo
        echo "SSL сертификаты:"
        echo "  Сертификат: ${SSL_CERT_PATH:-не определен}"
        echo "  Ключ: ${SSL_KEY_PATH:-не определен}"
        
        # Статус службы
        echo
        echo "Статус службы:"
        if systemctl is-active --quiet caddy; then
            safe_echo "${GREEN}• Caddy: запущен${NC}"
        else
            safe_echo "${RED}• Caddy: остановлен${NC}"
        fi
    else
        echo
        echo "Конфигурация: генерируется для Proxmox хоста"
        local proxmox_config="$CONFIG_DIR/proxmox/Caddyfile"
        if [[ -f "$proxmox_config" ]]; then
            safe_echo "${GREEN}• Конфигурация для Proxmox: сгенерирована${NC}"
        else
            safe_echo "${YELLOW}• Конфигурация для Proxmox: не сгенерирована${NC}"
        fi
    fi
    
    return 0
}

# Функция показа инструкций по SRV записи
show_srv_instructions() {
    print_header "НАСТРОЙКА SRV ЗАПИСИ ДЛЯ ФЕДЕРАЦИИ" "$YELLOW"
    
    local root_domain="${MATRIX_DOMAIN#*.}"
    
    safe_echo "${BLUE}📋 Для корректной работы федерации Matrix необходимо создать SRV запись${NC}"
    echo
    safe_echo "${BOLD}Параметры SRV записи:${NC}"
    safe_echo "   ${GREEN}Тип записи:${NC}    SRV"
    safe_echo "   ${GREEN}Услуга:${NC}        _matrix._tcp"
    safe_echo "   ${GREEN}Домен:${NC}         $root_domain. ${RED}(обязательно с точкой в конце!)${NC}"
    safe_echo "   ${GREEN}Приоритет:${NC}     10"
    safe_echo "   ${GREEN}Вес:${NC}           5"
    safe_echo "   ${GREEN}Порт:${NC}          8448"
    safe_echo "   ${GREEN}TTL:${NC}           3600 (или значение по умолчанию)"
    echo
    safe_echo "${BOLD}Пример записи:${NC}"
    safe_echo "${CYAN}_matrix._tcp.$root_domain. 3600 IN SRV 10 5 8448 $MATRIX_DOMAIN.${NC}"
    echo
    safe_echo "${BOLD}Проверка работы:${NC}"
    safe_echo "${YELLOW}dig SRV _matrix._tcp.$root_domain +short${NC}"
    echo
    safe_echo "${BOLD}Ожидаемый результат:${NC}"
    safe_echo "${GREEN}10 5 8448 $MATRIX_DOMAIN.${NC}"
    echo
    safe_echo "${RED}⚠️ ВАЖНО: После создания записи подождите до 24 часов для полного распространения DNS${NC}"
}

# Главная функция настройки Caddy
main() {
    print_header "НАСТРОЙКА CADDY ДЛЯ MATRIX (v4.1)" "$BLUE"
    
    # Проверка прав root
    check_root || return 1
    
    # Загрузка типа сервера
    load_server_type || return 1
    
    log "INFO" "Начало настройки Caddy для Matrix (тип сервера: $SERVER_TYPE)"
    
    # Получение конфигурации доменов
    get_domain_config || return 1
    
    # Определение backend адресов
    detect_backend_addresses
    
    # Ветвление по типу сервера
    case "$SERVER_TYPE" in
        "hosting")
            # Для хостинга: полная установка и настройка
            detect_ssl_certificates || return 1
            install_caddy || return 1
            create_hosting_config || return 1
            configure_caddy_service || return 1
            test_caddy_configuration
            
            print_header "CADDY НАСТРОЕН ДЛЯ ХОСТИНГА!" "$GREEN"
            safe_echo "${GREEN}✅ Caddy установлен и настроен по новой схеме${NC}"
            safe_echo "${BLUE}📋 Конфигурация: $CADDY_CONFIG_FILE${NC}"
            safe_echo "${BLUE}🔐 SSL: ${SSL_CERT_PATH}${NC}"
            safe_echo "${BLUE}🌐 Matrix API: https://$MATRIX_DOMAIN/_matrix/...${NC}"
            safe_echo "${BLUE}⚙️  Synapse Admin: https://$MATRIX_DOMAIN/admin${NC}"
            safe_echo "${BLUE}🔗 Element Web: https://$ELEMENT_DOMAIN${NC}"
            ;;
            
        "proxmox"|"home_server"|"docker"|"openvz")
            # Для Proxmox: генерация конфигурации и инструкций
            generate_proxmox_config || return 1
            show_proxmox_config
            show_srv_instructions
            
            print_header "КОНФИГУРАЦИЯ ДЛЯ PROXMOX ГОТОВА!" "$GREEN"
            safe_echo "${GREEN}✅ Конфигурация сгенерирована по новой схеме${NC}"
            safe_echo "${BLUE}📋 Скопируйте конфигурацию на хост Proxmox${NC}"
            safe_echo "${BLUE}📋 Создайте SRV запись в DNS${NC}"
            safe_echo "${BLUE}🌐 Matrix API: https://$MATRIX_DOMAIN/_matrix/...${NC}"
            safe_echo "${BLUE}⚙️  Synapse Admin: https://$MATRIX_DOMAIN/admin${NC}"
            ;;
            
        *)
            log "ERROR" "Неподдерживаемый тип сервера: $SERVER_TYPE"
            return 1
            ;;
    esac
    
    # Сохранение конфигурации
    set_config_value "$CONFIG_DIR/caddy.conf" "CADDY_CONFIGURED" "true"
    set_config_value "$CONFIG_DIR/caddy.conf" "CADDY_CONFIG_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
    set_config_value "$CONFIG_DIR/caddy.conf" "SERVER_TYPE" "$SERVER_TYPE"
    set_config_value "$CONFIG_DIR/caddy.conf" "CONFIG_VERSION" "4.1"
    
    echo
    safe_echo "${YELLOW}📝 Следующие шаги:${NC}"
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        safe_echo "   1. Убедитесь, что Matrix Synapse запущен на порту 8008"
        safe_echo "   2. Убедитесь, что Synapse Admin запущен на порту 8080"
        safe_echo "   3. Настройте DNS записи для всех доменов"
        safe_echo "   4. Проверьте доступность: https://$MATRIX_DOMAIN"
        safe_echo "   5. Протестируйте админку: https://$MATRIX_DOMAIN/admin"
        safe_echo "   6. Создайте SRV запись для федерации"
    else
        safe_echo "   1. Установите Caddy на хост Proxmox"
        safe_echo "   2. Скопируйте сгенерированную конфигурацию"
        safe_echo "   3. Получите SSL сертификаты (рекомендуется wildcard Cloudflare)"
        safe_echo "   4. Создайте SRV запись в DNS"
        safe_echo "   5. Запустите Caddy на хосте"
        safe_echo "   6. Проверьте доступность Matrix API и админки"
    fi
    
    return 0
}

# Экспорт функций
export -f main diagnose_caddy show_caddy_status show_proxmox_config show_srv_instructions

# Запуск, если вызван напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi