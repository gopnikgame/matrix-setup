#!/bin/bash

# Caddy Configuration Module for Matrix Setup
# Версия: 5.0.0 - Полностью переработанная конфигурация с поддержкой MAS
# Модуль настройки Caddy для Matrix

# Настройки модуля
LIB_NAME="Caddy Configuration Manager"
LIB_VERSION="5.0.0"
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
    
    if [[ -f "$domain_file" ]]; then
        ROOT_DOMAIN=$(cat "$domain_file")
        log "INFO" "Корневой домен: $ROOT_DOMAIN"
    else
        log "ERROR" "Не найден файл с доменом Matrix сервера в $domain_file"
        return 1
    fi
    
    # Новая схема доменов
    MATRIX_DOMAIN="matrix.${ROOT_DOMAIN}"
    ELEMENT_DOMAIN="element.${ROOT_DOMAIN}"
    
    log "INFO" "Домены: Root=$ROOT_DOMAIN, Matrix=$MATRIX_DOMAIN, Element=$ELEMENT_DOMAIN"
    export ROOT_DOMAIN MATRIX_DOMAIN ELEMENT_DOMAIN
    return 0
}

# Функция определения SSL сертификатов (только для хостинга)
detect_ssl_certificates() {
    if [[ "$SERVER_TYPE" != "hosting" ]]; then
        return 0
    fi
    
    local cert_path=""
    local key_path=""
    
    # Поиск wildcard сертификатов (приоритет)
    local wildcard_path="/etc/letsencrypt/live/${ROOT_DOMAIN}"
    if [[ -f "$wildcard_path/fullchain.pem" ]] && [[ -f "$wildcard_path/privkey.pem" ]]; then
        cert_path="$wildcard_path/fullchain.pem"
        key_path="$wildcard_path/privkey.pem"
        log "INFO" "Найдены wildcard сертификаты: $wildcard_path"
    fi
    
    if [[ -z "$cert_path" ]]; then
        log "WARN" "Wildcard SSL сертификаты не найдены для домена $ROOT_DOMAIN"
        log "INFO" "Caddy попытается получить их автоматически, но рекомендуется настроить wildcard вручную."
        show_ssl_help
        # Не возвращаем ошибку, Caddy может справиться сам
    fi
    
    export SSL_CERT_PATH="$cert_path"
    export SSL_KEY_PATH="$key_path"
    return 0
}

# Функция показа помощи по SSL сертификатам
show_ssl_help() {
    print_header "НАСТРОЙКА WILDCARD SSL СЕРТИФИКАТОВ" "$YELLOW"
    safe_echo "${BOLD}Рекомендуемый вариант: Cloudflare wildcard (БЕСПЛАТНО)${NC}"
    safe_echo "${GREEN}1. Установите плагин Certbot для Cloudflare:${NC}"
    safe_echo "   sudo apt update && sudo apt install certbot python3-certbot-dns-cloudflare"
    safe_echo "${GREEN}2. Создайте файл с API токеном Cloudflare:${NC}"
    safe_echo "   sudo mkdir -p /etc/cloudflare && sudo nano /etc/cloudflare/cloudflare.ini"
    safe_echo "   # Содержимое: dns_cloudflare_api_token = ВАШ_API_ТОКЕН"
    safe_echo "   sudo chmod 600 /etc/cloudflare/cloudflare.ini"
    safe_echo "${GREEN}3. Получите wildcard сертификат:${NC}"
    safe_echo "   sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/cloudflare/cloudflare.ini -d \"${ROOT_DOMAIN}\" -d \"*.${ROOT_DOMAIN}\" --register-unsafely-without-email"
    echo
}

# Функция определения backend адресов
detect_backend_addresses() {
    local ip_addr
    case "$SERVER_TYPE" in
        "proxmox"|"home_server"|"docker"|"openvz")
            ip_addr="${LOCAL_IP:-192.168.88.165}"
            ;;
        *)
            ip_addr="127.0.0.1"
            ;;
    esac
    
    # Новая схема портов
    SYNAPSE_BACKEND="${ip_addr}:8008"
    FEDERATION_BACKEND="${ip_addr}:8448"
    ADMIN_BACKEND="${ip_addr}:8080"
    ELEMENT_BACKEND="${ip_addr}:8081"
    MAS_BACKEND="${ip_addr}:8082"
    
    log "INFO" "Backend адреса: Synapse=$SYNAPSE_BACKEND, MAS=$MAS_BACKEND, Element=$ELEMENT_BACKEND, Admin=$ADMIN_BACKEND"
    export SYNAPSE_BACKEND FEDERATION_BACKEND ADMIN_BACKEND ELEMENT_BACKEND MAS_BACKEND
}

