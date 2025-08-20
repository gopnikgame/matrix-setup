#!/bin/bash

# Matrix Authentication Service (MAS) - Модуль управления регистрацией
# Версия: 1.2.0 - исправлена проблема с правами доступа

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
MAS_WORK_DIR="/var/lib/mas"

# Проверка root прав
check_root

# Загружаем тип сервера
load_server_type

# Проверка существования пользователя MAS
if ! id -u "$MAS_USER" >/dev/null 2>&1; then
    log "ERROR" "Пользователь $MAS_USER не существует"
    exit 1
fi

# Функция для проверки и создания рабочей среды MAS
ensure_mas_environment() {
    log "DEBUG" "Проверка и создание рабочей среды MAS..."
    
    # Создаем рабочую директорию если нужно
    if [ ! -d "$MAS_WORK_DIR" ]; then
        log "INFO" "Создание рабочей директории MAS: $MAS_WORK_DIR"
        mkdir -p "$MAS_WORK_DIR"
    fi
    
    # Устанавливаем правильные права
    chown "$MAS_USER:$MAS_GROUP" "$MAS_WORK_DIR" 2>/dev/null || {
        log "ERROR" "Не удалось установить владельца рабочей директории"
        return 1
    }
    chmod 755 "$MAS_WORK_DIR" 2>/dev/null || {
        log "ERROR" "Не удалось установить права на рабочую директорию"
        return 1
    }
    
    # Создаем .env файл если нужно
    local env_file="$MAS_WORK_DIR/.env"
    if [ ! -f "$env_file" ]; then
        log "DEBUG" "Создание .env файла в рабочей директории"
        cat > "$env_file" << 'EOF'
# MAS Environment Variables
# Created by matrix-setup automation

RUST_LOG=info
EOF
        chown "$MAS_USER:$MAS_GROUP" "$env_file" 2>/dev/null
        chmod 600 "$env_file" 2>/dev/null
    fi
    
    # Проверяем права на конфигурационный файл
    if [ -f "$MAS_CONFIG_FILE" ]; then
        if ! sudo -u "$MAS_USER" test -r "$MAS_CONFIG_FILE"; then
            log "WARN" "Исправление прав доступа к конфигурационному файлу"
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null
            chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null
        fi
    fi
    
    log "DEBUG" "Рабочая среда MAS готова"
    return 0
}

# Проверка и исправление установки yq при запуске (АГРЕССИВНОЕ УДАЛЕНИЕ SNAP)
check_and_fix_yq_installation() {
    log "DEBUG" "АГРЕССИВНАЯ проверка корректности установки yq..."
    
    # Шаг 1: Полное удаление всех версий yq
    log "INFO" "Удаляем ВСЕ существующие версии yq..."
    
    # Удаляем snap версию максимально агрессивно
    if command -v snap &>/dev/null; then
        log "DEBUG" "Принудительное удаление snap версии yq..."
        snap remove yq 2>/dev/null || true
        snap remove yq --purge 2>/dev/null || true
        # Ждем завершения операций snap
        sleep 2
    fi
    
    # Удаляем все возможные бинарники yq из всех известных мест
    local yq_paths=(
        "/usr/local/bin/yq"
        "/usr/bin/yq"
        "/opt/bin/yq"
        "$HOME/bin/yq"
        "/snap/bin/yq"
        "/var/lib/snapd/snap/bin/yq"
        "/snap/yq/current/bin/yq"
        "/usr/local/sbin/yq"
        "/usr/sbin/yq"
        "/sbin/yq"
        "/bin/yq"
    )
    
    for path in "${yq_paths[@]}"; do
        if [ -f "$path" ] || [ -L "$path" ]; then
            log "DEBUG" "Удаляем: $path"
            rm -f "$path" 2>/dev/null || true
        fi
    done
    
    # Очищаем кэш команд агрессивно
    hash -d yq 2>/dev/null || true
    hash -r 2>/dev/null || true
    unset -f yq 2>/dev/null || true
    
    # Ждем
    sleep 1
    
    # Убеждаемся, что yq больше не найден
    local attempts=0
    while command -v yq &>/dev/null && [ $attempts -lt 5 ]; do
        local remaining_path=$(which yq 2>/dev/null)
        log "WARN" "yq все еще найден по пути: $remaining_path, попытка удаления $((attempts + 1))"
        rm -f "$remaining_path" 2>/dev/null || true
        
        # Если это snap путь, убиваем snap процессы
        if [[ "$remaining_path" == *"/snap/"* ]]; then
            log "DEBUG" "Найден snap путь, принудительное завершение snap процессов..."
            pkill -f "snap.*yq" 2>/dev/null || true
            umount -f "/snap/yq"* 2>/dev/null || true
            rm -rf "/snap/yq" 2>/dev/null || true
            rm -rf "/var/lib/snapd/snap/yq" 2>/dev/null || true
        fi
        
        hash -r 2>/dev/null || true
        sleep 1
        ((attempts++))
    done
    
    # Окончательная проверка отсутствия yq
    if command -v yq &>/dev/null; then
        local final_path=$(which yq 2>/dev/null)
        log "ERROR" "Не удалось полностью удалить yq: $final_path"
        log "DEBUG" "Попытка принудительного удаления из PATH..."
        
        # Временно исключаем из PATH
        local old_path="$PATH"
        export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v snap | tr '\n' ':' | sed 's/:$//')
        
        # Проверяем снова
        if command -v yq &>/dev/null; then
            log "ERROR" "yq все еще найден даже после удаления snap из PATH"
            export PATH="$old_path"  # Возвращаем PATH
            return 1
        else
            log "DEBUG" "yq успешно исключен из PATH"
            export PATH="$old_path"  # Возвращаем PATH
        fi
    else
        log "SUCCESS" "Все версии yq успешно удалены"
    fi
    
    # Шаг 2: Принудительная установка правильной версии
    log "INFO" "Принудительная установка правильной версии yq..."
    
    # Определяем архитектуру
    local arch=$(uname -m)
    local yq_binary=""
    
    case "$arch" in
        x86_64) yq_binary="yq_linux_amd64" ;;
        aarch64|arm64) yq_binary="yq_linux_arm64" ;;
        armv7l|armv6l) yq_binary="yq_linux_arm" ;;
        *)
            log "ERROR" "Неподдерживаемая архитектура: $arch"
            return 1
            ;;
    esac
    
    log "DEBUG" "Архитектура: $arch, бинарник: $yq_binary"
    
    # URL для загрузки
    local yq_url="https://github.com/mikefarah/yq/releases/latest/download/$yq_binary"
    log "DEBUG" "URL для загрузки: $yq_url"
    
    # Пытаемся установить в /usr/local/bin с проверкой
    local install_success=false
    local install_path="/usr/local/bin/yq"
    
    # Создаем директорию если нужно
    mkdir -p "$(dirname "$install_path")"
    
    # Скачиваем с помощью curl
    if command -v curl &>/dev/null; then
        log "DEBUG" "Скачивание yq с помощью curl..."
        if curl -sSL --connect-timeout 30 --retry 3 "$yq_url" -o "$install_path"; then
            chmod +x "$install_path"
            
            # ВАЖНО: Проверяем что это не snap и что файл работает
            if [ -f "$install_path" ] && "$install_path" --version >/dev/null 2>&1; then
                # Дополнительная проверка что это не snap
                local file_info=$(file "$install_path" 2>/dev/null || echo "")
                if [[ "$file_info" == *"ELF"* ]]; then
                    install_success=true
                    log "SUCCESS" "yq успешно установлен в $install_path"
                else
                    log "ERROR" "Установленный файл не является исполняемым ELF файлом"
                    rm -f "$install_path"
                fi
            else
                log "ERROR" "Установленный yq не работает"
                rm -f "$install_path"
            fi
        else
            log "ERROR" "Не удалось скачать yq с помощью curl"
        fi
    elif command -v wget &>/dev/null; then
        log "DEBUG" "Скачивание yq с помощью wget..."
        if wget -q --timeout=30 --tries=3 -O "$install_path" "$yq_url"; then
            chmod +x "$install_path"
            
            if [ -f "$install_path" ] && "$install_path" --version >/dev/null 2>&1; then
                local file_info=$(file "$install_path" 2>/dev/null || echo "")
                if [[ "$file_info" == *"ELF"* ]]; then
                    install_success=true
                    log "SUCCESS" "yq успешно установлен в $install_path"
                else
                    log "ERROR" "Установленный файл не является исполняемым ELF файлом"
                    rm -f "$install_path"
                fi
            else
                log "ERROR" "Установленный yq не работает"
                rm -f "$install_path"
            fi
        else
            log "ERROR" "Не удалось скачать yq с помощью wget"
        fi
    else
        log "ERROR" "Не найдены curl или wget для скачивания yq"
        return 1
    fi
    
    # Обновляем PATH и кэш команд
    export PATH="/usr/local/bin:$PATH"
    hash -r 2>/dev/null || true
    
    # Финальная проверка установки
    if [ "$install_success" = true ] && command -v yq &>/dev/null; then
        local yq_version=$(yq --version 2>/dev/null || echo "unknown")
        local yq_path=$(which yq 2>/dev/null)
        log "SUCCESS" "yq успешно установлен и работает"
        log "DEBUG" "Версия: $yq_version"
        log "DEBUG" "Расположение: $yq_path"
        
        # Финальная проверка что это НЕ snap версия
        if [[ "$yq_path" == *"/snap/"* ]]; then
            log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: Установилась snap версия несмотря на все предостережения!"
            return 1
        fi
        
        # Проверяем что можем выполнить простую команду
        if echo "test: value" | yq eval '.test' - >/dev/null 2>&1; then
            log "SUCCESS" "yq успешно прошел функциональный тест"
            return 0
        else
            log "ERROR" "yq установлен, но не прошел функциональный тест"
            return 1
        fi
    else
        log "ERROR" "Не удалось установить рабочую версию yq"
        log "DEBUG" "Проверьте подключение к интернету и права доступа"
        
        # Показываем пользователю команды для ручной установки
        safe_echo "${RED}❌ Не удалось автоматически установить yq${NC}"
        safe_echo "${YELLOW}Выполните вручную:${NC}"
        safe_echo "sudo curl -sSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq"
        safe_echo "sudo chmod +x /usr/local/bin/yq"
        
        return 1
    fi
}

# Проверка и установка yq (БЕЗ SNAP)
check_yq_dependency() {
    log "DEBUG" "Проверка наличия yq..."
    
    # Сначала агрессивно удаляем все следы snap версии
    if command -v snap &>/dev/null; then
        log "DEBUG" "Удаляем snap версию yq..."
        snap remove yq 2>/dev/null
        sleep 1
    fi
    
    # Удаляем все возможные бинарники yq
    local yq_paths=("/usr/local/bin/yq" "/usr/bin/yq" "/opt/bin/yq" "$HOME/bin/yq" "/snap/bin/yq")
    for path in "${yq_paths[@]}"; do
        if [ -f "$path" ] || [ -L "$path" ]; then
            rm -f "$path" 2>/dev/null
            log "DEBUG" "Удален: $path"
        fi
    done
    
    # Очищаем кэш команд
    hash -r 2>/dev/null
    sleep 1
    
    # Проверяем, остались ли следы yq
    if command -v yq &>/dev/null; then
        local remaining_path=$(which yq 2>/dev/null)
        log "WARN" "yq все еще найден по пути: $remaining_path"
        rm -f "$remaining_path" 2>/dev/null
        hash -r
    fi
    
    # Теперь устанавливаем правильную версию
    log "INFO" "Установка yq без snap..."
    
    # Определяем архитектуру
    local arch=$(uname -m)
    local yq_binary=""
    
    case "$arch" in
        x86_64) yq_binary="yq_linux_amd64" ;;
        aarch64|arm64) yq_binary="yq_linux_arm64" ;;
        armv7l|armv6l) yq_binary="yq_linux_arm" ;;
        *)
            log "ERROR" "Неподдерживаемая архитектура: $arch"
            return 1
            ;;
    esac
    
    log "DEBUG" "Архитектура: $arch, бинарник: $yq_binary"
    
    # URL для загрузки
    local yq_url="https://github.com/mikefarah/yq/releases/latest/download/$yq_binary"
    log "DEBUG" "URL для загрузки: $yq_url"
    
    # Пытаемся установить в /usr/local/bin
    local install_success=false
    
    # Вариант 1: Установка в /usr/local/bin с curl
    if command -v curl &>/dev/null; then
        log "DEBUG" "Пытаемся установить с помощью curl в /usr/local/bin"
        if curl -sSL --connect-timeout 30 --retry 3 "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            if /usr/local/bin/yq --version >/dev/null 2>&1; then
                install_success=true
                log "SUCCESS" "yq успешно установлен в /usr/local/bin"
            fi
        fi
    fi
    
    # Вариант 2: Установка в /usr/local/bin с wget
    if [ "$install_success" = false ] && command -v wget &>/dev/null; then
        log "DEBUG" "Пытаемся установить с помощью wget в /usr/local/bin"
        if wget -q --timeout=30 --tries=3 -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            if /usr/local/bin/yq --version >/dev/null 2>&1; then
                install_success=true
                log "SUCCESS" "yq успешно установлен в /usr/local/bin"
            fi
        fi
    fi
    
    # Вариант 3: Установка в /opt/bin
    if [ "$install_success" = false ] && [ -w "/opt" ]; then
        log "DEBUG" "Пытаемся установить в /opt/bin"
        mkdir -p /opt/bin
        if command -v curl &>/dev/null; then
            if curl -sSL --connect-timeout 30 "$yq_url" -o /opt/bin/yq; then
                chmod +x /opt/bin/yq
                export PATH="/opt/bin:$PATH"
                if /opt/bin/yq --version >/dev/null 2>&1; then
                    install_success=true
                fi
            fi
        elif command -v wget &>/dev/null; then
            if wget -q --timeout=30 -O /opt/bin/yq "$yq_url"; then
                chmod +x /opt/bin/yq
                export PATH="/opt/bin:$PATH"
                if /opt/bin/yq --version >/dev/null 2>&1; then
                    install_success=true
                fi
            fi
        fi
    fi
    
    # Проверяем успешность установки
    if [ "$install_success" = true ] && command -v yq &>/dev/null; then
        local yq_version=$(yq --version 2>/dev/null || echo "unknown")
        local yq_path=$(which yq 2>/dev/null)
        log "SUCCESS" "yq успешно установлен, версия: $yq_version"
        log "DEBUG" "Расположение: $yq_path"
        
        # Проверяем, что это не snap версия
        if [[ "$yq_path" == *"/snap/"* ]]; then
            log "ERROR" "Установилась snap версия несмотря на все precautions!"
            return 1
        fi
        
        return 0
    else
        log "ERROR" "Не удалось установить yq"
        log "DEBUG" "Проверьте подключение к интернету и права доступа"
        
        # Показываем пользователю команды для ручной установки
        safe_echo "${RED}❌ Не удалось автоматически установить yq${NC}"
        safe_echo "${YELLOW}Выполните вручную:${NC}"
        safe_echo "sudo curl -sSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq"
        safe_echo "sudo chmod +x /usr/local/bin/yq"
        
        return 1
    fi
}

# Инициализация секции account
initialize_mas_account_section() {
    log "INFO" "Инициализация секции account в конфигурации MAS..."
    log "DEBUG" "Путь к конфигурационному файлу: $MAS_CONFIG_FILE"
    
    # Проверка существования файла конфигурации
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "DEBUG" "Проверка существования директории: $(ls -la "$(dirname "$MAS_CONFIG_FILE")" 2>/dev/null || echo "Директория недоступна")"
        return 1
    fi
    
    log "DEBUG" "Файл конфигурации существует, размер: $(stat -c %s "$MAS_CONFIG_FILE" 2>/dev/null || echo "неизвестно") байт"
    
    # Проверяем, есть ли уже секция account
    log "DEBUG" "Проверка наличия секции account в файле конфигурации"
    if sudo -u "$MAS_USER" yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        log "DEBUG" "Секция account обнаружена в конфигурации"
        local account_content=$(sudo -u "$MAS_USER" yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
        
        if [ "$account_content" != "null" ] && [ -n "$account_content" ]; then
            log "INFO" "Секция account уже существует и содержит данные"
            log "DEBUG" "Содержимое секции account: $(echo "$account_content" | head -c 100)..."
            return 0
        else
            log "DEBUG" "Секция account существует, но пуста или содержит null"
        fi
    else
        log "DEBUG" "Секция account отсутствует в конфигурации, требуется создание"
    fi
    
    # Сохраняем текущие права доступа
    log "DEBUG" "Сохранение текущих прав доступа к файлу конфигурации"
    local original_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null)
    local original_perms=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "Текущий владелец: ${original_owner:-неизвестно}, права: ${original_perms:-неизвестно}"
    
    # Проверяем права на запись и временно изменяем их при необходимости
    log "DEBUG" "Проверка прав на запись для пользователя $MAS_USER"
    if ! sudo -u "$MAS_USER" test -w "$MAS_CONFIG_FILE"; then
        log "WARN" "Пользователь $MAS_USER не имеет прав на запись в файл конфигурации"
        log "DEBUG" "Временное изменение прав доступа для редактирования"
        
        if chown root:root "$MAS_CONFIG_FILE"; then
            log "DEBUG" "Владелец временно изменен на root:root"
        else
            log "ERROR" "Не удалось изменить владельца файла"
            return 1
        fi
        
        if chmod 644 "$MAS_CONFIG_FILE"; then
            log "DEBUG" "Права доступа временно изменены на 644"
        else
            log "ERROR" "Не удалось изменить права доступа файла"
            # Пытаемся восстановить оригинального владельца
            [ -n "$original_owner" ] && chown "$original_owner" "$MAS_CONFIG_FILE" 2>/dev/null
            return 1
        fi
    else
        log "DEBUG" "Пользователь $MAS_USER имеет права на запись в файл конфигурации"
    fi
    
    # Создаем резервную копию
    log "DEBUG" "Создание резервной копии конфигурационного файла"
    backup_file "$MAS_CONFIG_FILE" "mas_config_account_init"
    local backup_result=$?
    local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_account_init_* 2>/dev/null | head -1)
    
    if [ $backup_result -eq 0 ] && [ -f "$latest_backup" ]; then
        log "SUCCESS" "Резервная копия создана: $latest_backup"
        log "DEBUG" "Размер резервной копии: $(stat -c %s "$latest_backup" 2>/dev/null || echo "неизвестно") байт"
    else
        log "WARN" "Проблема при создании резервной копии (код: $backup_result)"
    fi
    
    log "INFO" "Добавление секции account в конфигурацию MAS..."
    
    # Сохраняем контрольную сумму файла перед изменением
    log "DEBUG" "Сохранение контрольной суммы файла перед изменением"
    local checksum_before=""
    if command -v md5sum >/dev/null 2>&1; then
        checksum_before=$(md5sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "MD5 до изменения: $checksum_before"
    elif command -v sha1sum >/dev/null 2>&1; then
        checksum_before=$(sha1sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "SHA1 до изменения: $checksum_before"
    fi
    
    # Используем yq для добавления секции account
    log "DEBUG" "Выполнение команды yq для добавления секции account"
    local yq_output=""
    local yq_exit_code=0
    
    if ! yq_output=$(sudo -u "$MAS_USER" yq eval -i '.account = {
        "password_registration_enabled": false,
        "registration_token_required": false,
        "email_change_allowed": true,
        "displayname_change_allowed": true,
        "password_change_allowed": true,
        "password_recovery_enabled": false,
        "account_deactivation_allowed": false
    }' "$MAS_CONFIG_FILE" 2>&1); then
        yq_exit_code=$?
        log "ERROR" "Ошибка при выполнении yq (код: $yq_exit_code): $yq_output"
        log "DEBUG" "Размер файла после ошибки: $(stat -c %s "$MAS_CONFIG_FILE" 2>/dev/null || echo "неизвестно") байт"
    else
        log "DEBUG" "Команда yq выполнена успешно"
        log "DEBUG" "Размер файла после изменения: $(stat -c %s "$MAS_CONFIG_FILE" 2>/dev/null || echo "неизвестно") байт"
    fi
    
    # Проверяем контрольную сумму после изменения
    if [ -n "$checksum_before" ]; then
        log "DEBUG" "Проверка изменения контрольной суммы файла"
        local checksum_after=""
        if command -v md5sum >/dev/null 2>&1; then
            checksum_after=$(md5sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
            log "DEBUG" "MD5 после изменения: $checksum_after"
        elif command -v sha1sum >/dev/null 2>&1; then
            checksum_after=$(sha1sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
            log "DEBUG" "SHA1 после изменения: $checksum_after"
        fi
        
        if [ "$checksum_before" = "$checksum_after" ]; then
            log "WARN" "Файл не изменился после выполнения yq (контрольные суммы совпадают)"
        else
            log "DEBUG" "Файл успешно изменен (контрольные суммы отличаются)"
        fi
    fi
    
    # Восстанавливаем оригинальные права доступа
    log "DEBUG" "Восстановление оригинальных прав доступа"
    if [ -n "$original_owner" ]; then
        if chown "$original_owner" "$MAS_CONFIG_FILE"; then
            log "DEBUG" "Оригинальный владелец восстановлен: $original_owner"
        else
            log "ERROR" "Не удалось восстановить оригинального владельца"
        fi
    fi
    
    if [ -n "$original_perms" ]; then
        if chmod "$original_perms" "$MAS_CONFIG_FILE"; then
            log "DEBUG" "Оригинальные права доступа восстановлены: $original_perms"
        else
            log "ERROR" "Не удалось восстановить оригинальные права доступа"
        fi
    fi
    
    # Проверяем результат выполнения yq
    if [ $yq_exit_code -eq 0 ]; then
        log "SUCCESS" "Секция account успешно добавлена в конфигурацию"
        
        # Проверяем валидность YAML
        log "DEBUG" "Проверка валидности YAML после модификации"
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                log "ERROR" "YAML файл поврежден после добавления секции account"
                
                # Восстанавливаем из резервной копии
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    log "INFO" "Восстановление конфигурации из резервной копии: $latest_backup"
                    if restore_file "$latest_backup" "$MAS_CONFIG_FILE"; then
                        log "SUCCESS" "Конфигурация успешно восстановлена из резервной копии"
                    else
                        log "ERROR" "Не удалось восстановить конфигурацию из резервной копии"
                    fi
                else
                    log "ERROR" "Резервная копия не найдена для восстановления"
                fi
                return 1
            else
                log "DEBUG" "YAML файл валиден после модификации"
            fi
        else
            log "WARN" "Python3 не найден, пропуск проверки валидности YAML"
        fi
    else
        log "ERROR" "Не удалось добавить секцию account (код ошибки: $yq_exit_code)"
        
        # Проверяем, не поврежден ли файл после неудачной попытки
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                log "ERROR" "YAML файл поврежден после неудачной попытки модификации"
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    log "INFO" "Восстановление из резервной копии после ошибки yq"
                    if restore_file "$latest_backup" "$MAS_CONFIG_FILE" ]; then
                        log "SUCCESS" "Конфигурация восстановлена после ошибки"
                    fi
                fi
            else
                log "DEBUG" "YAML файл остался валидным несмотря на ошибку yq"
            fi
        fi
        return 1
    fi
    
    # Устанавливаем окончательные права доступа
    log "DEBUG" "Установка окончательных прав доступа: владелец=$MAS_USER:$MAS_GROUP, права=600"
    if chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"; then
        log "DEBUG" "Владелец файла установлен: $MAS_USER:$MAS_GROUP"
    else
        log "ERROR" "Не удалось установить владельца файла"
    fi
    
    if chmod 600 "$MAS_CONFIG_FILE"; then
        log "DEBUG" "Права доступа установлены: 600"
    else
        log "ERROR" "Не удалось установить права доступа"
    fi
    
    # Финальная проверка прав доступа
    local final_perms=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null)
    local final_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "Финальные права доступа: $final_perms, владелец: $final_owner"
    
    # Перезапускаем MAS для применения изменений
    log "INFO" "Перезапуск Matrix Authentication Service для применения изменений..."
    local restart_output=""
    
    if restart_output=$(restart_service "matrix-auth-service" 2>&1); then
        log "DEBUG" "Команда перезапуска выполнена успешно"
        log "DEBUG" "Ожидание запуска службы (2 секунды)..."
        sleep 2
        
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "Matrix Authentication Service успешно запущен после перезапуска"
            
            # Дополнительная проверка доступности службы
            log "DEBUG" "Проверка статуса службы..."
            local service_status=$(systemctl status matrix-auth-service --no-pager 2>&1 | head -5)
            log "DEBUG" "Статус службы: $service_status"
        else
            log "ERROR" "Matrix Authentication Service не запустился после изменения конфигурации"
            log "DEBUG" "Вывод systemctl status: $(systemctl status matrix-auth-service --no-pager -n 10 2>&1)"
            
            # Проверяем журнал systemd для диагностики
            log "DEBUG" "Последние записи в журнале:"
            journalctl -u matrix-auth-service -n 5 --no-pager 2>&1 | while read -r line; do
                log "DEBUG" "  $line"
            done
            return 1
        fi
    else
        log "ERROR" "Ошибка выполнения команды перезапуска: $restart_output"
        return 1
    fi
    
    log "SUCCESS" "Инициализация секции account завершена успешно"
    return 0
}

# Изменение параметра в YAML файле (УЛУЧШЕННАЯ ВЕРСИЯ)
set_mas_config_value() {
    local key="$1"
    local value="$2"
    
    log "INFO" "Начинаем изменение параметра $key на значение '$value'"
    log "DEBUG" "Проверка существования файла конфигурации: $MAS_CONFIG_FILE"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        log "DEBUG" "Содержимое директории $(dirname "$MAS_CONFIG_FILE"): $(ls -la "$(dirname "$MAS_CONFIG_FILE")" 2>/dev/null || echo "недоступно")"
        return 1
    fi
    
    log "DEBUG" "Файл конфигурации существует, размер: $(stat -c %s "$MAS_CONFIG_FILE" 2>/dev/null || echo "неизвестно") байт"
    
    # ПРИНУДИТЕЛЬНАЯ проверка корректности yq перед использованием
    log "DEBUG" "Принудительная проверка корректности yq перед изменением конфигурации..."
    if ! check_and_fix_yq_installation; then
        log "ERROR" "Не удалось обеспечить корректную установку yq"
        return 1
    fi
    
    # Проверяем версию yq
    local yq_version=$(yq --version 2>/dev/null || echo "Unknown")
    log "DEBUG" "Используемая версия yq: $yq_version"
    
    # Проверяем что это НЕ snap версия
    local yq_path=$(which yq 2>/dev/null)
    if [[ "$yq_path" == *"/snap/"* ]]; then
        log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: Обнаружена snap версия yq по пути: $yq_path"
        log "ERROR" "Принудительное удаление snap версии и переустановка..."
        if ! check_and_fix_yq_installation; then
            log "ERROR" "Не удалось исправить проблему со snap версией yq"
            return 1
        fi
    fi
    
    local full_path=""
    case "$key" in
        "password_registration_enabled"|"registration_token_required"|"email_change_allowed"|"displayname_change_allowed"|"password_change_allowed"|"password_recovery_enabled"|"account_deactivation_allowed")
            full_path=".account.$key"
            
            log "DEBUG" "Проверка наличия секции account для параметра: $key"
            if ! sudo -u "$MAS_USER" yq eval '.account' "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
                log "WARN" "Секция account отсутствует, инициализирую..."
                if ! initialize_mas_account_section; then
                    log "ERROR" "Не удалось инициализировать секцию account"
                    return 1
                fi
            else
                log "DEBUG" "Секция account уже существует"
            fi
            ;;
        "captcha_service")
            full_path=".captcha.service"
            ;;
        "captcha_site_key")
            full_path=".captcha.site_key"
            ;;
        "captcha_secret_key")
            full_path=".captcha.secret_key"
            ;;
        *)
            log "ERROR" "Неизвестный параметр конфигурации: $key"
            log "DEBUG" "Доступные параметры: password_registration_enabled, registration_token_required, email_change_allowed, displayname_change_allowed, password_change_allowed, password_recovery_enabled, account_deactivation_allowed, captcha_service, captcha_site_key, captcha_secret_key"
            return 1
            ;;
    esac
    
    log "DEBUG" "Полный путь к параметру: $full_path"
    
    # Проверяем текущее значение параметра
    local current_value=$(sudo -u "$MAS_USER" yq eval "$full_path" "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "Текущее значение параметра $key: '$current_value'"
    
    if [ "$current_value" = "$value" ]; then
        log "INFO" "Параметр $key уже имеет значение '$value', изменение не требуется"
        return 0
    fi
    
    # Проверяем права доступа к файлу конфигурации
    local file_perms=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null)
    local file_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "Права на файл конфигурации: $file_perms, владелец: $file_owner"
    
    # Проверяем, имеет ли пользователь MAS права на запись
    if ! sudo -u "$MAS_USER" test -w "$MAS_CONFIG_FILE"; then
        log "WARN" "Пользователь $MAS_USER не имеет прав на запись в файл конфигурации"
        log "DEBUG" "Временное изменение прав для редактирования"
        
        # Сохраняем оригинальные права
        local original_owner="$file_owner"
        local original_perms="$file_perms"
        
        # Временно даем права root для редактирования
        if chown root:root "$MAS_CONFIG_FILE"; then
            log "DEBUG" "Владелец временно изменен на root:root"
        else
            log "ERROR" "Не удалось изменить владельца файла"
            return 1
        fi
        
        if chmod 644 "$MAS_CONFIG_FILE"; then
            log "DEBUG" "Права доступа временно изменены на 644"
        else
            log "ERROR" "Не удалось изменить права доступа файла"
            chown "$original_owner" "$MAS_CONFIG_FILE" 2>/dev/null
            return 1
        fi
    else
        log "DEBUG" "Пользователь $MAS_USER имеет права на запись в файл конфигурации"
    fi
    
    # Создаем резервную копию
    log "DEBUG" "Создание резервной копии конфигурационного файла"
    backup_file "$MAS_CONFIG_FILE" "mas_config_change"
    local backup_result=$?
    local latest_backup=$(ls -t "$BACKUP_DIR"/mas_config_change_* 2>/dev/null | head -1)
    
    if [ $backup_result -eq 0 ] && [ -f "$latest_backup" ]; then
        log "SUCCESS" "Резервная копия создана: $latest_backup"
        log "DEBUG" "Размер резервной копии: $(stat -c %s "$latest_backup" 2>/dev/null || echo "неизвестно") байт"
    else
        log "WARN" "Проблема при создании резервной копии (код: $backup_result)"
    fi
    
    # Сохраняем контрольную сумму файла перед изменением
    local checksum_before=""
    if command -v md5sum >/dev/null 2>&1; then
        checksum_before=$(md5sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "MD5 до изменения: $checksum_before"
    fi
    
    # Основная попытка изменения с помощью yq
    log "INFO" "Применение изменения: $full_path = $value"
    local yq_output=""
    local yq_exit_code=0
    local config_success=false
    
    if ! yq_output=$(sudo -u "$MAS_USER" yq eval -i "$full_path = $value" "$MAS_CONFIG_FILE" 2>&1); then
        yq_exit_code=$?
        log "ERROR" "Ошибка при выполнении yq (код: $yq_exit_code): $yq_output"
    else
        log "DEBUG" "Команда yq выполнена успешно"
        config_success=true
    fi
    
    # Проверяем контрольную сумму после изменения
    if [ -n "$checksum_before" ] && [ "$config_success" = true ]; then
        local checksum_after=$(md5sum "$MAS_CONFIG_FILE" 2>/dev/null | awk '{print $1}')
        log "DEBUG" "MD5 после изменения: $checksum_after"
        
        if [ "$checksum_before" = "$checksum_after" ]; then
            log "WARN" "Файл не изменился после выполнения yq (MD5 совпадает)"
            config_success=false
        else
            log "DEBUG" "Файл успешно изменен (MD5 отличается)"
        fi
    fi
    
    # Проверяем, что изменение действительно применилось
    if [ "$config_success" = true ]; then
        local new_value=$(sudo -u "$MAS_USER" yq eval "$full_path" "$MAS_CONFIG_FILE" 2>/dev/null)
        if [ "$new_value" = "$value" ]; then
            log "DEBUG" "Подтверждение: значение $key успешно изменено на '$value'"
        else
            log "WARN" "Изменение не применено: ожидалось '$value', получено '$new_value'"
            config_success=false
        fi
    fi
    
    # Восстанавливаем оригинальные права доступа
    if [ -n "$original_owner" ]; then
        log "DEBUG" "Восстановление оригинальных прав доступа: $original_owner:$original_perms"
        chown "$original_owner" "$MAS_CONFIG_FILE" 2>/dev/null
        chmod "$original_perms" "$MAS_CONFIG_FILE" 2>/dev/null
    fi
    
    # Если изменение не удалось, восстанавливаем из бэкапа
    if [ "$config_success" = false ]; then
        log "ERROR" "Не удалось применить изменения к конфигурации"
        
        if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
            log "INFO" "Восстановление конфигурации из резервной копии: $latest_backup"
            if cp "$latest_backup" "$MAS_CONFIG_FILE"; then
                log "SUCCESS" "Конфигурация успешно восстановлена из резервной копии"
                # Восстанавливаем права после восстановления
                if [ -n "$original_owner" ]; then
                    chown "$original_owner" "$MAS_CONFIG_FILE" 2>/dev/null
                    chmod "$original_perms" "$MAS_CONFIG_FILE" 2>/dev/null
                fi
            else
                log "ERROR" "Не удалось восстановить конфигурацию из резервной копии"
            fi
        else
            log "ERROR" "Резервная копия не найдена для восстановления"
        fi
        return 1
    fi
    
    # Проверяем валидность YAML после изменений
    log "DEBUG" "Проверка валидности YAML после изменений"
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "ERROR" "YAML файл поврежден после изменений"
            if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                cp "$latest_backup" "$MAS_CONFIG_FILE"
                log "INFO" "Конфигурация восстановлена из резервной копии после повреждения YAML"
            fi
            return 1
        else
            log "DEBUG" "YAML файл валиден после изменений"
        fi
    else
        log "WARN" "Python3 не найден, пропуск проверки валидности YAML"
    fi
    
    # Устанавливаем окончательные права доступа
    log "DEBUG" "Установка окончательных прав доступа: владелец=$MAS_USER:$MAS_GROUP, права=600"
    chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null
    chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null
    
    # Перезапускаем MAS для применения изменений
    log "INFO" "Перезапуск Matrix Authentication Service для применения изменений..."
    local restart_output=""
    
    if restart_output=$(restart_service "matrix-auth-service" 2>&1); then
        log "DEBUG" "Команда перезапуска выполнена успешно"
        sleep 2
        
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "Matrix Authentication Service успешно запущен после перезапуска"
            
            # Дополнительная проверка доступности службы
            local service_status=$(systemctl is-active matrix-auth-service 2>&1)
            log "DEBUG" "Статус службы: $service_status"
            
        else
            log "ERROR" "Matrix Authentication Service не запустился после изменения конфигурации"
            log "DEBUG" "Вывод systemctl status:"
            systemctl status matrix-auth-service --no-pager -n 5 2>&1 | while read -r line; do
                log "DEBUG" "  $line"
            done
            return 1
        fi
    else
        log "ERROR" "Ошибка выполнения команды перезагрузки: $restart_output"
        return 1
    fi
    
    # Финальная проверка значения после перезагрузки
    local final_value=$(sudo -u "$MAS_USER" yq eval "$full_path" "$MAS_CONFIG_FILE" 2>/dev/null)
    log "DEBUG" "Финальное значение параметра $key после перезапуска: '$final_value'"
    
    if [ "$final_value" = "$value" ]; then
        log "SUCCESS" "Параметр $key успешно изменен на '$value' и применен после перезапуска"
    else
        log "WARN" "Значение параметра изменилось после перезапуска: '$final_value' (ожидалось: '$value')"
    fi
    
    return 0
}

# Просмотр секции account конфигурации MAS
view_mas_account_config() {
    print_header "КОНФИГУРАЦИЯ СЕКЦИИ ACCOUNT В MAS" "$CYAN"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Файл конфигурации MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    # Принудительная проверка yq перед использованием
    log "DEBUG" "Проверка корректности yq для просмотра конфигурации..."
    if ! check_and_fix_yq_installation; then
        log "ERROR" "Невозможно продолжить без корректной версии yq"
        safe_echo "${RED}❌ Невозможно просмотреть конфигурацию без yq${NC}"
        return 1
    fi
    
    safe_echo "${BOLD}Текущая конфигурация секции account:${NC}"
    echo
    
    # Проверяем наличие секции account
    local yq_output=""
    if ! yq_output=$(sudo -u "$MAS_USER" yq eval '.account' "$MAS_CONFIG_FILE" 2>&1); then
        safe_echo "${RED}Секция account отсутствует в конфигурации MAS${NC}"
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Используйте пункты меню выше для включения настроек регистрации"
        safe_echo "• Секция account будет создана автоматически при первом изменении"
        return 1
    fi
    
    local account_content=$(sudo -u "$MAS_USER" yq eval '.account' "$MAS_CONFIG_FILE" 2>/dev/null)
    
    if [ "$account_content" = "null" ] || [ -z "$account_content" ]; then
        safe_echo "${RED}Секция account пуста или повреждена${NC}"
        echo
        safe_echo "${YELLOW}📝 Рекомендация:${NC}"
        safe_echo "• Попробуйте переинициализировать секцию через пункт '1. Включить открытую регистрацию'"
        return 1
    fi
    
    # Показываем основные параметры регистрации
    safe_echo "${CYAN}🔐 Настройки регистрации:${NC}"
    
    local password_reg=$(sudo -u "$MAS_USER" yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$password_reg" = "true" ]; then
        safe_echo "  • password_registration_enabled: ${GREEN}true${NC} (открытая регистрация включена)"
    elif [ "$password_reg" = "false" ]; then
        safe_echo "  • password_registration_enabled: ${RED}false${NC} (открытая регистрация отключена)"
    else
        safe_echo "  • password_registration_enabled: ${YELLOW}$password_reg${NC}"
    fi
    
    local token_req=$(sudo -u "$MAS_USER" yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>/dev/null)
    if [ "$token_req" = "true" ]; then
        safe_echo "  • registration_token_required: ${GREEN}true${NC} (требуется токен регистрации)"
    elif [ "$token_req" = "false" ]; then
        safe_echo "  • registration_token_required: ${RED}false${NC} (токен регистрации не требуется)"
    else
        safe_echo "  • registration_token_required: ${YELLOW}$token_req${NC}"
    fi
    
    echo
    safe_echo "${CYAN}👤 Настройки управления аккаунтами:${NC}"
    
    local email_change=$(sudo -u "$MAS_USER" yq eval '.account.email_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • email_change_allowed: ${BLUE}$email_change${NC}"
    
    local display_change=$(sudo -u "$MAS_USER" yq eval '.account.displayname_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • displayname_change_allowed: ${BLUE}$display_change${NC}"
    
    local password_change=$(sudo -u "$MAS_USER" yq eval '.account.password_change_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • password_change_allowed: ${BLUE}$password_change${NC}"
    
    local password_recovery=$(sudo -u "$MAS_USER" yq eval '.account.password_recovery_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • password_recovery_enabled: ${BLUE}$password_recovery${NC}"
    
    local account_deactivation=$(sudo -u "$MAS_USER" yq eval '.account.account_deactivation_allowed' "$MAS_CONFIG_FILE" 2>/dev/null)
    safe_echo "  • account_deactivation_allowed: ${BLUE}$account_deactivation${NC}"
    
    echo
    safe_echo "${CYAN}📄 Полная секция account (YAML):${NC}"
    echo "────────────────────────────────────────────────────────────"
    
    local account_yaml_output=$(sudo -u "$MAS_USER" yq eval '.account' "$MAS_CONFIG_FILE" 2>&1)
    if [ $? -eq 0 ]; then
        echo "$account_yaml_output"
    else
        safe_echo "${RED}Ошибка чтения секции account${NC}"
    fi
    
    echo "────────────────────────────────────────────────────────────"
    
    echo
    safe_echo "${YELLOW}📝 Примечание:${NC}"
    safe_echo "• Изменения этих параметров требуют перезапуска MAS"
    safe_echo "• Файл конфигурации: $MAS_CONFIG_FILE"
    safe_echo "• Для изменения используйте пункты меню выше"
    echo
    safe_echo "${BLUE}ℹ️  Дополнительная информация:${NC}"
    safe_echo "• Проверить статус MAS: systemctl status matrix-auth-service"
    safe_echo "• Логи MAS: journalctl -u matrix-auth-service -n 20"
}

# Получение статуса открытой регистрации MAS
get_mas_registration_status() {
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    
    # Быстрая проверка yq перед использованием
    if ! command -v yq >/dev/null 2>&1; then
        log "WARN" "yq не найден для чтения конфигурации"
        echo "unknown"
        return 1
    fi
    
    # Проверяем что это не snap версия
    local yq_path=$(which yq 2>/dev/null)
    if [[ "$yq_path" == *"/snap/"* ]]; then
        log "WARN" "Обнаружена snap версия yq, исправляем..."
        if ! check_and_fix_yq_installation; then
            echo "unknown"
            return 1
        fi
    fi
    
    local status=$(sudo -u "$MAS_USER" yq eval '.account.password_registration_enabled' "$MAS_CONFIG_FILE" 2>/dev/null)
    
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
    
    # Быстрая проверка yq перед использованием
    if ! command -v yq >/dev/null 2>&1; then
        log "WARN" "yq не найден для чтения конфигурации"
        echo "unknown"
        return 1
    fi
    
    # Проверяем что это не snap версия
    local yq_path=$(which yq 2>/dev/null)
    if [[ "$yq_path" == *"/snap/"* ]]; then
        log "WARN" "Обнаружена snap версия yq, исправляем..."
        if ! check_and_fix_yq_installation; then
            echo "unknown"
            return 1
        fi
    fi
    
    local status=$(sudo -u "$MAS_USER" yq eval '.account.registration_token_required' "$MAS_CONFIG_FILE" 2>/dev/null)
    
    if [ "$status" = "true" ]; then
        echo "enabled"
    elif [ "$status" = "false" ]; then
        echo "disabled"
    else
        echo "unknown"
    fi
}

# Создание токена регистрации
create_registration_token() {
    print_header "СОЗДАНИЕ ТОКЕНА РЕГИСТРАЦИИ" "$CYAN"
    
    safe_echo "${BOLD}Параметры токена регистрации:${NC}"
    safe_echo "• ${BLUE}Кастомный токен${NC} - используйте свою строку или оставьте пустым для автогенерации"
    safe_echo "• ${BLUE}Лимит использований${NC} - количество раз, которое можно использовать токен"
    safe_echo "• ${BLUE}Срок действия${NC} - время жизни токена в секундах"
    echo
    
    # Проверяем, что MAS запущен
    if ! systemctl is-active --quiet matrix-auth-service; then
        safe_echo "${RED}❌ Matrix Authentication Service не запущен!${NC}"
        safe_echo "${YELLOW}Для создания токенов MAS должен быть запущен.${NC}"
        return 1
    fi
    
    # Проверяем наличие команды mas-cli
    if ! command -v mas-cli >/dev/null 2>&1 && [ ! -f "/usr/local/bin/mas-cli" ]; then
        safe_echo "${RED}❌ Команда mas-cli не найдена!${NC}"
        safe_echo "${YELLOW}Проверьте установку Matrix Authentication Service${NC}"
        return 1
    fi
    
    # Определяем путь к mas-cli
    local mas_cli_path=""
    if command -v mas-cli >/dev/null 2>&1; then
        mas_cli_path="mas-cli"
    elif [ -f "/usr/local/bin/mas-cli" ]; then
        mas_cli_path="/usr/local/bin/mas-cli"
    else
        safe_echo "${RED}❌ Не удалось найти исполняемый файл mas-cli${NC}"
        return 1
    fi
    
    log "DEBUG" "Используется mas-cli по пути: $mas_cli_path"
    
    # Параметры токена
    read -p "Введите кастомный токен (или оставьте пустым для автогенерации): " custom_token
    read -p "Лимит использований (или оставьте пустым для неограниченного): " usage_limit
    read -p "Срок действия в секундах (или оставьте пустым для бессрочного): " expires_in
    
    # Формируем команду
    local cmd_array=("$mas_cli_path" "manage" "issue-user-registration-token" "--config" "$MAS_CONFIG_FILE")
    
    if [ -n "$custom_token" ]; then
        cmd_array+=("--token" "$custom_token")
    fi
    
    if [ -n "$usage_limit" ]; then
        if [[ ! "$usage_limit" =~ ^[0-9]+$ ]]; then
            safe_echo "${RED}❌ Ошибка: Лимит использований должен быть числом${NC}"
            return 1
        fi
        cmd_array+=("--usage-limit" "$usage_limit")
    fi
    
    if [ -n "$expires_in" ]; then
        if [[ ! "$expires_in" =~ ^[0-9]+$ ]]; then
            safe_echo "${RED}❌ Ошибка: Срок действия должен быть числом в секундах${NC}"
            return 1
        fi
        cmd_array+=("--expires-in" "$expires_in")
    fi
    
    log "INFO" "Создание токена регистрации..."
    log "DEBUG" "Команда: ${cmd_array[*]}"
    
    # ИСПРАВЛЕНИЕ: Выполняем команду напрямую без временного файла
    # Переходим в рабочую директорию MAS для выполнения команды
    local original_dir=$(pwd)
    cd /var/lib/mas 2>/dev/null || {
        log "WARN" "Не удалось перейти в /var/lib/mas, выполняем из текущей директории"
    }
    
    # Выполняем команду как пользователь MAS 
    local output=""
    local exit_code=0
    
    # Используем более простой подход без временных файлов
    log "DEBUG" "Выполнение команды от имени пользователя $MAS_USER..."
    if ! output=$(sudo -u "$MAS_USER" "${cmd_array[@]}" 2>&1); then
        exit_code=$?
        cd "$original_dir" 2>/dev/null
        
        safe_echo "${RED}❌ Ошибка создания токена регистрации (код: $exit_code)${NC}"
        safe_echo "${YELLOW}Вывод команды:${NC}"
        safe_echo "$output"
        echo
        
        # Анализ конкретных ошибок
        if [[ "$output" == *"Permission denied"* ]]; then
            safe_echo "${YELLOW}Возможные причины ошибки с правами доступа:${NC}"
            safe_echo "• Проблемы с правами пользователя $MAS_USER"
            safe_echo "• Неправильные права на рабочую директорию /var/lib/mas"
            safe_echo "• Проблемы с доступом к конфигурационному файлу"
            echo
            safe_echo "${CYAN}Попробуйте выполнить команду вручную:${NC}"
            safe_echo "sudo -u $MAS_USER $mas_cli_path manage issue-user-registration-token --config $MAS_CONFIG_FILE"
        elif [[ "$output" == *"database"* ]]; then
            safe_echo "${YELLOW}Проблема с базой данных:${NC}"
            safe_echo "• Проверьте подключение к базе данных MAS"
            safe_echo "• Убедитесь, что база данных mas_db существует"
            safe_echo "• Проверьте права пользователя synapse_user на базу данных"
        elif [[ "$output" == *"config"* ]]; then
            safe_echo "${YELLOW}Проблема с конфигурацией:${NC}"
            safe_echo "• Проверьте синтаксис файла $MAS_CONFIG_FILE"
            safe_echo "• Убедитесь, что файл доступен для чтения пользователем $MAS_USER"
        else
            safe_echo "${YELLOW}Общие причины ошибки:${NC}"
            safe_echo "• MAS служба может быть не полностью запущена"
            safe_echo "• Проблемы с базой данных MAS"
            safe_echo "• Недостаточные права пользователя $MAS_USER"
            safe_echo "• Неправильная конфигурация MAS"
        fi
        
        echo
        safe_echo "${CYAN}Диагностика:${NC}"
        safe_echo "• Проверьте логи: journalctl -u matrix-auth-service -n 20"
        safe_echo "• Проверьте конфигурацию: mas-cli config check --config $MAS_CONFIG_FILE"
        safe_echo "• Проверьте подключение к БД: mas-cli database migrate --config $MAS_CONFIG_FILE"
        safe_echo "• Проверьте права: ls -la $MAS_CONFIG_FILE /var/lib/mas"
        return 1
    fi
    
    # Возвращаемся в исходную директорию
    cd "$original_dir" 2>/dev/null || true
    
    echo
    safe_echo "${BOLD}${GREEN}✅ Токен регистрации успешно создан!${NC}"
    echo
    safe_echo "${BOLD}${CYAN}Созданный токен:${NC}"
    echo "────────────────────────────────────────────────────────────"
    safe_echo "${YELLOW}$output${NC}"
    echo "────────────────────────────────────────────────────────────"
    echo
    safe_echo "${BOLD}${RED}⚠️  ВАЖНО:${NC}"
    safe_echo "${YELLOW}• Сохраните этот токен - он больше не будет показан!${NC}"
    safe_echo "${YELLOW}• Передайте токен пользователю любым безопасным способом${NC}"
    echo
    safe_echo "${BOLD}${BLUE}Как использовать токен:${NC}"
    safe_echo "1. Пользователь переходит на страницу регистрации вашего Matrix сервера"
    safe_echo "2. Вводит токен в поле 'Registration Token' или 'Токен регистрации'"
    safe_echo "3. Заполняет остальные поля (имя пользователя, пароль, email)"
    safe_echo "4. Подтверждает регистрацию"
    
    return 0
}

# Показ информации о токенах
show_registration_tokens_info() {
    print_header "ИНФОРМАЦИЯ О ТОКЕНАХ РЕГИСТРАЦИИ" "$CYAN"
        
    safe_echo "${BOLD}Что такое токены регистрации?${NC}"
    safe_echo "Токены регистрации позволяют контролировать регистрацию пользователей."
    safe_echo "Когда включено требование токенов (registration_token_required: true),"
    safe_echo "пользователи должны предоставить действительный токен для регистрации."
    echo
    
    safe_echo "${BOLD}${GREEN}Как использовать токены:${NC}"
    safe_echo "1. ${BLUE}Создайте токен${NC} с помощью этого меню"
    safe_echo "2. ${BLUE}Передайте токен${NC} пользователю любым безопасным способом"
    safe_echo "3. ${BLUE}Пользователь вводит токен${NC} при регистрации на сервере"
    safe_echo "4. ${BLUE}После использования${NC} лимит токена уменьшается"
    echo
    
    safe_echo "${BOLD}${CYAN}Параметры токенов:${NC}"
    safe_echo "• ${YELLOW}Кастомный токен${NC} - задайте свою строку (например, 'invite2024') или автогенерация"
    safe_echo "• ${YELLOW}Лимит использований${NC} - сколько раз можно использовать (например, 5 для группы)"
    safe_echo "• ${YELLOW}Срок действия${NC} - время жизни токена в секундах"
    echo
    
    safe_echo "${BOLD}${BLUE}Примеры сроков действия:${NC}"
    safe_echo "• ${GREEN}3600${NC} = 1 час"
    safe_echo "• ${GREEN}86400${NC} = 1 день"
    safe_echo "• ${GREEN}604800${NC} = 1 неделя"
    safe_echo "• ${GREEN}2592000${NC} = 1 месяц"
    safe_echo "• ${GREEN}пусто${NC} = бессрочный токен"
    echo
    
    safe_echo "${BOLD}${MAGENTA}Примеры использования:${NC}"
    safe_echo "• ${CYAN}Частный сервер${NC}: создайте токены для друзей/семьи"
    safe_echo "• ${CYAN}Корпоративный сервер${NC}: токены для новых сотрудников"
    safe_echo "• ${CYAN}Временный доступ${NC}: токены с ограниченным сроком действия"
    safe_echo "• ${CYAN}Групповые приглашения${NC}: один токен для нескольких человек"
    echo
    
    safe_echo "${BOLD}${RED}Безопасность:${NC}"
    safe_echo "• ${YELLOW}Никогда не передавайте токены через незащищенные каналы${NC}"
    safe_echo "• ${YELLOW}Используйте токены с ограниченным сроком действия${NC}"
    safe_echo "• ${YELLOW}Отслеживайте использование токенов${NC}"
    safe_echo "• ${YELLOW}Удаляйте неиспользованные токены${NC}"
    
    local token_status=$(get_mas_token_registration_status)
    
    if [ "$token_status" = "enabled" ]; then
        echo
        safe_echo "${GREEN}ℹ️  Требование токенов регистрации сейчас: ВКЛЮЧЕНО${NC}"
    elif [ "$token_status" = "disabled" ]; then
        echo
        safe_echo "${RED}⚠️  Требование токенов регистрации сейчас: ОТКЛЮЧЕНО${NC}"
        safe_echo "${YELLOW}Для использования токенов включите регистрацию по токенам в меню управления.${NC}"
    fi
}

manage_mas_registration_tokens() {
    print_header "УПРАВЛЕНИЕ ТОКЕНАМИ РЕГИСТРАЦИИ MAS" "$BLUE"
    
    if ! check_yq_dependency; then
        log "ERROR" "Невозможно продолжить без yq"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi
    
    # Проверяем и создаем рабочую директорию MAS с правильными правами
    local mas_work_dir="/var/lib/mas"
    if [ ! -d "$mas_work_dir" ]; then
        log "INFO" "Создание рабочей директории MAS: $mas_work_dir"
        mkdir -p "$mas_work_dir"
        chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir"
        chmod 755 "$mas_work_dir"
    else
        # Проверяем права на существующую директорию
        local current_owner=$(stat -c "%U:%G" "$mas_work_dir" 2>/dev/null)
        if [ "$current_owner" != "$MAS_USER:$MAS_GROUP" ]; then
            log "INFO" "Исправление прав на рабочую директорию MAS"
            chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir"
            chmod 755 "$mas_work_dir"
        fi
    fi
    
    # Проверяем права доступа к конфигурационному файлу
    if [ -f "$MAS_CONFIG_FILE" ]; then
        if ! sudo -u "$MAS_USER" test -r "$MAS_CONFIG_FILE"; then
            log "WARN" "Пользователь $MAS_USER не может читать конфигурационный файл"
            log "INFO" "Исправление прав доступа к конфигурационному файлу"
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
            chmod 600 "$MAS_CONFIG_FILE"
        fi
    fi
    
    if ! systemctl is-active --quiet matrix-auth-service; then
        safe_echo "${RED}❌ Matrix Authentication Service не запущен!${NC}"
        safe_echo "${YELLOW}Для создания токенов MAS должен быть запущен.${NC}"
        
        if ask_confirmation "Попробовать запустить MAS?"; then
            if restart_output=$(restart_service "matrix-auth-service" 2>&1); then
                sleep 2
                if systemctl is_active --quiet matrix-auth-service; then
                    safe_echo "${GREEN}✅ MAS успешно запущен${NC}"
                else
                    safe_echo "${RED}❌ Не удалось запустить MAS${NC}"
                    safe_echo "${YELLOW}Проверьте логи: journalctl -u matrix-auth-service -n 20${NC}"
                    read -p "Нажмите Enter для возврата..."
                    return 1
                fi
            else
                safe_echo "${RED}❌ Ошибка запуска MAS${NC}"
                safe_echo "${YELLOW}$restart_output${NC}"
                read -p "Нажмите Enter для возврата..."
                return 1
            fi
        else
            read -p "Нажмите Enter для возврата..."
            return 1
        fi
    fi

    while true; do
        local token_status=$(get_mas_token_registration_status)
        
        safe_echo "Текущий статус:"
        case "$token_status" in
            "enabled") 
                safe_echo "• Токены регистрации: ${GREEN}ТРЕБУЮТСЯ${NC}"
                ;;
            "disabled") 
                safe_echo "• Токены регистрации: ${RED}НЕ ТРЕБУЮТСЯ${NC}"
                ;;
            *) 
                safe_echo "• Токены регистрации: ${YELLOW}НЕИЗВЕСТНО${NC}"
                ;;
        esac
        
        if systemctl is-active --quiet matrix-auth-service; then
            safe_echo "• MAS служба: ${GREEN}АКТИВНА${NC}"
        else
            safe_echo "• MAS служба: ${RED}НЕ АКТИВНА${NC}"
        fi
        
        # Показываем дополнительную диагностическую информацию
        safe_echo "• Рабочая директория: ${BLUE}$mas_work_dir${NC} $([ -d "$mas_work_dir" ] && echo "${GREEN}✓${NC}" || echo "${RED}✗${NC}")"
        safe_echo "• Конфигурация: ${BLUE}$MAS_CONFIG_FILE${NC} $([ -f "$MAS_CONFIG_FILE" ] && echo "${GREEN}✓${NC}" || echo "${RED}✗${NC}")"
        
        echo
        safe_echo "${BOLD}Управление токенами регистрации:${NC}"
        safe_echo "1. ${GREEN}✅ Включить требование токенов регистрации${NC}"
        safe_echo "2. ${RED}❌ Отключить требование токенов регистрации${NC}"
        safe_echo "3. ${GREEN}🎫 Создать новый токен регистрации${NC}"
        safe_echo "4. ${GREEN}ℹ️  Показать информацию о токенах${NC}"
        safe_echo "5. ${CYAN}🔧 Диагностика прав доступа${NC}"
        safe_echo "6. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-6]: " action

        case $action in
            1)
                set_mas_config_value "registration_token_required" "true"
                ;;
            2)
                set_mas_config_value "registration_token_required" "false"
                ;;
            3)
                create_registration_token
                ;;
            4)
                show_registration_tokens_info
                ;;
            5)
                diagnose_mas_permissions
                ;;
            6)
                return 0
                ;;
            *)
                safe_echo "${RED}❌ Некорректный ввод. Попробуйте ещё раз.${NC}"
                sleep 1
                ;;
        esac
        
        if [ $action -ne 6 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

manage_mas_registration() {
    print_header "УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ MAS" "$BLUE"
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        safe_echo "${RED}❌ Файл конфигурации MAS не найден: $MAS_CONFIG_FILE${NC}"
        safe_echo "${YELLOW}Убедитесь, что MAS установлен и настроен${NC}"
        read -p "Нажмите Enter для возврата..."
        return 1
    fi

    while true; do
        local current_status=$(get_mas_registration_status)
        local token_status=$(get_mas_token_registration_status)
        
        safe_echo "${BOLD}Текущий статус регистрации:${NC}"
        case "$current_status" in
            "enabled") 
                safe_echo "• Открытая регистрация: ${GREEN}ВКЛЮЧЕНА${NC}"
                ;;
            "disabled") 
                safe_echo "• Открытая регистрация: ${RED}ОТКЛЮЧЕНА${NC}"
                ;;
            *) 
                safe_echo "• Открытая регистрация: ${YELLOW}НЕИЗВЕСТНО${NC}"
                ;;
        esac
        
        case "$token_status" in
            "enabled") 
                safe_echo "• Регистрация по токенам: ${GREEN}ТРЕБУЕТСЯ${NC}"
                ;;
            "disabled") 
                safe_echo "• Регистрация по токенам: ${RED}НЕ ТРЕБУЕТСЯ${NC}"
                ;;
            *) 
                safe_echo "• Регистрация по токенам: ${YELLOW}НЕИЗВЕСТНО${NC}"
                ;;
        esac
        
        if systemctl is-active --quiet matrix-auth-service; then
            safe_echo "• MAS служба: ${GREEN}АКТИВНА${NC}"
        else
            safe_echo "• MAS служба: ${RED}НЕ АКТИВНА${NC}"
        fi
        
        if [ "$current_status" = "enabled" ] && [ "$token_status" = "disabled" ]; then
            echo
            safe_echo "${YELLOW}⚠️ Предупреждение:${NC} Открытая регистрация включена без требования токенов."
            safe_echo "${YELLOW}   Это означает, что любой может зарегистрироваться на вашем сервере.${NC}"
            safe_echo "${CYAN}   Рекомендуется включить требование токенов или отключить открытую регистрацию.${NC}"
        fi
        
        echo
        safe_echo "${BOLD}Управление регистрацией MAS:${NC}"
        safe_echo "1. ${GREEN}✅ Включить открытую регистрацию${NC}"
        safe_echo "2. ${RED}❌ Выключить открытую регистрацию${NC}"
        safe_echo "3. ${GREEN}🔐 Включить требование токенов регистрации${NC}"
        safe_echo "4. ${RED}🔓 Отключить требование токенов регистрации${NC}"
        safe_echo "5. ${GREEN}📄 Просмотреть конфигурацию account${NC}"
        safe_echo "6. ${GREEN}🎫 Управление токенами регистрации${NC}"
        safe_echo "7. ${WHITE}↩️  Назад${NC}"

        read -p "Выберите действие [1-7]: " action

        case $action in
            1)
                set_mas_config_value "password_registration_enabled" "true"
                ;;
            2)
                set_mas_config_value "password_registration_enabled" "false"
                ;;
            3)
                set_mas_config_value "registration_token_required" "true"
                ;;
            4)
                set_mas_config_value "registration_token_required" "false"
                ;;
            5)
                view_mas_account_config
                ;;
            6)
                manage_mas_registration_tokens
                ;;
            7)
                return 0
                ;;
            *)
                safe_echo "${RED}❌ Некорректный ввод. Попробуйте ещё раз.${NC}"
                sleep 1
                ;;
        esac
        
        if [ $action -ne 7 ]; then
            echo
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# Диагностика прав доступа MAS
diagnose_mas_permissions() {
    print_header "ДИАГНОСТИКА ПРАВ ДОСТУПА MAS" "$CYAN"
    
    safe_echo "${BOLD}Проверка компонентов MAS:${NC}"
    echo
    
    # 1. Проверка пользователя и группы
    safe_echo "${CYAN}1. Пользователь и группа MAS:${NC}"
    if id "$MAS_USER" >/dev/null 2>&1; then
        local user_info=$(id "$MAS_USER" 2>/dev/null)
        safe_echo "   • Пользователь $MAS_USER: ${GREEN}✓ существует${NC}"
        safe_echo "   • Информация: $user_info"
    else
        safe_echo "   • Пользователь $MAS_USER: ${RED}✗ не существует${NC}"
    fi
    echo
    
    # 2. Проверка рабочей директории
    safe_echo "${CYAN}2. Рабочая директория MAS:${NC}"
    local mas_work_dir="/var/lib/mas"
    if [ -d "$mas_work_dir" ]; then
        local dir_perms=$(stat -c "%a" "$mas_work_dir" 2>/dev/null)
        local dir_owner=$(stat -c "%U:%G" "$mas_work_dir" 2>/dev/null)
        safe_echo "   • Директория: ${GREEN}✓ $mas_work_dir${NC}"
        safe_echo "   • Владелец: $dir_owner $([ "$dir_owner" = "$MAS_USER:$MAS_GROUP" ] && echo "${GREEN}✓${NC}" || echo "${YELLOW}!${NC}")"
        safe_echo "   • Права: $dir_perms $([ "$dir_perms" = "755" ] && echo "${GREEN}✓${NC}" || echo "${YELLOW}!${NC}")"
        
        # Проверяем возможность записи
        if sudo -u "$MAS_USER" test -w "$mas_work_dir"; then
            safe_echo "   • Запись для $MAS_USER: ${GREEN}✓ разрешена${NC}"
        else
            safe_echo "   • Запись для $MAS_USER: ${RED}✗ запрещена${NC}"
        fi
    else
        safe_echo "   • Директория: ${RED}✗ $mas_work_dir не существует${NC}"
    fi
    echo
    
    # 3. Проверка конфигурационного файла
    safe_echo "${CYAN}3. Конфигурационный файл MAS:${NC}"
    if [ -f "$MAS_CONFIG_FILE" ]; then
        local file_perms=$(stat -c "%a" "$MAS_CONFIG_FILE" 2>/dev/null)
        local file_owner=$(stat -c "%U:%G" "$MAS_CONFIG_FILE" 2>/dev/null)
        safe_echo "   • Файл: ${GREEN}✓ $MAS_CONFIG_FILE${NC}"
        safe_echo "   • Владелец: $file_owner $([ "$file_owner" = "$MAS_USER:$MAS_GROUP" ] && echo "${GREEN}✓${NC}" || echo "${YELLOW}!${NC}")"
        safe_echo "   • Права: $file_perms $([ "$file_perms" = "600" ] && echo "${GREEN}✓${NC}" || echo "${YELLOW}!${NC}")"
        
        # Проверяем возможность чтения
        if sudo -u "$MAS_USER" test -r "$MAS_CONFIG_FILE"; then
            safe_echo "   • Чтение для $MAS_USER: ${GREEN}✓ разрешено${NC}"
        else
            safe_echo "   • Чтение для $MAS_USER: ${RED}✗ запрещено${NC}"
        fi
        
        # Проверка валидности YAML
        if command -v python3 >/dev/null 2>&1; then
            if python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
                safe_echo "   • YAML синтаксис: ${GREEN}✓ корректный${NC}"
            else
                safe_echo "   • YAML синтаксис: ${RED}✗ некорректный${NC}"
            fi
        fi
    else
        safe_echo "   • Файл: ${RED}✗ $MAS_CONFIG_FILE не существует${NC}"
    fi
    echo
    
    # 4. Проверка исполняемого файла mas-cli
    safe_echo "${CYAN}4. Исполняемый файл mas-cli:${NC}"
    if command -v mas-cli >/dev/null 2>&1; then
        local mas_cli_path=$(which mas-cli 2>/dev/null)
        safe_echo "   • Команда mas-cli: ${GREEN}✓ найдена${NC}"
        safe_echo "   • Путь: $mas_cli_path"
        
        # Проверяем версию
        local mas_version=$(mas-cli --version 2>/dev/null | head -1)
        safe_echo "   • Версия: $mas_version"
        
        # Проверяем возможность выполнения пользователем MAS
        if sudo -u "$MAS_USER" mas-cli --version >/dev/null 2>&1; then
            safe_echo "   • Выполнение от $MAS_USER: ${GREEN}✓ работает${NC}"
        else
            safe_echo "   • Выполнение от $MAS_USER: ${RED}✗ не работает${NC}"
        fi
    else
        safe_echo "   • Команда mas-cli: ${RED}✗ не найдена${NC}"
    fi
    echo
    
    # 5. Проверка службы systemd
    safe_echo "${CYAN}5. Служба matrix-auth-service:${NC}"
    if systemctl is-enabled --quiet matrix-auth-service 2>/dev/null; then
        safe_echo "   • Служба включена: ${GREEN}✓${NC}"
    else
        safe_echo "   • Служба включена: ${RED}✗${NC}"
    fi
    
    if systemctl is-active --quiet matrix-auth-service; then
        safe_echo "   • Служба активна: ${GREEN}✓${NC}"
        
        # Проверяем время запуска
        local start_time=$(systemctl show -p ActiveEnterTimestamp matrix-auth-service --value 2>/dev/null)
        safe_echo "   • Время запуска: $start_time"
    else
        safe_echo "   • Служба активна: ${RED}✗${NC}"
        
        # Показываем последние ошибки
        local service_status=$(systemctl status matrix-auth-service --no-pager -n 3 2>&1 | tail -3)
        safe_echo "   • Последний статус:"
        echo "$service_status" | while read -r line; do
            safe_echo "     $line"
        done
    fi
    echo
    
    # 6. Проверка тестовой команды
    safe_echo "${CYAN}6. Тестовая команда:${NC}"
    safe_echo "   Пробуем выполнить: mas-cli config check --config $MAS_CONFIG_FILE"
    
    if sudo -u "$MAS_USER" mas-cli config check --config "$MAS_CONFIG_FILE" >/dev/null 2>&1; then
        safe_echo "   • Результат: ${GREEN}✓ команда выполнена успешно${NC}"
    else
        local test_output=$(sudo -u "$MAS_USER" mas-cli config check --config "$MAS_CONFIG_FILE" 2>&1)
        safe_echo "   • Результат: ${RED}✗ ошибка выполнения${NC}"
        safe_echo "   • Вывод ошибки: $test_output"
    fi
    echo
    
    # Рекомендации по исправлению
    safe_echo "${BOLD}${YELLOW}🔧 Автоматическое исправление:${NC}"
    if ask_confirmation "Попробовать автоматически исправить обнаруженные проблемы?"; then
        echo
        safe_echo "${CYAN}Применение исправлений...${NC}"
        
        # Создаем рабочую директорию если нужно
        if [ ! -d "$mas_work_dir" ]; then
            safe_echo "• Создание рабочей директории..."
            mkdir -p "$mas_work_dir"
            chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir"
            chmod 755 "$mas_work_dir"
            safe_echo "  ${GREEN}✓ Директория создана${NC}"
        fi
        
        # Исправляем права на рабочую директорию
        safe_echo "• Исправление прав рабочей директории..."
        chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir" 2>/dev/null
        chmod 755 "$mas_work_dir" 2>/dev/null
        safe_echo "  ${GREEN}✓ Права исправлены${NC}"
        
        # Исправляем права на конфигурационный файл
        if [ -f "$MAS_CONFIG_FILE" ]; then
            safe_echo "• Исправление прав конфигурационного файла..."
            chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE" 2>/dev/null
            chmod 600 "$MAS_CONFIG_FILE" 2>/dev/null
            safe_echo "  ${GREEN}✓ Права исправлены${NC}"
        fi
        
        # Создаем .env файл если нужно
        local env_file="$mas_work_dir/.env"
        if [ ! -f "$env_file" ]; then
            safe_echo "• Создание .env файла..."
            cat > "$env_file" << 'EOF'
# MAS Environment Variables
# Created by matrix-setup automation

RUST_LOG=info
EOF
            chown "$MAS_USER:$MAS_GROUP" "$env_file"
            chmod 600 "$env_file"
            safe_echo "  ${GREEN}✓ .env файл создан${NC}"
        fi
        
        safe_echo "${GREEN}✅ Автоматическое исправление завершено${NC}"
        echo
        safe_echo "${CYAN}Попробуйте снова создать токен регистрации.${NC}"
    fi
}

# Главная функция модуля
main() {
    log "DEBUG" "Запуск главной функции модуля mas_manage_mas_registration.sh"
    
    # ПРИНУДИТЕЛЬНАЯ проверка и исправление установки yq в самом начале
    log "INFO" "Принудительная проверка корректности установки yq..."
    if ! check_and_fix_yq_installation; then
        log "ERROR" "Не удалось обеспечить корректную установку yq"
        safe_echo "${RED}❌ Критическая ошибка: не удалось установить корректную версию yq${NC}"
        safe_echo "${YELLOW}yq необходим для управления YAML конфигурацией MAS${NC}"
        safe_echo "${CYAN}Попробуйте выполнить вручную:${NC}"
        safe_echo "sudo snap remove yq"
        safe_echo "sudo curl -sSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq"
        safe_echo "sudo chmod +x /usr/local/bin/yq"
        return 1
    fi
    
    # Проверяем и создаем рабочую среду MAS
    log "INFO" "Проверка рабочей среды MAS..."
    if ! ensure_mas_environment; then
        log "ERROR" "Не удалось подготовить рабочую среду MAS"
        safe_echo "${RED}❌ Ошибка подготовки рабочей среды MAS${NC}"
        safe_echo "${YELLOW}Попробуйте запустить скрипт исправления:${NC}"
        safe_echo "${CYAN}sudo ./fix_mas_permissions.sh${NC}"
        return 1
    fi
    
    # Проверяем, что MAS установлен
    if ! command -v mas >/dev/null 2>&1 && [ ! -f "$MAS_CONFIG_FILE" ]; then
        print_header "MATRIX AUTHENTICATION SERVICE НЕ УСТАНОВЛЕН" "$RED"
        log "ERROR" "Matrix Authentication Service не установлен"
        log "INFO" "Установите MAS через главное меню"
        
        safe_echo "${RED}❌ Matrix Authentication Service не установлен!${NC}"
        safe_echo "${YELLOW}Установите MAS через главное меню:${NC}"
        safe_echo "${CYAN}  Дополнительные компоненты → Matrix Authentication Service (MAS)${NC}"
        return 1
    else
        log "DEBUG" "MAS установлен, запуск меню управления регистрацией"
        manage_mas_registration
    fi
}

# Проверка запуска скрипта напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
