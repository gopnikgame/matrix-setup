#!/bin/bash

# Matrix Authentication Service (MAS) Management Module
# Все функции управления MAS, перенесённые из registration_mas.sh

# Определение директории скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключение общей библиотеки
if [ -f "${SCRIPT_DIR}/../common/common_lib.sh" ]; then
    source "${SCRIPT_DIR}/../common/common_lib.sh"
fi

# Настройки модуля
CONFIG_DIR="/opt/matrix-install"
MAS_CONFIG_DIR="/etc/mas"
MAS_CONFIG_FILE="$MAS_CONFIG_DIR/config.yaml"
SYNAPSE_MAS_CONFIG="/etc/matrix-synapse/conf.d/mas.yaml"
HOMESERVER_CONFIG="/etc/matrix-synapse/homeserver.yaml"
MAS_USER="matrix-synapse"
MAS_GROUP="matrix-synapse"
MAS_PORT_HOSTING="8080"
MAS_PORT_PROXMOX="8082"
MAS_DB_NAME="mas_db"

# --- Управляющие функции MAS ---

# Проверка статуса MAS
check_mas_status() {
    print_header "СТАТУС MATRIX AUTHENTICATION SERVICE" "$CYAN"

    # Проверяем, запущен ли процесс MAS
    if pgrep -f "mas" >/dev/null 2>&1; then
        echo "MAS запущен."
    else
        echo "MAS не запущен."
    fi

    # Проверяем, слушает ли MAS нужный порт
    if lsof -iTCP:$MAS_PORT_HOSTING -sTCP:LISTEN >/dev/null 2>&1; then
        echo "MAS слушает на порту $MAS_PORT_HOSTING."
    else
        echo "MAS НЕ слушает на порту $MAS_PORT_HOSTING."
    fi
}

# Удаление MAS
uninstall_mas() {
    print_header "УДАЛЕНИЕ MATRIX AUTHENTICATION SERVICE" "$RED"

    echo "Удаление MAS..."

    # Остановка службы MAS
    systemctl stop matrix-synapse.service

    # Удаление пакетов MAS
    apt-get remove --purge matrix-synapse mas -y

    # Удаление оставшихся конфигурационных файлов
    rm -rf $MAS_CONFIG_DIR
    rm -rf /etc/matrix-synapse/conf.d/mas.yaml
    rm -rf /etc/matrix-synapse/homeserver.yaml

    echo "MAS успешно удалён."
}

# Диагностика MAS
diagnose_mas() {
    print_header "ДИАГНОСТИКА MATRIX AUTHENTICATION SERVICE" "$BLUE"

    echo "Диагностика MAS..."

    # Проверка состояния службы MAS
    systemctl status matrix-synapse.service

    # Проверка логов MAS
    journalctl -u matrix-synapse.service --no-pager | tail -n 50

    # Проверка конфигурационных файлов MAS на наличие ошибок
    synapse_config="/etc/matrix-synapse/homeserver.yaml"
    if [ -f "$synapse_config" ]; then
        echo "Проверка конфигурации Synapse..."
        python3 -m synapse.config -c $synapse_config --validate
    fi

    echo "Диагностика завершена."
}

# Проверка наличия yq
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

# Получение статуса открытой регистрации MAS
get_mas_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local status=$(yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$status" = "true" ]; then
        echo "enabled"
    elif [ "$status" = "false" ]; then
        echo "disabled" 
    else
        echo "unknown"
    fi
}

# Получение статуса регистрации по токенам
get_mas_token_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if ! check_yq_dependency; then
        echo "unknown"
        return 1
    fi
    local status=$(yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$status" = "true" ]; then
        echo "enabled"
    elif [ "$status" = "false" ]; then
        echo "disabled"
    else
        echo "unknown"
    fi
}

# Изменение параметра в YAML файле
set_mas_config_value() {
    local key="$1"
    local value="$2"
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    if ! check_yq_dependency; then
        return 1
    fi
    log "INFO" "Изменение настройки $key на $value..."
    local full_path=""
    case "$key" in
        "password_registration_enabled"|"registration_token_required"|"email_change_allowed"|"displayname_change_allowed"|"password_change_allowed"|"password_recovery_enabled"|"account_deactivation_allowed")
            full_path=".account.$key"
            ;;
        *)
            log "ERROR" "Неизвестный параметр конфигурации: $key"
            return 1
            ;;
    esac
    if ! yq eval -i "$full_path = $value" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Не удалось изменить $key в $MAS_CONFIG_FILE"
        return 1
    fi
    log "INFO" "Перезапуск MAS для применения изменений..."
    if systemctl restart matrix-auth-service; then
        log "SUCCESS" "Настройка $key успешно изменена на $value"
    else
        log "ERROR" "Ошибка перезапуска matrix-auth-service"
        return 1
    fi
    return 0
}

# Генерация токена регистрации
generate_registration_token() {
    print_header "ГЕНЕРАЦИЯ ТОКЕНА РЕГИСТРАЦИИ" "$GREEN"

    local token_length=32

    # Генерация случайного токена
    local token=$(openssl rand -hex $token_length)

    echo "$token"
}

# Просмотр существующих токенов
view_registration_tokens() {
    print_header "ПРОСМОТР ТОКЕНОВ РЕГИСТРАЦИИ" "$BLUE"

    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi

    # Извлечение и отображение токенов с использованием yq
    yq eval '.registration.tokens[]' "$MAS_CONFIG_FILE"
}

manage_sso_providers() {
    print_header "УПРАВЛЕНИЕ ВНЕШНИМИ ПРОВАЙДЕРАМИ (SSO)" "$BLUE"

    # Проверка наличия yq
    if ! command -v yq &>/dev/null; then
        log "ERROR" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией MAS."
        log "INFO" "Пожалуйста, установите 'yq' (например, 'sudo apt install yq' или 'sudo snap install yq')"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    # Функция для синхронизации и перезапуска MAS
    sync_and_restart_mas() {
        log "INFO" "Синхронизация конфигурации MAS с базой данных..."
        if ! sudo -u "$MAS_USER" mas config sync --config "$MAS_CONFIG_FILE" --prune; then
            log "ERROR" "Ошибка синхронизации конфигурации MAS"
            return 1
        fi
        log "INFO" "Перезапуск MAS для применения изменений..."
        if systemctl restart matrix-auth-service; then
            log "SUCCESS" "Настройки SSO успешно обновлены"
            sleep 3
        else
            log "ERROR" "Ошибка перезапуска matrix-auth-service"
            return 1
        fi
    }

    # Функция для генерации ULID
    generate_ulid() {
        local timestamp=$(printf '%x' $(date +%s))
        local random_part=$(openssl rand -hex 10)
        echo "$(echo "$timestamp$random_part" | tr '[:lower:]' '[:upper:]')"
    }

    # Функция добавления провайдера
    add_sso_provider() {
        local provider_name="$1"
        local human_name="$2"
        local brand_name="$3"
        local issuer="$4"
        local scope="$5"
        local extra_config="$6"

        print_header "НАСТРОЙКА $human_name SSO" "$CYAN"
        case $provider_name in
            "google")
                safe_echo "1. Перейдите в Google API Console: https://console.developers.google.com/apis/credentials"
                safe_echo "2. Нажмите 'CREATE CREDENTIALS' -> 'OAuth client ID'. "
                safe_echo "3. Выберите 'Web application'."
                safe_echo "4. В 'Authorized redirect URIs' добавьте URI вашего MAS. Он будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Скопируйте 'Client ID' и 'Client Secret'."
                ;;
            "github")
                safe_echo "1. Перейдите в 'Developer settings' вашего GitHub профиля: https://github.com/settings/developers"
                safe_echo "2. Выберите 'OAuth Apps' -> 'New OAuth App'."
                safe_echo "3. 'Homepage URL': URL вашего MAS (например, https://auth.your-domain.com)."
                safe_echo "4. 'Authorization callback URL': URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Скопируйте 'Client ID' и сгенерируйте 'Client Secret'."
                ;;
            "gitlab")
                safe_echo "1. Перейдите в 'Applications' в настройках вашего профиля GitLab: https://gitlab.com/-/profile/applications"
                safe_echo "2. Создайте новое приложение."
                safe_echo "3. В 'Redirect URI' укажите URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "4. Включите скоупы: 'openid', 'profile', 'email'."
                safe_echo "5. Сохраните и скопируйте 'Application ID' (это Client ID) и 'Secret'."
                ;;
            "discord")
                safe_echo "1. Перейдите на Discord Developer Portal: https://discord.com/developers/applications"
                safe_echo "2. Создайте новое приложение."
                safe_echo "3. Перейдите во вкладку 'OAuth2'."
                safe_echo "4. В 'Redirects' добавьте URL для коллбэка. Будет показан после ввода данных."
                safe_echo "   Пример: https://auth.your-domain.com/upstream/callback/YOUR_ULID"
                safe_echo "5. Сохраните изменения и скопируйте 'Client ID' и 'Client Secret'."
                ;;
        esac
        echo
        read -p "Введите Client ID: " client_id
        read -p "Введите Client Secret: " client_secret
        if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
            log "ERROR" "Client ID и Client Secret не могут быть пустыми."
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        local ulid=$(generate_ulid)
        local mas_public_base=$(yq eval '.http.public_base' "$MAS_CONFIG_FILE")
        local redirect_uri="${mas_public_base}upstream/callback/${ulid}"
        safe_echo "Ваш Redirect URI для настройки в $human_name: $redirect_uri"
        echo
        if ! ask_confirmation "Продолжить добавление провайдера?"; then
            return
        fi
        local provider_yaml
        provider_yaml=$(cat <<EOF
{
  "id": "$ulid",
  "human_name": "$human_name",
  "brand_name": "$brand_name",
  "client_id": "$client_id",
  "client_secret": "$client_secret",
  "scope": "$scope"
}
EOF
)
        provider_yaml=$(echo "$provider_yaml" | yq eval '. as $item | '"$extra_config"' | $item * .' -)
        yq eval -i '.upstream_oauth2.providers += [load_str("-")]' "$MAS_CONFIG_FILE" -- - "$provider_yaml"
        sync_and_restart_mas
        read -p "Нажмите Enter для продолжения..."
    }

    # Функция удаления провайдера
    remove_sso_provider() {
        print_header "УДАЛЕНИЕ SSO-ПРОВАЙДЕРА" "$RED"
        local providers=$(yq eval '.upstream_oauth2.providers[] | .id + " " + .human_name' "$MAS_CONFIG_FILE")
        if [ -z "$providers" ]; then
            safe_echo "Нет настроенных SSO-провайдеров для удаления."
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        safe_echo "Список настроенных провайдеров:"
        echo "$providers"
        echo
        read -p "Введите ID провайдера для удаления: " id_to_remove
        if [ -z "$id_to_remove" ]; then
            log "WARN" "ID не указан."
            return
        fi
        if ask_confirmation "Вы уверены, что хотите удалить провайдера с ID $id_to_remove?"; then
            yq eval -i 'del(.upstream_oauth2.providers[] | select(.id == "'"$id_to_remove"'"))' "$MAS_CONFIG_FILE"
            sync_and_restart_mas
        fi
        read -p "Нажмите Enter для продолжения..."
    }

    while true; do
        print_header "УПРАВЛЕНИЕ SSO" "$BLUE"
        safe_echo "Текущие SSO-провайдеры:"
        local current_providers=$(yq eval -o=json '.upstream_oauth2.providers' "$MAS_CONFIG_FILE")
        if [ -z "$current_providers" ] || [ "$current_providers" = "null" ] || [ "$current_providers" = "[]" ]; then
            safe_echo "SSO-провайдеры не настроены."
        else
            echo "$current_providers" | yq eval -P '.[] | .human_name + " (ID: " + .id + ")"' -
        fi
        echo
        safe_echo "Доступные опции:"
        safe_echo "1. ➕ Добавить Google"
        safe_echo "2. ➕ Добавить GitHub"
        safe_echo "3. ➕ Добавить GitLab"
        safe_echo "4. ➕ Добавить Discord"
        safe_echo "5. 🗑️  Удалить провайдера"
        safe_echo "6. ↩️  Вернуться в главное меню"
        echo
        read -p "Выберите опцию [1-6]: " choice
        case $choice in
            1)
                add_sso_provider "google" "Google" "google" "" "openid profile email" '.issuer = "https://accounts.google.com" | .token_endpoint_auth_method = "client_secret_post"'
                ;;
            2)
                add_sso_provider "github" "GitHub" "github" "" "read:user" '.discovery_mode = "disabled" | .fetch_userinfo = true | .token_endpoint_auth_method = "client_secret_post" | .authorization_endpoint = "https://github.com/login/oauth/authorize" | .token_endpoint = "https://github.com/login/oauth/access_token" | .userinfo_endpoint = "https://api.github.com/user" | .claims_imports.subject.template = "{{ userinfo_claims.id }}"'
                ;;
            3)
                add_sso_provider "gitlab" "GitLab" "gitlab" "" "openid profile email" '.issuer = "https://gitlab.com" | .token_endpoint_auth_method = "client_secret_post"'
                ;;
            4)
                add_sso_provider "discord" "Discord" "discord" "" "identify email" '.discovery_mode = "disabled" | .fetch_userinfo = true | .token_endpoint_auth_method = "client_secret_post" | .authorization_endpoint = "https://discord.com/oauth2/authorize" | .token_endpoint = "https://discord.com/api/oauth2/token" | .userinfo_endpoint = "https://discord.com/api/users/@me"'
                ;;
            5)
                remove_sso_provider
                ;;
            6)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Попробуйте снова"
                sleep 1
                ;;
        esac
    done
}

# Меню управления CAPTCHA
manage_captcha_settings() {
    print_header "УПРАВЛЕНИЕ CAPTCHA" "$BLUE"

    # Проверка наличия yq
    if ! command -v yq &>/dev/null; then
        log "ERROR" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией MAS."
        log "INFO" "Пожалуйста, установите 'yq' (например, 'sudo apt install yq' или 'sudo snap install yq')"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    # Инструкция по интеграции reCAPTCHA
    show_captcha_instructions() {
        print_header "ИНТЕГРАЦИЯ reCAPTCHA" "$CYAN"
        safe_echo "Для работы CAPTCHA требуется получить ключи reCAPTCHA v2 или v3:"
        safe_echo "1. Перейдите на https://www.google.com/recaptcha/admin/create"
        safe_echo "2. Зарегистрируйте домен, выберите тип reCAPTCHA (v2/v3)"
        safe_echo "3. Получите Site Key и Secret Key"
        safe_echo "4. Вставьте их в конфиг MAS:"
        safe_echo "   .registration.captcha_site_key"
        safe_echo "   .registration.captcha_secret_key"
        safe_echo "5. Включите CAPTCHA в настройках"
        echo
    }

    # Включение CAPTCHA
    enable_captcha() {
        show_captcha_instructions
        read -p "Введите Site Key: " site_key
        read -p "Введите Secret Key: " secret_key
        if [ -z "$site_key" ] || [ -z "$secret_key" ]; then
            log "ERROR" "Site Key и Secret Key не могут быть пустыми."
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        yq eval -i '.registration.captcha_enabled = true' "$MAS_CONFIG_FILE"
        yq eval -i '.registration.captcha_site_key = "'$site_key'"' "$MAS_CONFIG_FILE"
        yq eval -i '.registration.captcha_secret_key = "'$secret_key'"' "$MAS_CONFIG_FILE"
        log "SUCCESS" "CAPTCHA включена и ключи сохранены."
        systemctl restart matrix-auth-service
        read -p "Нажмите Enter для продолжения..."
    }

    # Отключение CAPTCHA
    disable_captcha() {
        yq eval -i '.registration.captcha_enabled = false' "$MAS_CONFIG_FILE"
        log "SUCCESS" "CAPTCHA отключена."
        systemctl restart matrix-auth-service
        read -p "Нажмите Enter для продолжения..."
    }

    # Изменение секретного ключа
    change_captcha_secret() {
        read -p "Введите новый Secret Key: " secret_key
        if [ -z "$secret_key" ]; then
            log "ERROR" "Secret Key не может быть пустым."
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        yq eval -i '.registration.captcha_secret_key = "'$secret_key'"' "$MAS_CONFIG_FILE"
        log "SUCCESS" "Secret Key обновлён."
        systemctl restart matrix-auth-service
        read -p "Нажмите Enter для продолжения..."
    }

    while true; do
        print_header "CAPTCHA" "$BLUE"
        safe_echo "Текущий статус CAPTCHA:"
        local status=$(yq eval '.registration.captcha_enabled' "$MAS_CONFIG_FILE")
        if [ "$status" = "true" ]; then
            safe_echo "CAPTCHA включена."
        else
            safe_echo "CAPTCHA отключена."
        fi
        echo
        safe_echo "1. Включить CAPTCHA (и задать ключи)"
        safe_echo "2. Выключить CAPTCHA"
        safe_echo "3. Изменить Secret Key"
        safe_echo "4. Показать инструкцию по интеграции"
        safe_echo "5. Назад"
        echo
        read -p "Выберите действие [1-5]: " action
        case $action in
            1)
                enable_captcha
                ;;
            2)
                disable_captcha
                ;;
            3)
                change_captcha_secret
                ;;
            4)
                show_captcha_instructions
                read -p "Нажмите Enter для продолжения..."
                ;;
            5)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
    done
}

# Меню управления заблокированными именами
manage_banned_usernames() {
    print_header "УПРАВЛЕНИЕ ЗАБЛОКИРОВАННЫМИ ИМЕНАМИ" "$BLUE"

    # Проверка наличия yq
    if ! command -v yq &>/dev/null; then
        log "ERROR" "Утилита 'yq' не найдена. Она необходима для управления YAML конфигурацией MAS."
        log "INFO" "Пожалуйста, установите 'yq' (например, 'sudo apt install yq' или 'sudo snap install yq')"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    # Инструкция по использованию заблокированных имён
    show_banned_usernames_instructions() {
        print_header "ИНСТРУКЦИЯ ПО ЗАБЛОКИРОВАННЫМ ИМЕНАМ" "$CYAN"
        safe_echo "Блокировка имён предотвращает регистрацию пользователей с определёнными именами."
        safe_echo "1. Добавьте имя в список, чтобы запретить его регистрацию."
        safe_echo "2. Удалите имя из списка для разблокировки."
        safe_echo "3. Список хранится в .registration.banned_usernames в $MAS_CONFIG_FILE."
        safe_echo "4. После изменений требуется перезапуск MAS."
        echo
    }

    # Добавление заблокированного имени
    add_banned_username() {
        read -p "Введите имя для блокировки: " username
        if [ -z "$username" ]; then
            log "ERROR" "Имя не может быть пустым."
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        yq eval -i '.registration.banned_usernames += ["'$username'"]' "$MAS_CONFIG_FILE"
        log "SUCCESS" "Имя '$username' добавлено в список заблокированных."
        systemctl restart matrix-auth-service
        read -p "Нажмите Enter для продолжения..."
    }

    # Удаление заблокированного имени
    remove_banned_username() {
        read -p "Введите имя для разблокировки: " username
        if [ -z "$username" ]; then
            log "ERROR" "Имя не может быть пустым."
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        yq eval -i 'del(.registration.banned_usernames[] | select(. == "'$username'"))' "$MAS_CONFIG_FILE"
        log "SUCCESS" "Имя '$username' удалено из списка заблокированных."
        systemctl restart matrix-auth-service
        read -p "Нажмите Enter для продолжения..."
    }

    # Показать заблокированные имена
    show_banned_usernames() {
        print_header "СПИСОК ЗАБЛОКИРОВАННЫХ ИМЁН" "$CYAN"
        local banned=$(yq eval '.registration.banned_usernames' "$MAS_CONFIG_FILE")
        if [ -z "$banned" ] || [ "$banned" = "null" ]; then
            safe_echo "Список заблокированных имён пуст."
        else
            echo "$banned" | yq eval -P '.' -
        fi
        echo
        read -p "Нажмите Enter для продолжения..."
    }

    while true; do
        print_header "ЗАБЛОКИРОВАННЫЕ ИМЕНА" "$BLUE"
        safe_echo "1. Добавить заблокированное имя"
        safe_echo "2. Удалить заблокированное имя"
        safe_echo "3. Показать заблокированные имена"
        safe_echo "4. Показать инструкцию по использованию"
        safe_echo "5. Назад"
        echo
        read -p "Выберите действие [1-5]: " action
        case $action in
            1)
                add_banned_username
                ;;
            2)
                remove_banned_username
                ;;
            3)
                show_banned_usernames
                ;;
            4)
                show_banned_usernames_instructions
                read -p "Нажмите Enter для продолжения..."
                ;;
            5)
                return 0
                ;;
            *)
                log "ERROR" "Некорректный ввод. Попробуйте ещё раз."
                sleep 1
                ;;
        esac
    done
}

# Меню управления регистрацией MAS
manage_mas_registration() {
    print_header "УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ MATRIX AUTHENTICATION SERVICE" "$BLUE"

    echo "Управление регистрацией MAS:"
    echo "1. Включить открытую регистрацию"
    echo "2. Выключить открытую регистрацию"
    echo "3. Настроить регистрацию по токенам"
    echo "4. Назад"

    read -p "Выберите действие: " action

    case $action in
        1)
            set_mas_config_value '.registration.enable_registration' 'true'
            ;;
        2)
            set_mas_config_value '.registration.enable_registration' 'false'
            ;;
        3)
            read -p "Введите новый лимит регистраций: " registration_limit
            set_mas_config_value '.registration.registration_limit' "$registration_limit"
            ;;
        4)
            echo "Возврат в главное меню."
            ;;
        *)
            echo "Некорректный ввод. Попробуйте ещё раз."
            manage_mas_registration
            ;;
    esac
}

# Главное меню модуля
show_main_menu() {
    echo "Matrix Authentication Service (MAS) - Главное меню"
    echo "1. Проверить статус MAS"
    echo "2. Удалить MAS"
    echo "3. Диагностика MAS"
    echo "4. Управление регистрацией MAS"
    echo "5. Управление SSO-провайдерами"
    echo "6. Управление CAPTCHA"
    echo "7. Управление заблокированными именами"
    echo "8. Выход"

    read -p "Выберите действие: " action

    case $action in
        1)
            check_mas_status
            ;;
        2)
            uninstall_mas
            ;;
        3)
            diagnose_mas
            ;;
        4)
            manage_mas_registration
            ;;
        5)
            manage_sso_providers
            ;;
        6)
            manage_captcha_settings
            ;;
        7)
            manage_banned_usernames
            ;;
        8)
            echo "Выход из MAS Management Module."
            exit 0
            ;;
        *)
            echo "Некорректный ввод. Попробуйте ещё раз."
            show_main_menu
            ;;
    esac
}

# Главная функция управления MAS
main() {
    show_main_menu
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