# Функция установки Caddy (только для хостинга)
install_caddy() {
    if [[ "$SERVER_TYPE" != "hosting" ]]; then
        log "INFO" "Пропуск установки Caddy для типа сервера: $SERVER_TYPE"
        return 0
    fi
    
    if command -v caddy >/dev/null 2>&1; then
        log "INFO" "Caddy уже установлен: $(caddy version | head -n1)"
        return 0
    fi
    
    print_header "УСТАНОВКА CADDY" "$BLUE"
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update
    if ! apt install -y caddy; then
        log "ERROR" "Ошибка установки Caddy"
        return 1
    fi
    log "SUCCESS" "Caddy установлен: $(caddy version | head -n1)"
    return 0
}

# Функция создания общей части конфигурации Caddy
generate_caddyfile_content() {
    local tls_line=""
    if [[ -n "$SSL_CERT_PATH" ]] && [[ -n "$SSL_KEY_PATH" ]]; then
        tls_line="tls $SSL_CERT_PATH $SSL_KEY_PATH"
    else
        # Для хостинга без сертификатов Caddy получит их сам
        # Для Proxmox путь будет вставлен напрямую
        if [[ "$SERVER_TYPE" == "proxmox"|"home_server"|"docker"|"openvz" ]]; then
            tls_line="tls /etc/letsencrypt/live/$ROOT_DOMAIN/fullchain.pem /etc/letsencrypt/live/$ROOT_DOMAIN/privkey.pem"
        fi
    fi

    cat <<EOF
# Caddy Configuration for Matrix Server (v5.0)
# Generated by Matrix Setup Tool
# Server Type: $SERVER_TYPE
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# ==============================================
# ГЛОБАЛЬНЫЕ НАСТРОЙКИ
# ==============================================
{
    email admin@${ROOT_DOMAIN}
    default_sni $MATRIX_DOMAIN
}

# ==============================================
# КОРНЕВОЙ ДОМЕН (ДЛЯ ФЕДЕРАЦИИ)
# ==============================================
$ROOT_DOMAIN {
    $tls_line

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

    # Отдаем пустую страницу по умолчанию
    respond "Federation discovery domain for $ROOT_DOMAIN" 200
}

# ==============================================
# ОСНОВНОЙ ДОМЕН MATRIX API И MAS
# ==============================================
$MATRIX_DOMAIN {
    $tls_line

    # --- MATRIX AUTHENTICATION SERVICE (MAS) ---
    # ПОРЯДОК ОБРАБОТКИ КРИТИЧЕН!

    # MAS Compatibility Layer (для старых клиентов)
    handle_path /_matrix/client/*/login {
        reverse_proxy $MAS_BACKEND
    }
    handle_path /_matrix/client/*/logout {
        reverse_proxy $MAS_BACKEND
    }
    handle_path /_matrix/client/*/refresh {
        reverse_proxy $MAS_BACKEND
    }
    
    # MAS Endpoints
    handle_path /.well-known/openid-configuration { reverse_proxy $MAS_BACKEND }
    handle_path /account/* { reverse_proxy $MAS_BACKEND }
    handle_path /oauth2/* { reverse_proxy $MAS_BACKEND }
    handle_path /authorize { reverse_proxy $MAS_BACKEND }
    handle_path /auth/* { reverse_proxy $MAS_BACKEND }
    handle_path /device/* { reverse_proxy $MAS_BACKEND }
    handle_path /graphql { reverse_proxy $MAS_BACKEND }
    handle_path /api/admin/* { reverse_proxy $MAS_BACKEND }
    handle_path /assets/* { reverse_proxy $MAS_BACKEND }

    # --- SYNAPSE ADMIN ---
    route /admin/* {
        uri strip_prefix /admin
        reverse_proxy $ADMIN_BACKEND
    }

    # --- MATRIX SYNAPSE API (в последнюю очередь) ---
    route /_matrix/* {
        reverse_proxy $SYNAPSE_BACKEND
    }
    route /_synapse/* {
        reverse_proxy $SYNAPSE_BACKEND
    }

    # --- ЗАГОЛОВКИ БЕЗОПАСНОСТИ ---
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
    }
}

# ==============================================
# ФЕДЕРАЦИЯ (ОТДЕЛЬНЫЙ ПОРТ)
# ==============================================
$MATRIX_DOMAIN:8448 {
    $tls_line
    reverse_proxy $FEDERATION_BACKEND
}

# ==============================================
# ELEMENT WEB CLIENT
# ==============================================
$ELEMENT_DOMAIN {
    $tls_line
    reverse_proxy $ELEMENT_BACKEND

    header /assets/* Cache-Control "public, max-age=31536000, immutable"
    header /index.html Cache-Control "no-cache"

    header {
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; font-src 'self' data:; connect-src 'self' https://$MATRIX_DOMAIN wss://$MATRIX_DOMAIN; worker-src 'self' blob:; frame-src 'self';"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
}

# Функция создания конфигурации для хостинга
create_hosting_config() {
    print_header "СОЗДАНИЕ КОНФИГУРАЦИИ CADDY ДЛЯ ХОСТИНГА" "$CYAN"
    
    if [[ -f "$CADDY_CONFIG_FILE" ]]; then
        backup_file "$CADDY_CONFIG_FILE" "caddy-config"
    fi
    
    mkdir -p "$CADDY_CONFIG_DIR"
    
    generate_caddyfile_content > "$CADDY_CONFIG_FILE"
    
    if ! caddy validate --config "$CADDY_CONFIG_FILE"; then
        log "ERROR" "Ошибка в конфигурации Caddy. Проверьте $CADDY_CONFIG_FILE"
        return 1
    fi
    
    chown root:root "$CADDY_CONFIG_FILE"
    chmod 644 "$CADDY_CONFIG_FILE"
    
    log "SUCCESS" "Конфигурация Caddy для хостинга создана: $CADDY_CONFIG_FILE"
    return 0
}

# Функция генерации конфигурации для Proxmox
generate_proxmox_config() {
    print_header "ГЕНЕРАЦИЯ КОНФИГУРАЦИИ ДЛЯ PROXMOX" "$CYAN"
    
    mkdir -p "$CONFIG_DIR/proxmox"
    local proxmox_config="$CONFIG_DIR/proxmox/Caddyfile"
    
    generate_caddyfile_content > "$proxmox_config"
    
    local instructions_file="$CONFIG_DIR/proxmox/setup-instructions.txt"
    cat > "$instructions_file" <<EOF
# ИНСТРУКЦИИ ПО НАСТРОЙКЕ CADDY НА PROXMOX ХОСТЕ (v5.0)

## 1. УСТАНОВИТЕ CADDY НА ХОСТЕ PROXMOX
(Если еще не установлен)
sudo apt update && sudo apt install -y curl gpg
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

## 2. СКОПИРУЙТЕ КОНФИГУРАЦИЮ
sudo cp "$proxmox_config" /etc/caddy/Caddyfile

## 3. НАСТРОЙТЕ DNS ЗАПИСИ
Вам понадобятся следующие A-записи, указывающие на ПУБЛИЧНЫЙ IP вашего хоста Proxmox:
- A-запись:   $ROOT_DOMAIN -> [PUBLIC_IP]
- A-запись:   $MATRIX_DOMAIN -> [PUBLIC_IP]
- A-запись:   $ELEMENT_DOMAIN -> [PUBLIC_IP]

И SRV-запись для федерации:
- Тип:         SRV
- Услуга:      _matrix._tcp
- Домен:       $ROOT_DOMAIN. (с точкой!)
- Приоритет:   10
- Вес:         5
- Порт:        8448
- Цель:        $MATRIX_DOMAIN. (с точкой!)

## 4. ПОЛУЧИТЕ SSL СЕРТИФИКАТЫ (WILDCARD)
sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/cloudflare/cloudflare.ini -d "$ROOT_DOMAIN" -d "*.$ROOT_DOMAIN" --register-unsafely-without-email
(Инструкции по настройке certbot-dns-cloudflare см. в документации)

## 5. ЗАПУСТИТЕ CADDY
sudo systemctl enable --now caddy
sudo systemctl status caddy

## 6. НАСТРОЙКА ФАЙРВОЛА НА ХОСТЕ
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 8448/tcp

## 7. ПРОВЕРКА
- Федерация: curl https://$ROOT_DOMAIN/.well-known/matrix/server
- Клиент: curl https://$ROOT_DOMAIN/.well-known/matrix/client
- MAS: curl https://$MATRIX_DOMAIN/.well-known/openid-configuration
- Админка: https://$MATRIX_DOMAIN/admin
- Element: https://$ELEMENT_DOMAIN
EOF

    log "SUCCESS" "Конфигурация для Proxmox сгенерирована:"
    safe_echo "${BLUE}   📄 Caddyfile: $proxmox_config${NC}"
    safe_echo "${BLUE}   📋 Инструкции: $instructions_file${NC}"
    return 0
}

# Функция показа конфигурации для Proxmox
show_proxmox_config() {
    local instructions_file="$CONFIG_DIR/proxmox/setup-instructions.txt"
    if [[ ! -f "$instructions_file" ]]; then
        log "ERROR" "Инструкции для Proxmox не найдены. Сгенерируйте их сначала."
        return 1
    fi
    
    print_header "ИНСТРУКЦИИ ПО НАСТРОЙКЕ CADDY НА PROXMOX" "$CYAN"
    cat "$instructions_file"
    return 0
}

# Функция настройки системного сервиса Caddy (только для хостинга)
configure_caddy_service() {
    if [[ "$SERVER_TYPE" != "hosting" ]]; then
        return 0
    fi
    
    log "INFO" "Настройка и перезапуск службы Caddy..."
    if ! systemctl enable --now caddy; then
        log "ERROR" "Ошибка запуска/включения Caddy"
        return 1
    fi
    
    if ! systemctl reload caddy; then
        log "WARN" "Не удалось перезагрузить Caddy, пробую перезапустить..."
        if ! systemctl restart caddy; then
            log "ERROR" "Ошибка перезапуска Caddy"
            return 1
        fi
    fi
    
    sleep 3
    if ! systemctl is-active --quiet caddy; then
        log "ERROR" "Caddy не запустился. Логи: journalctl -u caddy -n 20"
        return 1
    fi
    
    log "SUCCESS" "Служба Caddy настроена и запущена"
    return 0
}

# Функция диагностики Caddy
diagnose_caddy() {
    print_header "ДИАГНОСТИКА CADDY (v5.0)" "$CYAN"
    log "INFO" "Запуск диагностики Caddy..."
    
    echo "Тип сервера: $SERVER_TYPE"
    
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        if command -v caddy >/dev/null 2>&1; then
            safe_echo "${GREEN}✓ Caddy установлен: $(caddy version | head -n1)${NC}"
        else
            safe_echo "${RED}✗ Caddy не установлен${NC}"
        fi
        if [[ -f "$CADDY_CONFIG_FILE" ]]; then
            safe_echo "${GREEN}✓ Конфигурационный файл существует${NC}"
            if caddy validate --config "$CADDY_CONFIG_FILE" >/dev/null 2>&1; then
                safe_echo "${GREEN}✓ Синтаксис корректен${NC}"
            else
                safe_echo "${RED}✗ Ошибка в синтаксисе${NC}"
            fi
        else
            safe_echo "${RED}✗ Конфигурационный файл отсутствует${NC}"
        fi
        if systemctl is-active --quiet caddy; then
            safe_echo "${GREEN}✓ Служба Caddy запущена${NC}"
        else
            safe_echo "${RED}✗ Служба Caddy не запущена${NC}"
        fi
    else
        local proxmox_config="$CONFIG_DIR/proxmox/Caddyfile"
        if [[ -f "$proxmox_config" ]]; then
            safe_echo "${GREEN}✓ Конфигурация для Proxmox сгенерирована${NC}"
        else
            safe_echo "${YELLOW}! Конфигурация для Proxmox не сгенерирована${NC}"
        fi
    fi
}

# Функция показа статуса Caddy
show_caddy_status() {
    print_header "СТАТУС CADDY (v5.0)" "$CYAN"
    
    echo "Тип сервера: ${SERVER_TYPE:-не определен}"
    echo
    echo "Настроенные домены:"
    echo "  - Корневой (федерация): ${ROOT_DOMAIN:-не определен}"
    echo "  - Matrix API & MAS: ${MATRIX_DOMAIN:-не определен}"
    echo "  - Element Web: ${ELEMENT_DOMAIN:-не определен}"
    echo
    echo "Backend адреса:"
    echo "  - Synapse API: ${SYNAPSE_BACKEND:-не определен}"
    echo "  - Federation: ${FEDERATION_BACKEND:-не определен}"
    echo "  - MAS: ${MAS_BACKEND:-не определен}"
    echo "  - Element Web: ${ELEMENT_BACKEND:-не определен}"
    echo "  - Synapse Admin: ${ADMIN_BACKEND:-не определен}"
    
    if [[ "$SERVER_TYPE" == "hosting" ]]; then
        echo
        if systemctl is-active --quiet caddy; then
            safe_echo "Статус службы: ${GREEN}запущен${NC}"
        else
            safe_echo "Статус службы: ${RED}остановлен${NC}"
        fi
    fi
}

# Функция показа инструкций по SRV записи
show_srv_instructions() {
    print_header "НАСТРОЙКА SRV ЗАПИСИ ДЛЯ ФЕДЕРАЦИИ" "$YELLOW"
    safe_echo "${BOLD}Параметры SRV записи:${NC}"
    safe_echo "   ${GREEN}Тип записи:${NC}    SRV"
    safe_echo "   ${GREEN}Услуга:${NC}        _matrix._tcp"
    safe_echo "   ${GREEN}Домен:${NC}         $ROOT_DOMAIN. ${RED}(с точкой!)${NC}"
    safe_echo "   ${GREEN}Приоритет:${NC}     10"
    safe_echo "   ${GREEN}Вес:${NC}           5"
    safe_echo "   ${GREEN}Порт:${NC}          8448"
    safe_echo "   ${GREEN}Цель:${NC}          $MATRIX_DOMAIN. ${RED}(с точкой!)${NC}"
    echo
    safe_echo "${BOLD}Проверка:${NC} dig SRV _matrix._tcp.$ROOT_DOMAIN +short"
    safe_echo "${BOLD}Ожидаемый результат:${NC} 10 5 8448 $MATRIX_DOMAIN."
}

# Главная функция настройки Caddy
main() {
    print_header "НАСТРОЙКА CADDY ДЛЯ MATRIX (v5.0)" "$BLUE"
    
    check_root || return 1
    load_server_type || return 1
    
    log "INFO" "Начало настройки Caddy для Matrix (тип сервера: $SERVER_TYPE)"
    
    get_domain_config || return 1
    detect_backend_addresses
    
    case "$SERVER_TYPE" in
        "hosting")
            detect_ssl_certificates || return 1
            install_caddy || return 1
            create_hosting_config || return 1
            configure_caddy_service || return 1
            
            print_header "CADDY НАСТРОЕН ДЛЯ ХОСТИНГА!" "$GREEN"
            safe_echo "✅ Caddy установлен и настроен по новой схеме."
            safe_echo "Проверьте DNS записи для доменов: $ROOT_DOMAIN, $MATRIX_DOMAIN, $ELEMENT_DOMAIN"
            show_srv_instructions
            ;;
            
        "proxmox"|"home_server"|"docker"|"openvz")
            generate_proxmox_config || return 1
            show_proxmox_config
            
            print_header "КОНФИГУРАЦИЯ ДЛЯ PROXMOX ГОТОВА!" "$GREEN"
            safe_echo "✅ Конфигурация и инструкции сгенерированы."
            safe_echo "Следуйте инструкциям в файле $CONFIG_DIR/proxmox/setup-instructions.txt"
            ;;
            
        *)
            log "ERROR" "Неподдерживаемый тип сервера: $SERVER_TYPE"
            return 1
            ;;
    esac
    
    set_config_value "$CONFIG_DIR/caddy.conf" "CADDY_CONFIGURED" "true"
    set_config_value "$CONFIG_DIR/caddy.conf" "CONFIG_VERSION" "5.0"
    
    return 0
}

# Экспорт функций
export -f main diagnose_caddy show_caddy_status show_proxmox_config show_srv_instructions

# Запуск, если вызван напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi