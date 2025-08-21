#!/bin/bash

# Matrix Authentication Service (MAS) Setup Module
# Matrix Setup & Management Tool v3.0
# Модуль установки Matrix Authentication Service

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
MAS_CONFIG_DIR="/etc/mas"
MAS_CONFIG_FILE="$MAS_CONFIG_DIR/config.yaml"
SYNAPSE_MAS_CONFIG="/etc/matrix-synapse/conf.d/mas.yaml"
HOMESERVER_CONFIG="/etc/matrix-synapse/homeserver.yaml"

# Константы
MAS_USER="matrix-synapse"
MAS_GROUP="matrix-synapse"
MAS_PORT_HOSTING="8080"
MAS_PORT_PROXMOX="8082"
MAS_DB_NAME="mas_db"
MAS_SOURCE_DIR="/opt/matrix-authentication-service"
MAS_INSTALL_DIR="/usr/local/share/mas-cli"

# Проверка root прав
check_root

# Загружаем тип сервера при инициализации модуля
load_server_type

# Логируем информацию о среде
log "INFO" "Модуль Matrix Authentication Service загружен"
log "DEBUG" "Тип сервера: ${SERVER_TYPE:-неопределен}"
log "DEBUG" "Bind адрес: ${BIND_ADDRESS:-неопределен}"

# Функция определения порта MAS в зависимости от типа сервера
determine_mas_port() {
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            echo "$MAS_PORT_PROXMOX"
            ;;
        *)
            echo "$MAS_PORT_HOSTING"
            ;;
    esac
}

# Проверка доступности порта для MAS
check_mas_port() {
    local port="$1"
    local alternative_ports=()
    
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            alternative_ports=(8082 8083 8084 8085)
            ;;
        *)
            alternative_ports=(8080 8081 8082 8083)
            ;;
    esac
    
    log "INFO" "Проверка доступности порта $port для MAS..." >&2
    check_port "$port" >&2
    local port_status=$?
    
    if [ $port_status -eq 1 ]; then
        log "WARN" "Порт $port занят, поиск альтернативного..." >&2
        
        for alt_port in "${alternative_ports[@]}"; do
            check_port "$alt_port" >&2
            if [ $? -eq 0 ]; then
                log "SUCCESS" "Найден свободный порт: $alt_port" >&2
                echo "$alt_port"
                return 0
            fi
        done
        
        log "ERROR" "Не удалось найти свободный порт для MAS" >&2
        return 1
    elif [ $port_status -eq 0 ]; then
        # Убираем вывод log сообщения в stdout
        echo "$port"
        return 0
    else
        log "WARN" "Не удалось проверить порт (lsof не установлен), продолжаем с портом $port" >&2
        echo "$port"
        return 0
    fi
}

# Проверка зависимостей для сборки из исходников
check_mas_build_dependencies() {
    log "INFO" "Проверка зависимостей для сборки MAS из исходников..."
    
    local dependencies=("curl" "wget" "tar" "openssl" "systemctl" "git" "make")
    local missing_deps=()
    local special_deps=()
    
    # Проверяем обычные зависимости
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Проверяем Rust/Cargo
    if ! command -v cargo &>/dev/null; then
        special_deps+=("cargo")
    fi
    
    # Проверяем Node.js и npm
    if ! command -v node &>/dev/null; then
        special_deps+=("nodejs")
    else
        # Проверяем версию Node.js
        local node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$node_version" -lt 18 ]; then
            special_deps+=("nodejs>=18")
        fi
    fi
    
    if ! command -v npm &>/dev/null; then
        special_deps+=("npm")
    fi
    
    # Проверяем OPA
    if ! command -v opa &>/dev/null; then
        special_deps+=("opa")
    fi
    
    # Если есть отсутствующие зависимости
    if [ ${#missing_deps[@]} -gt 0 ] || [ ${#special_deps[@]} -gt 0 ]; then
        log "ERROR" "Отсутствуют зависимости для сборки:"
        [ ${#missing_deps[@]} -gt 0 ] && log "ERROR" "  Обычные пакеты: ${missing_deps[*]}"
        [ ${#special_deps[@]} -gt 0 ] && log "ERROR" "  Специальные пакеты: ${special_deps[*]}"
        
        log "INFO" "Установка недостающих пакетов..."
        
        if ! apt update; then
            log "ERROR" "Не удалось обновить список пакетов"
            return 1
        fi
        
        # Устанавливаем Rust toolchain если нужно
        if [[ " ${special_deps[@]} " =~ "cargo" ]]; then
            log "INFO" "Установка Rust toolchain..."
            if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
                log "ERROR" "Не удалось установить Rust"
                return 1
            fi
            # ВАЖНО: Обновляем PATH для текущей сессии
            export PATH="$HOME/.cargo/bin:$PATH"
            source "$HOME/.cargo/env" 2>/dev/null || true
        fi
        
        # Устанавливаем Node.js если нужно
        if [[ " ${special_deps[@]} " =~ "nodejs" ]] || [[ " ${special_deps[@]} " =~ "nodejs>=18" ]] || [[ " ${special_deps[@]} " =~ "npm" ]]; then
            log "INFO" "Установка Node.js 18+ и npm..."
            if ! curl -fsSL https://deb.nodesource.com/setup_18.x | bash -; then
                log "ERROR" "Не удалось добавить репозиторий Node.js"
                return 1
            fi
            if ! apt install -y nodejs; then
                log "ERROR" "Не удалось установить Node.js"
                return 1
            fi
        fi
        
        # Устанавливаем OPA если нужно
        if [[ " ${special_deps[@]} " =~ "opa" ]]; then
            log "INFO" "Установка Open Policy Agent..."
            if ! curl -L -o /usr/local/bin/opa https://openpolicyagent.org/downloads/v0.58.0/opa_linux_amd64_static; then
                log "ERROR" "Не удалось скачать OPA"
                return 1
            fi
            chmod +x /usr/local/bin/opa
        fi
        
        # Устанавливаем обычные зависимости через apt
        if [ ${#missing_deps[@]} -gt 0 ]; then
            log "INFO" "Установка обычных зависимостей: ${missing_deps[*]}"
            if ! apt install -y "${missing_deps[@]}"; then
                log "ERROR" "Не удалось установить зависимости: ${missing_deps[*]}"
                return 1
            fi
        fi
        
        # Проверяем, что все установилось корректно
        log "INFO" "Проверка установленных зависимостей..."
        
        # Проверяем Rust/Cargo
        if [[ " ${special_deps[@]} " =~ "cargo" ]]; then
            if command -v cargo &>/dev/null; then
                local cargo_version=$(cargo --version | head -1)
                log "SUCCESS" "✅ Rust/Cargo установлен: $cargo_version"
            else
                log "ERROR" "❌ Rust/Cargo не установлен корректно"
                return 1
            fi
        fi
        
        # Проверяем Node.js
        if [[ " ${special_deps[@]} " =~ "nodejs" ]] || [[ " ${special_deps[@]} " =~ "nodejs>=18" ]]; then
            if command -v node &>/dev/null; then
                local node_version=$(node --version)
                log "SUCCESS" "✅ Node.js установлен: $node_version"
            else
                log "ERROR" "❌ Node.js не установлен корректно"
                return 1
            fi
        fi
        
        # Проверяем npm
        if [[ " ${special_deps[@]} " =~ "npm" ]]; then
            if command -v npm &>/dev/null; then
                local npm_version=$(npm --version)
                log "SUCCESS" "✅ npm установлен: v$npm_version"
            else
                log "ERROR" "❌ npm не установлен корректно"
                return 1
            fi
        fi
        
        # Проверяем OPA
        if [[ " ${special_deps[@]} " =~ "opa" ]]; then
            if command -v opa &>/dev/null; then
                local opa_version=$(opa version | head -1)
                log "SUCCESS" "✅ OPA установлен: $opa_version"
            else
                log "ERROR" "❌ OPA не установлен корректно"
                return 1
            fi
        fi
        
        log "SUCCESS" "Все зависимости для сборки установлены"
    else
        log "SUCCESS" "Все зависимости для сборки уже установлены"
    fi
    
    return 0
}

# Клонирование и сборка MAS из исходников
build_mas_from_source() {
    log "INFO" "Клонирование и сборка Matrix Authentication Service из исходников..."
    
    # ВАЖНО: Убеждаемся, что Rust и Node.js доступны в PATH
    export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"
    
    # Проверяем доступность необходимых команд
    if ! command -v cargo &>/dev/null; then
        log "ERROR" "Cargo не найден в PATH после установки"
        log "DEBUG" "PATH: $PATH"
        return 1
    fi
    
    if ! command -v node &>/dev/null; then
        log "ERROR" "Node.js не найден в PATH после установки"
        return 1
    fi
    
    if ! command -v npm &>/dev/null; then
        log "ERROR" "npm не найден в PATH после установки"
        return 1
    fi
    
    # Показываем версии для диагностики
    log "INFO" "Версии инструментов сборки:"
    log "INFO" "  Rust: $(rustc --version 2>/dev/null || echo 'не установлен')"
    log "INFO" "  Cargo: $(cargo --version 2>/dev/null || echo 'не установлен')"
    log "INFO" "  Node.js: $(node --version 2>/dev/null || echo 'не установлен')"
    log "INFO" "  npm: v$(npm --version 2>/dev/null || echo 'не установлен')"
    log "INFO" "  OPA: $(opa version 2>/dev/null | head -1 || echo 'не установлен')"
    
    # Создаем директорию для исходников
    mkdir -p "$MAS_SOURCE_DIR"
    
    # Клонируем репозиторий
    if [ -d "$MAS_SOURCE_DIR/.git" ]; then
        log "INFO" "Обновление существующего репозитория MAS..."
        cd "$MAS_SOURCE_DIR"
        if ! git pull origin main; then
            log "ERROR" "Не удалось обновить репозиторий"
            return 1
        fi
    else
        log "INFO" "Клонирование репозитория MAS..."
        if ! git clone https://github.com/element-hq/matrix-authentication-service.git "$MAS_SOURCE_DIR"; then
            log "ERROR" "Не удалось клонировать репозиторий"
            return 1
        fi
        cd "$MAS_SOURCE_DIR"
    fi
    
    # Переключаемся на последний стабильный тег или main
    local latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "main")
    log "INFO" "Использование версии: $latest_tag"
    if [ "$latest_tag" != "main" ]; then
        if ! git checkout "$latest_tag"; then
            log "WARN" "Не удалось переключиться на тег $latest_tag, используем main"
            git checkout main
        fi
    fi
    
    # Собираем фронтенд
    log "INFO" "Сборка фронтенда..."
    cd frontend
    
    # Очищаем npm кэш если нужно
    if [ -d "node_modules" ]; then
        log "INFO" "Очистка предыдущей установки npm..."
        rm -rf node_modules package-lock.json
    fi
    
    log "INFO" "Установка зависимостей фронтенда..."
    if ! npm ci; then
        log "WARN" "npm ci не удалась, пробуем npm install..."
        if ! npm install; then
            log "ERROR" "Ошибка установки зависимостей фронтенда"
            return 1
        fi
    fi
    
    log "INFO" "Сборка фронтенда..."
    if ! npm run build; then
        log "ERROR" "Ошибка сборки фронтенда"
        log "INFO" "Проверка доступных npm scripts..."
        npm run 2>/dev/null | grep -E "^  [a-zA-Z]" || true
        return 1
    fi
    cd ..
    
    # Проверяем, что фронтенд собран
    if [ ! -d "frontend/dist" ]; then
        log "ERROR" "Фронтенд не собран, директория frontend/dist отсутствует"
        return 1
    fi
    
    # Собираем политики OPA
    log "INFO" "Сборка политик OPA..."
    cd policies
    
    if command -v opa >/dev/null 2>&1; then
        log "INFO" "Использование локально установленного OPA..."
        if ! make; then
            log "ERROR" "Ошибка сборки политик OPA"
            return 1
        fi
    else
        log "WARN" "OPA не установлен, попытка сборки через Docker..."
        if command -v docker >/dev/null 2>&1; then
            if ! make DOCKER=1; then
                log "ERROR" "Ошибка сборки политик OPA через Docker"
                return 1
            fi
        else
            log "ERROR" "Ни OPA, ни Docker не доступны для сборки политик"
            return 1
        fi
    fi
    cd ..
    
    # Проверяем, что политики собраны
    if [ ! -f "policies/policy.wasm" ]; then
        log "ERROR" "Политики OPA не собраны, файл policies/policy.wasm отсутствует"
        return 1
    fi
    
    # Компилируем CLI
    log "INFO" "Компиляция MAS CLI..."
    
    # Убеждаемся, что Rust доступен
    source "$HOME/.cargo/env" 2>/dev/null || true
    
    if ! cargo build --release; then
        log "ERROR" "Ошибка компиляции MAS"
        log "INFO" "Проверка Cargo и Rust..."
        cargo --version 2>/dev/null || log "ERROR" "Cargo недоступен"
        rustc --version 2>/dev/null || log "ERROR" "Rust compiler недоступен"
        return 1
    fi
    
    # Проверяем, что бинарник создан
    if [ ! -f "./target/release/mas-cli" ]; then
        log "ERROR" "Бинарник mas-cli не создан"
        return 1
    fi
    
    # Создаем директорию для установки
    mkdir -p "$MAS_INSTALL_DIR"
    
    # Копируем бинарник
    log "INFO" "Установка бинарника mas-cli..."
    cp ./target/release/mas-cli /usr/local/bin/mas-cli
    chmod +x /usr/local/bin/mas-cli
    
    # Создаем симлинк для обратной совместимости
    ln -sf /usr/local/bin/mas-cli /usr/local/bin/mas
    
    # Копируем все необходимые файлы
    log "INFO" "Копирование файлов MAS..."
    
    # Frontend assets
    mkdir -p "$MAS_INSTALL_DIR/assets"
    cp -r frontend/dist/* "$MAS_INSTALL_DIR/assets/"
    
    # Manifest
    cp frontend/dist/manifest.json "$MAS_INSTALL_DIR/"
    
    # Policy
    cp policies/policy.wasm "$MAS_INSTALL_DIR/"
    
    # Templates (если есть в репозитории)
    if [ -d "templates" ]; then
        cp -r templates "$MAS_INSTALL_DIR/"
    else
        mkdir -p "$MAS_INSTALL_DIR/templates"
        log "WARN" "Директория templates не найдена в репозитории, создана пустая"
    fi
    
    # Translations (если есть в репозитории)
    if [ -d "translations" ]; then
        cp -r translations "$MAS_INSTALL_DIR/"
    else
        mkdir -p "$MAS_INSTALL_DIR/translations"
        log "WARN" "Директория translations не найдена в репозитории, создана пустая"
    fi
    
    # Устанавливаем правильные права
    chown -R root:root "$MAS_INSTALL_DIR"
    find "$MAS_INSTALL_DIR" -type f -exec chmod 644 {} \;
    find "$MAS_INSTALL_DIR" -type d -exec chmod 755 {} \;
    
    # Проверяем установку
    if /usr/local/bin/mas-cli --version >/dev/null 2>&1; then
        local mas_version=$(/usr/local/bin/mas-cli --version | head -1)
        log "SUCCESS" "Matrix Authentication Service собран из исходников: $mas_version"
        
        # Проверяем наличие всех критических файлов
        local critical_files=(
            "$MAS_INSTALL_DIR/policy.wasm"
            "$MAS_INSTALL_DIR/manifest.json"
            "$MAS_INSTALL_DIR/assets"
        )
        
        for file in "${critical_files[@]}"; do
            if [ -e "$file" ]; then
                log "SUCCESS" "✅ Файл найден: $file"
            else
                log "ERROR" "❌ Критический файл отсутствует: $file"
                return 1
            fi
        done
        
    else
        log "ERROR" "Ошибка установки MAS из исходников"
        log "INFO" "Проверка бинарника..."
        ls -la /usr/local/bin/mas-cli 2>/dev/null || log "ERROR" "Бинарник не найден"
        return 1
    fi
    
    return 0
}

# Функция для создания правильной конфигурации MAS (исправленная версия)
setup_mas_database() {
    log "INFO" "Настройка базы данных для MAS..."
    
    # Проверяем, что PostgreSQL запущен
    if ! systemctl is-active --quiet postgresql; then
        log "ERROR" "PostgreSQL не запущен"
        return 1
    fi
    
    # Получаем пароль пользователя synapse_user из основной установки Matrix
    local db_password=""
    if [ -f "$CONFIG_DIR/database.conf" ]; then
        db_password=$(grep "DB_PASSWORD=" "$CONFIG_DIR/database.conf" | cut -d'=' -f2 | tr -d '"')
    fi
    
    if [ -z "$db_password" ]; then
        log "ERROR" "Не найден пароль базы данных в $CONFIG_DIR/database.conf"
        log "INFO" "Убедитесь, что основная установка Matrix завершена успешно"
        return 1
    fi
    
    # Проверяем, существует ли пользователь synapse_user (создается в core_install.sh)
    local synapse_user_exists=$(sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='synapse_user'" | grep -c 1)
    
    if [ "$synapse_user_exists" -eq 0 ]; then
        log "ERROR" "Пользователь базы данных 'synapse_user' не существует"
        log "INFO" "Необходимо сначала запустить основную установку Matrix (core_install.sh)"
        log "INFO" "Этот пользователь создается автоматически в процессе основной установки"
        return 1
    fi
    
    log "SUCCESS" "Пользователь базы данных 'synapse_user' найден"
    
    # Проверяем, существует ли база данных mas_db
    local mas_db_exists=$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -w "$MAS_DB_NAME" | wc -l)
    
    if [ "$mas_db_exists" -eq 0 ]; then
        log "INFO" "Создание базы данных $MAS_DB_NAME..."
        
        # Создаем базу данных для MAS с владельцем synapse_user (используем того же пользователя, что и для Synapse)
        if ! sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse_user "$MAS_DB_NAME"; then
            log "ERROR" "Не удалось создать базу данных $MAS_DB_NAME"
            return 1
        fi
        
        log "SUCCESS" "База данных $MAS_DB_NAME создана"
    else
        log "INFO" "База данных $MAS_DB_NAME уже существует"
    fi
    
    # Проверяем подключение к базе данных MAS с пользователем synapse_user
    log "INFO" "Проверка подключения к базе данных MAS..."
    if PGPASSWORD="$db_password" psql -h localhost -U "synapse_user" -d "$MAS_DB_NAME" -c "SELECT 1;" &>/dev/null; then
        log "SUCCESS" "Подключение к базе данных MAS работает"
    else
        log "ERROR" "Не удается подключиться к базе данных MAS"
        log "INFO" "Проверка и предоставление необходимых прав..."
        
        # Даем полные права пользователю synapse_user на базу данных mas_db
        if sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $MAS_DB_NAME TO synapse_user;" 2>/dev/null; then
            log "INFO" "Права на базу данных $MAS_DB_NAME предоставлены пользователю synapse_user"
        fi
        
        # Даем права на схему public если база уже существует  
        if sudo -u postgres psql -d "$MAS_DB_NAME" -c "GRANT ALL ON SCHEMA public TO synapse_user;" 2>/dev/null; then
            log "INFO" "Права на схему public предоставлены"
        fi
        
        # Повторная проверка подключения
        if PGPASSWORD="$db_password" psql -h localhost -U "synapse_user" -d "$MAS_DB_NAME" -c "SELECT 1;" &>/dev/null; then
            log "SUCCESS" "Подключение к базе данных MAS теперь работает"
        else
            log "ERROR" "Подключение к базе данных MAS все еще не работает"
            return 1
        fi
    fi
    
    # Сохраняем информацию о базе данных MAS (используем того же пользователя synapse_user)
    {
        echo "MAS_DB_NAME=\"$MAS_DB_NAME\""
        echo "MAS_DB_USER=\"synapse_user\""
        echo "MAS_DB_PASSWORD=\"$db_password\""
        echo "MAS_DB_URI=\"postgresql://synapse_user:$db_password@localhost/$MAS_DB_NAME\""
    } > "$CONFIG_DIR/mas_database.conf"
    
    log "SUCCESS" "Конфигурация базы данных MAS сохранена (пользователь: synapse_user, база: $MAS_DB_NAME)"
    return 0
}

# Генерация конфигурации MAS (ИСПРАВЛЕННАЯ ВЕРСИЯ С ПРАВИЛЬНЫМИ ПУТЯМИ)
generate_mas_config() {
    local mas_port="$1"
    local matrix_domain="$2"
    local mas_secret="$3"
    local db_uri="$4"
    
    log "INFO" "Генерация конфигурации MAS..."
    
    # Создаем системного пользователя для MAS если нужно
    if ! create_mas_user; then
        return 1
    fi
    
    # Создаем директории
    mkdir -p "$MAS_CONFIG_DIR"
    mkdir -p /var/lib/mas
    
    # Определяем публичную базу и issuer в зависимости от типа сервера
    local mas_public_base
    local mas_issuer
    
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            mas_public_base="https://$matrix_domain"
            mas_issuer="https://$matrix_domain"
            log "INFO" "Домашний сервер: MAS будет доступен через reverse proxy"
            ;;
        *)
            mas_public_base="https://auth.$matrix_domain"
            mas_issuer="https://auth.$matrix_domain"
            log "INFO" "Облачный хостинг: MAS получит отдельный поддомен"
            ;;
    esac
    
    # КРИТИЧЕСКАЯ ПРОВЕРКА: убеждаемся, что URI содержит правильное имя базы данных
    local expected_db="mas_db"
    local config_db=$(echo "$db_uri" | sed 's|.*@localhost/||' | sed 's|?.*||')
    
    if [ "$config_db" != "$expected_db" ]; then
        log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: URI содержит неправильное имя базы данных: '$config_db' (ожидается: '$expected_db')"
        log "ERROR" "URI: $(echo "$db_uri" | sed 's/:[^:]*@/:***@/')"  # Скрываем пароль
        return 1
    fi
    
    log "SUCCESS" "URI содержит правильное имя базы данных: $config_db"
    
    # ВАЖНО: Проверяем, что все необходимые файлы установлены
    local policy_path="$MAS_INSTALL_DIR/policy.wasm"
    local assets_path="$MAS_INSTALL_DIR/assets"
    local templates_path="$MAS_INSTALL_DIR/templates"
    local translations_path="$MAS_INSTALL_DIR/translations"
    local manifest_path="$MAS_INSTALL_DIR/manifest.json"
    
    log "INFO" "Проверка наличия файлов MAS..."
    if [ ! -f "$policy_path" ]; then
        log "ERROR" "❌ Файл политики не найден: $policy_path"
        log "ERROR" "Это означает, что сборка MAS неполная"
        log "ERROR" "Содержимое $MAS_INSTALL_DIR:"
        ls -la "$MAS_INSTALL_DIR/" 2>/dev/null || log "ERROR" "Директория $MAS_INSTALL_DIR не существует"
        return 1
    else
        log "SUCCESS" "✅ Файл политики найден: $policy_path"
    fi
    
    # Проверяем остальные файлы
    [ -d "$assets_path" ] && log "SUCCESS" "✅ Assets найдены: $assets_path" || log "WARN" "⚠️  Assets отсутствуют: $assets_path"
    [ -d "$templates_path" ] && log "SUCCESS" "✅ Templates найдены: $templates_path" || log "WARN" "⚠️  Templates отсутствуют: $templates_path"
    [ -d "$translations_path" ] && log "SUCCESS" "✅ Translations найдены: $translations_path" || log "WARN" "⚠️  Translations отсутствуют: $translations_path"
    [ -f "$manifest_path" ] && log "SUCCESS" "✅ Manifest найден: $manifest_path" || log "WARN" "⚠️  Manifest отсутствует: $manifest_path"
    
    # Создаем ИСПРАВЛЕННУЮ конфигурацию с правильными секретами И ПРАВИЛЬНЫМИ ПУТЯМИ
    log "INFO" "Создание конфигурации MAS с правильными секретами И ПРАВИЛЬНЫМИ ПУТЯМИ..."

    # Пытаемся сгенерировать конфигурацию с помощью mas config generate для получения правильных секретов
    log "INFO" "Генерация базовой конфигурации с помощью mas config generate..."

    local temp_config="/tmp/mas_generated_config_$$"
    local base_config_generated=false

    if mas config generate > "$temp_config" 2>/dev/null; then
        base_config_generated=true
        log "SUCCESS" "Базовая конфигурация сгенерирована командой 'mas config generate'"
        
        # Извлекаем правильные секреты из сгенерированной конфигурации
        local secrets_start=$(grep -n "^secrets:" "$temp_config" | cut -d: -f1)
        
        if [ -n "$secrets_start" ]; then
            log "INFO" "Создание конфигурации с использованием правильно сгенерированных секретов"
            
            # Найдем конец секции secrets (следующая секция верхнего уровня)
            local secrets_end=$(tail -n +$((secrets_start + 1)) "$temp_config" | grep -n "^[a-zA-Z]" | head -1 | cut -d: -f1)
            if [ -n "$secrets_end" ]; then
                secrets_end=$((secrets_start + secrets_end - 1))
            else
                secrets_end=$(wc -l < "$temp_config")
            fi
            
            # Создаем нашу конфигурацию с правильными секретами И ПРАВИЛЬНЫМИ ПУТЯМИ
            cat > "$MAS_CONFIG_FILE" <<EOF
# Matrix Authentication Service Configuration - ИСПРАВЛЕНО С ПРАВИЛЬНЫМИ ПУТЯМИ
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Type: ${SERVER_TYPE:-hosting}
# Port: $mas_port
# Database: $expected_db

http:
  public_base: "$mas_public_base"
  issuer: "$mas_issuer"
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
          path: "$assets_path"
      binds:
        - address: "$BIND_ADDRESS:$mas_port"
      proxy_protocol: false

database:
  uri: "$db_uri"

matrix:
  homeserver: "$matrix_domain"
  secret: "$mas_secret"
  endpoint: "http://localhost:8008"

# КРИТИЧЕСКИ ВАЖНО: Правильная конфигурация политики OPA с путем к файлу
policy:
  # Указываем правильный путь к файлу policy.wasm
  wasm_module: "$policy_path"
  
  # Данные для политики - базовые правила регистрации и управления
  data:
    registration:
      # Базовые настройки регистрации
      enabled: true
      require_registration_token: false
      
      # Заблокированные имена пользователей (базовый набор)
      banned_usernames:
        literals: ["admin", "root", "administrator", "system", "support", "help", "info"]
        substrings: ["admin", "root"]
        prefixes: ["admin-", "root-", "system-"]
        suffixes: ["-admin", "-root"]
        regexes: ["^admin.*", "^root.*", ".*admin$"]

# ВАЖНО: Настройка templates с правильными путями
templates:
  path: "$templates_path"
  assets_manifest: "$manifest_path"
  translations_path: "$translations_path"

EOF

            # Добавляем секцию secrets из сгенерированной конфигурации
            sed -n "${secrets_start},${secrets_end}p" "$temp_config" >> "$MAS_CONFIG_FILE"
            
            # Добавляем остальные секции
            cat >> "$MAS_CONFIG_FILE" <<EOF

clients:
  - client_id: "0000000000000000000SYNAPSE"
    client_auth_method: client_secret_basic
    client_secret: "$mas_secret"

passwords:
  enabled: true
  schemes:
    - version: 1
      algorithm: bcrypt
      unicode_normalization: true
    - version: 2
      algorithm: argon2id

account:
  email_change_allowed: true
  displayname_change_allowed: true
  password_registration_enabled: false
  password_change_allowed: true
  password_recovery_enabled: false
  account_deactivation_allowed: true
  registration_token_required: false

experimental:
  access_token_ttl: 300
  compat_token_ttl: 300
EOF

        else
            log "WARN" "Не удалось найти секцию secrets в сгенерированной конфигурации, создаем вручную"
            base_config_generated=false
        fi
        
        rm -f "$temp_config"
    else
        log "WARN" "Не удалось использовать 'mas config generate', создаем конфигурацию вручную"
        base_config_generated=false
    fi
    
    # Если автоматическая генерация не удалась, создаем конфигурацию вручную с правильными путями
    if [ "$base_config_generated" = false ]; then
        log "INFO" "Создание конфигурации MAS вручную с правильными путями..."
        
        # Генерируем правильные секреты вручную
        local encryption_secret=$(openssl rand -hex 32)
        local rsa_key_kid=$(date +%s | sha256sum | cut -c1-8)
        
        cat > "$MAS_CONFIG_FILE" <<EOF
# Matrix Authentication Service Configuration - ИСПРАВЛЕНО С ПРАВИЛЬНЫМИ ПУТЯМИ
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Type: ${SERVER_TYPE:-hosting}
# Port: $mas_port
# Database: $expected_db

http:
  public_base: "$mas_public_base"
  issuer: "$mas_issuer"
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
          path: "$assets_path"
      binds:
        - address: "$BIND_ADDRESS:$mas_port"
      proxy_protocol: false

database:
  uri: "$db_uri"

matrix:
  homeserver: "$matrix_domain"
  secret: "$mas_secret"
  endpoint: "http://localhost:8008"

# КРИТИЧЕСКИ ВАЖНО: Правильная конфигурация политики OPA с путем к файлу
policy:
  # Указываем правильный путь к файлу policy.wasm
  wasm_module: "$policy_path"
  
  # Данные для политики - базовые правила регистрации и управления
  data:
    registration:
      # Базовые настройки регистрации
      enabled: true
      require_registration_token: false
      
      # Заблокированные имена пользователей (базовый набор)
      banned_usernames:
        literals: ["admin", "root", "administrator", "system", "support", "help", "info"]
        substrings: ["admin", "root"]
        prefixes: ["admin-", "root-", "system-"]
        suffixes: ["-admin", "-root"]
        regexes: ["^admin.*", "^root.*", ".*admin$"]

# ВАЖНО: Настройка templates с правильными путями
templates:
  path: "$templates_path"
  assets_manifest: "$manifest_path"
  translations_path: "$translations_path"

secrets:
  encryption: "$encryption_secret"
  keys:
    - kid: "$rsa_key_kid"
      key: |
$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 | sed 's/^/        /')

clients:
  - client_id: "0000000000000000000SYNAPSE"
    client_auth_method: client_secret_basic
    client_secret: "$mas_secret"

passwords:
  enabled: true
  schemes:
    - version: 1
      algorithm: bcrypt
      unicode_normalization: true
    - version: 2
      algorithm: argon2id

account:
  email_change_allowed: true
  displayname_change_allowed: true
  password_registration_enabled: false
  password_change_allowed: true
  password_recovery_enabled: false
  account_deactivation_allowed: true
  registration_token_required: false

experimental:
  access_token_ttl: 300
  compat_token_ttl: 300
EOF
    fi
    
    # Устанавливаем права доступа
    chown -R "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_DIR"
    chown -R "$MAS_USER:$MAS_GROUP" /var/lib/mas
    chmod 600 "$MAS_CONFIG_FILE"
    
    # КРИТИЧЕСКАЯ ПРОВЕРКА: убеждаемся, что конфигурация создана правильно
    if ! grep -q "^database:" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS повреждена: секция database отсутствует!"
        return 1
    fi
    
    if ! grep -q "$db_uri" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS повреждена: не содержит корректный URI базы данных!"
        return 1
    fi
    
    if ! grep -q "^secrets:" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS повреждена: секция secrets отсутствует!"
        return 1
    fi
    
    # НОВАЯ ПРОВЕРКА: убеждаемся, что секция policy добавлена с правильным путем
    if ! grep -q "^policy:" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS повреждена: секция policy отсутствует!"
        return 1
    fi
    
    # ВАЖНАЯ ПРОВЕРКА: убеждаемся, что wasm_module указывает на правильный файл
    if ! grep -q "wasm_module: \"$policy_path\"" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS не содержит правильный путь к policy.wasm!"
        log "ERROR" "Ожидаемый путь: $policy_path"
        return 1
    else
        log "SUCCESS" "✅ Конфигурация MAS содержит правильный путь к policy.wasm"
    fi
    
    # ВАЖНАЯ ПРОВЕРКА: убеждаемся, что templates правильно настроены
    if ! grep -q "^templates:" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Конфигурация MAS не содержит секцию templates!"
        return 1
    else
        log "SUCCESS" "✅ Конфигурация MAS содержит секцию templates"
    fi
    
    # Проверяем YAML синтаксис если доступен python
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import yaml; yaml.safe_load(open('$MAS_CONFIG_FILE'))" 2>/dev/null; then
            log "SUCCESS" "YAML синтаксис конфигурации корректен"
        else
            log "ERROR" "Ошибка в YAML синтаксиса конфигурации!"
            log "INFO" "Проверьте конфигурацию: $MAS_CONFIG_FILE"
            return 1
        fi
    fi
    
    # Проверяем конфигурацию с помощью MAS если возможно
    if command -v mas >/dev/null 2>&1; then
        log "INFO" "Проверка конфигурации с помощью mas config check..."
        if mas config check --config "$MAS_CONFIG_FILE" 2>/dev/null; then
            log "SUCCESS" "Конфигурация MAS прошла проверку"
        else
            log "WARN" "Конфигурация MAS имеет предупреждения (но это нормально для первого запуска)"
        fi
    fi
    
    # Финальная проверка: убеждаемся, что в конфигурации указана правильная база данных
    local final_config_db=$(grep -A 1 "^database:" "$MAS_CONFIG_FILE" | grep "uri:" | sed 's/.*@localhost\///' | sed 's/".*$//' 2>/dev/null)
    if [ "$final_config_db" = "$expected_db" ]; then
        log "SUCCESS" "✅ Конфигурация MAS создана успешно с правильной базой данных: $final_config_db"
        log "INFO" "Конфигурация содержит:"
        log "INFO" "  - Порт: $mas_port"
        log "INFO" "  - Домен: $matrix_domain" 
        log "INFO" "  - База данных: $final_config_db"
        log "INFO" "  - Bind адрес: $BIND_ADDRESS:$mas_port"
        log "INFO" "  - Policy файл: $policy_path"
        log "INFO" "  - Assets: $assets_path"
        log "INFO" "  - Templates: $templates_path"
        log "INFO" "  - Translations: $translations_path"
        log "INFO" "  - Manifest: $manifest_path"
    else
        log "ERROR" "КРИТИЧЕСКАЯ ОШИБКА: Финальная проверка не прошла!"
        log "ERROR" "Ожидается база данных: $expected_db"
        log "ERROR" "Найдена база данных: $final_config_db"
        log "DEBUG" "Содержимое секции database:"
        grep -A 2 "^database:" "$MAS_CONFIG_FILE" 2>/dev/null || log "ERROR" "Секция database не найдена"
        return 1
    fi
    
    return 0
}

# Создание пользователя для MAS если не существует
create_mas_user() {
    log "INFO" "Проверка системного пользователя для MAS..."
    
    # Проверяем, существует ли пользователь matrix-synapse
    if id "$MAS_USER" &>/dev/null; then
        log "INFO" "Системный пользователь $MAS_USER уже существует"
        return 0
    fi
    
    log "INFO" "Создание системного пользователя $MAS_USER..."
    
    # Создаем группу matrix-synapse если не существует
    if ! getent group "$MAS_GROUP" &>/dev/null; then
        if ! groupadd --system "$MAS_GROUP"; then
            log "ERROR" "Не удалось создать группу $MAS_GROUP"
            return 1
        fi
        log "INFO" "Группа $MAS_GROUP создана"
    fi
    
    # Создаем пользователя matrix-synapse
    if ! useradd --system \
                 --no-create-home \
                 --shell /bin/false \
                 --gid "$MAS_GROUP" \
                 --comment "Matrix Authentication Service" \
                 "$MAS_USER"; then
        log "ERROR" "Не удалось создать пользователя $MAS_USER"
        return 1
    fi
    
    log "SUCCESS" "Системный пользователь $MAS_USER создан"
    return 0
}

# Создание systemd сервиса для MAS (полностью исправленная версия)
create_mas_systemd_service() {
    log "INFO" "Создание systemd сервиса для MAS..."
    
    cat > /etc/systemd/system/matrix-auth-service.service <<EOF
[Unit]
Description=Matrix Authentication Service
Documentation=https://element-hq.github.io/matrix-authentication-service/
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=$MAS_USER
Group=$MAS_GROUP
# КРИТИЧЕСКИ ВАЖНО: Устанавливаем правильную рабочую директорию
WorkingDirectory=/var/lib/mas
# ВАЖНО: Используем mas-cli с явным указанием пути к конфигурации 
ExecStart=/usr/local/bin/mas-cli server --config $MAS_CONFIG_FILE
Restart=always
RestartSec=10

# ТОЛЬКО безопасные переменные окружения
Environment=RUST_LOG=info

# НЕ передаем DATABASE_URL или другие проблемные переменные!
# MAS должен читать конфигурацию только из config.yaml

# Безопасность
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/mas $MAS_CONFIG_DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    # Создаем правильную рабочую директорию
    local mas_work_dir="/var/lib/mas"
    mkdir -p "$mas_work_dir"
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir"
    
    # Создаем безопасный .env файл
    cat > "$mas_work_dir/.env" << EOF
# MAS Environment Variables - БЕЗОПАСНАЯ ВЕРСИЯ
# $(date '+%Y-%m-%d %H:%M:%S')

# Только безопасные переменные окружения
RUST_LOG=info

# НЕ указываем DATABASE_URL - пусть читает из config.yaml!
# НЕ указываем MAS_CONFIG - используем --config флаг!
EOF
    
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir/.env"
    chmod 600 "$mas_work_dir/.env"
    
    # Перезагружаем systemd и включаем сервис
    systemctl daemon-reload
    systemctl enable matrix-auth-service
    
    log "SUCCESS" "Systemd сервис создан и включен с правильной командой (/usr/local/bin/mas-cli)"
    log "INFO" "Сервис будет запускаться с очищенным окружением и правильными правами доступа"
    return 0
}

# Настройка интеграции Synapse с MAS
configure_synapse_mas_integration() {
    local mas_port="$1"
    local mas_secret="$2"
    
    log "INFO" "Настройка интеграции Synapse с MAS..."
    
    # Создаем конфигурацию для Synapse
    cat > "$SYNAPSE_MAS_CONFIG" <<EOF
# Matrix Authentication Service Integration (MSC3861)
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Type: ${SERVER_TYPE:-hosting}
# MAS Port: $mas_port

# Экспериментальные функции для MSC3861
experimental_features:
  # Matrix Authentication Service интеграция
  msc3861:
    enabled: true
    
    # URL эмитента OIDC (MAS сервер)
    issuer: "http://localhost:$mas_port"
    
    # ID клиента для Synapse в MAS
    client_id: "0000000000000000000SYNAPSE"
    
    # Метод аутентификации клиента
    client_auth_method: client_secret_basic
    
    # Секрет клиента
    client_secret: "$mas_secret"
    
    # Административный токен для API взаимодействия
    admin_token: "$mas_secret"
    
    # URL для управления аккаунтами
    account_management_url: "http://localhost:$mas_port/account/"
    
    # URL для интроспекции токенов
    introspection_endpoint: "http://localhost:$mas_port/oauth2/introspect"

# Отключаем встроенную регистрацию Synapse в пользу MAS
enable_registration: false
disable_msisdn_registration: true

# Современые функции Matrix
experimental_features:
  spaces_enabled: true
  msc3440_enabled: true  # Threading
  msc3720_enabled: true  # Account data
  msc3827_enabled: true  # Filtering
  msc3861_enabled: true  # Matrix Authentication Service
EOF

    log "SUCCESS" "Конфигурация интеграции Synapse с MAS создана"
    return 0
}

# Диагностика и исправление проблем базы данных MAS
fix_mas_database_issues() {
    log "INFO" "Диагностика и исправление проблем базы данных MAS..."
    
    # Проверяем существование конфигурационных файлов
    if [ ! -f "$CONFIG_DIR/mas_database.conf" ]; then
        log "ERROR" "Файл конфигурации базы данных MAS не найден: $CONFIG_DIR/mas_database.conf"
        return 1
    fi
    
    if [ ! -f "$MAS_CONFIG_FILE" ]; then
        log "ERROR" "Конфигурационный файл MAS не найден: $MAS_CONFIG_FILE"
        return 1
    fi
    
    # Загружаем параметры базы данных
    local db_uri=$(grep "MAS_DB_URI=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    local db_user=$(grep "MAS_DB_USER=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    local db_password=$(grep "MAS_DB_PASSWORD=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    local db_name=$(grep "MAS_DB_NAME=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    
    log "DEBUG" "Параметры базы данных MAS:"
    log "DEBUG" "  URI: $db_uri"
    log "DEBUG" "  Пользователь: $db_user"
    log "DEBUG" "  База данных: $db_name"
    
    # Проверяем секцию database в конфигурации MAS
    if ! grep -q "^database:" "$MAS_CONFIG_FILE"; then
        log "ERROR" "Секция database отсутствует в конфигурации MAS!"
        log "INFO" "Проблема с конфигурацией, отсутствует секция database:"
        grep -A 5 "^http:" "$MAS_CONFIG_FILE" || true
        return 1
    fi
    
    # Проверяем URI в конфигурации MAS
    local config_uri=$(grep -A 5 "^database:" "$MAS_CONFIG_FILE" | grep "uri:" | sed 's/.*uri: *//' | tr -d '"' 2>/dev/null)
    
    if [ -z "$config_uri" ]; then
        log "ERROR" "URI базы данных не найден в конфигурации MAS"
        log "INFO" "Исправление конфигурации MAS..."
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Добавляем недостающую секцию database
        if ! grep -q "^database:" "$MAS_CONFIG_FILE"; then
            # Если секция database полностью отсутствует, добавляем её после http секции
            sed -i '/^http:/a\\ndatabase:\n  uri: "'"$db_uri"'"' "$MAS_CONFIG_FILE"
        else
            # Если секция database есть, но без uri, добавляем uri
            sed -i '/^database:$/a\  uri: "'"$db_uri"'"' "$MAS_CONFIG_FILE"
        fi
        
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        log "SUCCESS" "Конфигурация MAS исправлена"
        config_uri="$db_uri"
    elif [ "$config_uri" != "$db_uri" ]; then
        log "WARN" "URI в конфигурации MAS не соответствует сохраненному URI"
        log "INFO" "Исправление URI в конфигурации MAS..."
        
        # Создаем резервную копию
        cp "$MAS_CONFIG_FILE" "$MAS_CONFIG_FILE.backup.$(date +%s)"
        
        # Исправляем URI
        sed -i "s|uri: \".*\"|uri: \"$db_uri\"|" "$MAS_CONFIG_FILE"
        
        # Устанавливаем права
        chown "$MAS_USER:$MAS_GROUP" "$MAS_CONFIG_FILE"
        chmod 600 "$MAS_CONFIG_FILE"
        
        log "SUCCESS" "URI в конфигурации MAS исправлен"
    fi
    
    # Проверяем существование пользователя PostgreSQL
    local user_exists=$(sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" | grep -c 1)
    
    if [ "$user_exists" -eq 0 ]; then
        log "ERROR" "Пользователь PostgreSQL '$db_user' не существует"
        log "ERROR" "Этот пользователь должен быть создан на этапе основной установки Matrix"
        log "ERROR" "Запустите сначала модуль core_install.sh"
        return 1
    else
        log "SUCCESS" "Пользователь PostgreSQL '$db_user' существует"
    fi
    
    # Проверяем существование базы данных mas_db
    local db_exists=$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -w "$db_name" | wc -l)
    
    if [ "$db_exists" -eq 0 ]; then
        log "ERROR" "База данных '$db_name' не существует"
        log "INFO" "Создание базы данных $db_name..."
        
        if sudo -u postgres createdb --encoding=UTF8 --locale=C --template=template0 --owner="$db_user" "$db_name"; then
            log "SUCCESS" "База данных $db_name создана"
        else
            log "ERROR" "Не удалось создать базу данных $db_name"
            return 1
        fi
    else
        log "SUCCESS" "База данных '$db_name' существует"
    fi
    
    # Проверяем подключение к базе данных
    log "INFO" "Проверка подключения к базе данных..."
    if PGPASSWORD="$db_password" psql -h localhost -U "$db_user" -d "$db_name" -c "SELECT 1;" &>/dev/null; then
        log "SUCCESS" "Подключение к базе данных работает"
    else
        log "ERROR" "Не удается подключиться к базе данных MAS"
        
        # Проверяем права пользователя
        log "INFO" "Проверка и исправление прав пользователя на базу данных..."
        
        # Даем полные права на базу данных
        if sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $db_name TO \"$db_user\";" 2>/dev/null; then
            log "INFO" "Права на базу данных предоставлены"
        fi
        
        # Даем права на схему public если база уже существует
        if sudo -u postgres psql -d "$db_name" -c "GRANT ALL ON SCHEMA public TO \"$db_user\";" 2>/dev/null; then
            log "INFO" "Права на схему public предоставлены"
        fi
        
        # Повторная проверка подключения
        if PGPASSWORD="$db_password" psql -h localhost -U "$db_user" -d "$db_name" -c "SELECT 1;" &>/dev/null; then
            log "SUCCESS" "Подключение к базе данных теперь работает"
        else
            log "ERROR" "Подключение к базе данных все еще не работает"
            
            # Дополнительная диагностика
            log "DEBUG" "Дополнительная диагностика подключения:"
            log "DEBUG" "  Пользователь: $db_user"
            log "DEBUG" "  База данных: $db_name"
            log "DEBUG" "  Хост: localhost"
            
            # Проверяем, может ли пользователь вообще подключиться к PostgreSQL
            if PGPASSWORD="$db_password" psql -h localhost -U "$db_user" -d postgres -c "SELECT 1;" &>/dev/null; then
                log "DEBUG" "Пользователь может подключиться к PostgreSQL"
            else
                log "DEBUG" "Пользователь НЕ может подключиться к PostgreSQL"
            fi
            
            return 1
        fi
    fi
    
    return 0
}

# Инициализация базы данных MAS (исправленная версия)
initialize_mas_database() {
    log "INFO" "Инициализация базы данных MAS..."
    
    # Проверяем, что пользователь matrix-synapse существует в системе
    if ! id "$MAS_USER" &>/dev/null; then
        log "ERROR" "Системный пользователь $MAS_USER не существует"
        log "ERROR" "Пользователь должен был быть создан на этапе генерации конфигурации"
        return 1
    fi
    
    # КРИТИЧЕСКИ ВАЖНО: Создаем рабочую директорию с правильными правами
    log "INFO" "Создание рабочей директории MAS..."
    local mas_work_dir="/var/lib/mas"
    mkdir -p "$mas_work_dir"
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir"
    
    # Создаем безопасный .env файл (очищенный от проблемных переменных)
    log "INFO" "Создание безопасного .env файла..."
    cat > "$mas_work_dir/.env" << EOF
# MAS Environment Variables - БЕЗОПАСНАЯ ВЕРСИЯ
# $(date '+%Y-%m-%d %H:%M:%S')

# Только безопасные переменные окружения
RUST_LOG=info

# НЕ указываем DATABASE_URL - пусть читает из config.yaml!
# НЕ указываем MAS_CONFIG - используем --config флаг!
EOF
    
    chown "$MAS_USER:$MAS_GROUP" "$mas_work_dir/.env"
    chmod 600 "$mas_work_dir/.env"
    
    log "SUCCESS" "Рабочая директория и .env файл созданы"
    
    # Выполняем диагностику и исправление проблем БД
    if ! fix_mas_database_issues; then
        log "ERROR" "Не удалось исправить проблемы с базой данных"
        return 1
    fi
    
    # КРИТИЧЕСКИ ВАЖНО: Переходим в рабочую директорию перед выполнением команд MAS
    log "INFO" "Переход в рабочую директорию MAS: $mas_work_dir"
    cd "$mas_work_dir" || {
        log "ERROR" "Не удалось перейти в рабочую директорию $mas_work_dir"
        return 1
    }
    
    # ВАЖНО: Очищаем переменные окружения перед запуском
    log "INFO" "Очистка проблемных переменных окружения..."
    unset DATABASE_URL
    unset MAS_CONFIG
    
    # Проверяем конфигурацию перед миграцией
    log "INFO" "Проверка конфигурации перед миграцией..."
    log "DEBUG" "Рабочая директория: $(pwd)"
    log "DEBUG" "Конфигурационный файл: $MAS_CONFIG_FILE"
    
    # Показываем URI из конфигурации для диагностики
    local config_uri=$(grep -A 1 "^database:" "$MAS_CONFIG_FILE" | grep "uri:" | sed 's/.*uri: *//' | tr -d '"' 2>/dev/null)
    if [ -n "$config_uri" ]; then
        # Скрываем пароль в логах
        local safe_uri=$(echo "$config_uri" | sed 's/:[^:]*@/:***@/')
        log "DEBUG" "URI в конфигурации: $safe_uri"
    else
        log "ERROR" "URI не найден в конфигурации!"
        return 1
    fi
    
    # Выполняем миграции базы данных с очищенным окружением
    log "INFO" "Выполнение миграций базы данных MAS..."
    if sudo -u "$MAS_USER" env -i RUST_LOG=info DATABASE_URL="" /usr/local/bin/mas database migrate --config "$MAS_CONFIG_FILE"; then
        log "SUCCESS" "Миграции базы данных MAS выполнены"
    else
        log "ERROR" "Ошибка выполнения миграций базы данных MAS"
        
        # Дополнительная диагностика
        log "INFO" "Дополнительная диагностика..."
        
        # Показываем содержимое конфигурации (без паролей)
        log "DEBUG" "Конфигурация базы данных в MAS config.yaml:"
        grep -A 2 "^database:" "$MAS_CONFIG_FILE" 2>/dev/null | sed 's/password[^"]*"[^"]*"/password:***/' || log "ERROR" "Секция database не найдена"
        
        # Проверяем права доступа к файлам
        log "DEBUG" "Права доступа к файлам:"
        if [ -f "$MAS_CONFIG_FILE" ]; then
            local file_perms=$(ls -la "$MAS_CONFIG_FILE" 2>/dev/null)
            log "DEBUG" "Config.yaml: $file_perms"
        else
            log "ERROR" "Конфигурационный файл недоступен: $MAS_CONFIG_FILE"
        fi
        
        if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
            local db_file_perms=$(ls -la "$CONFIG_DIR/mas_database.conf" 2>/dev/null)
            log "DEBUG" "Database config: $db_file_perms"
        else
            log "ERROR" "Файл конфигурации БД недоступен: $CONFIG_DIR/mas_database.conf"
        fi
        
        # Проверяем валидность конфигурации
        log "DEBUG" "Проверка валидности конфигурации MAS..."
        if sudo -u "$MAS_USER" env -i RUST_LOG=info /usr/local/bin/mas config check --config "$MAS_CONFIG_FILE" 2>&1 | head -10; then
            log "DEBUG" "Конфигурация прошла проверку"
        else
            log "ERROR" "Конфигурация не прошла проверку"
        fi
        
        # Проверяем подключение к базе данных вручную
        log "DEBUG" "Проверка подключения к базе данных вручную..."
        if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
            local db_password=$(grep "MAS_DB_PASSWORD=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
            local db_name=$(grep "MAS_DB_NAME=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
            
            if [ -n "$db_password" ] && [ -n "$db_name" ]; then
                if PGPASSWORD="$db_password" psql -h localhost -U synapse_user -d "$db_name" -c "SELECT version();" 2>/dev/null | head -1; then
                    log "SUCCESS" "Подключение к PostgreSQL работает"
                else
                    log "ERROR" "Проблема с подключением к PostgreSQL"
                fi
            fi
        fi
        
        return 1
    fi
    
    # Синхронизируем конфигурацию с базой данных
    log "INFO" "Синхронизация конфигурации с базой данных..."
    if sudo -u "$MAS_USER" env -i RUST_LOG=info DATABASE_URL="" /usr/local/bin/mas config sync --config "$MAS_CONFIG_FILE"; then
        log "SUCCESS" "Конфигурация MAS синхронизирована с базой данных"
    else
        log "WARN" "Ошибка синхронизации конфигурации MAS (но миграции выполнены успешно)"
        # Не возвращаем ошибку, так как основная задача (миграции) выполнена
    fi
    
    # Возвращаемся в исходную директорию
    cd - >/dev/null || true
    
    return 0
}

# Основная функция установки MAS
install_matrix_authentication_service() {
    print_header "УСТАНОВКА MATRIX AUTHENTICATION SERVICE" "$GREEN"
    
    # Показываем информацию о режиме установки
    safe_echo "${BOLD}${CYAN}Режим установки для ${SERVER_TYPE:-неопределенного типа сервера}:${NC}"
    case "${SERVER_TYPE:-hosting}" in
        "proxmox"|"home_server"|"openvz"|"docker")
            safe_echo "• Домашний сервер/Proxmox режим"
            safe_echo "• MAS порт: $MAS_PORT_PROXMOX (избегает конфликтов)"
            safe_echo "• Bind адрес: $BIND_ADDRESS"
            safe_echo "• Требуется настройка reverse proxy на хосте"
            ;;
        *)
            safe_echo "• Облачный хостинг режим"
            safe_echo "• MAS порт: $MAS_PORT_HOSTING (стандартный)"
            safe_echo "• Bind адрес: $BIND_ADDRESS"
            safe_echo "• Отдельный поддомен auth.domain.com"
            ;;
    esac
    echo
    
    # Проверяем зависимости для сборки
    if ! check_mas_build_dependencies; then
        return 1
    fi
    
    # Получаем домен сервера
    if [ ! -f "$CONFIG_DIR/domain" ]; then
        log "ERROR" "Домен сервера не настроен. Запустите сначала основную установку Matrix."
        return 1
    fi
    
    local matrix_domain=$(cat "$CONFIG_DIR/domain")
    log "INFO" "Домен Matrix сервера: $matrix_domain"
    
    # Определяем и проверяем порт MAS
    local default_port=$(determine_mas_port)
    local mas_port=$(check_mas_port "$default_port")
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Не удалось найти свободный порт для MAS"
        return 1
    fi
    
    log "INFO" "Использование порта $mas_port для MAS"
    
    # Генерируем секретный ключ для MAS
    local mas_secret=$(openssl rand -hex 32)
    
    # Настраиваем базу данных для MAS
    if ! setup_mas_database; then
        return 1
    fi
    
    # Получаем URI базы данных
    local db_uri=$(grep "MAS_DB_URI=" "$CONFIG_DIR/mas_database.conf" | cut -d'=' -f2 | tr -d '"')
    
    # Собираем MAS из исходников
    if ! build_mas_from_source; then
        return 1
    fi
    
    # Генерируем конфигурацию MAS
    if ! generate_mas_config "$mas_port" "$matrix_domain" "$mas_secret" "$db_uri"; then
        return 1
    fi
    
    # Создаем systemd сервис
    if ! create_mas_systemd_service; then
        return 1
    fi
    
    # Инициализируем базу данных MAS
    if ! initialize_mas_database; then
        return 1
    fi
    
    # Настраиваем интеграцию с Synapse
    if ! configure_synapse_mas_integration "$mas_port" "$mas_secret"; then
        return 1
    fi
    
    # Сохраняем информацию о конфигурации MAS
    {
        echo "# MAS Configuration Info"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "MAS_PORT=\"$mas_port\""
        echo "MAS_SECRET=\"$mas_secret\""
        echo "MAS_SERVER_TYPE=\"${SERVER_TYPE:-hosting}\""
        echo "MAS_BIND_ADDRESS=\"$BIND_ADDRESS:$mas_port\""
        echo "MAS_DOMAIN=\"$matrix_domain\""
        case "${SERVER_TYPE:-hosting}" in
            "proxmox"|"home_server"|"openvz"|"docker")
                echo "MAS_PUBLIC_BASE=\"https://$matrix_domain\""
                echo "MAS_MODE=\"reverse_proxy\""
                ;;
            *)
                echo "MAS_PUBLIC_BASE=\"https://auth.$matrix_domain\""
                echo "MAS_MODE=\"direct\""
                ;;
        esac
    } > "$CONFIG_DIR/mas.conf"
    
    # Запускаем сервис MAS
    log "INFO" "Запуск Matrix Authentication Service..."
    if systemctl start matrix-auth-service; then
        log "SUCCESS" "Matrix Authentication Service запущен"
        
        # Ждем запуска
        sleep 5
        
        # Проверяем статус
        if systemctl is-active --quiet matrix-auth-service; then
            log "SUCCESS" "MAS работает корректно"
            
            # Проверяем доступность API
            local health_url="http://localhost:$mas_port/health"
            if curl -s -f "$health_url" >/dev/null 2>&1; then
                log "SUCCESS" "MAS API доступен на порту $mas_port"
            else
                log "WARN" "MAS API пока недоступен (возможно, еще инициализируется)"
            fi
            
            # Перезагружаем Synapse для применения конфигурации MAS
            log "INFO" "Перезапуск Synapse для применения конфигурации MAS..."
            if systemctl restart matrix-synapse; then
                log "SUCCESS" "Synapse перезапущен с поддержкой MAS"
                
                print_header "УСТАНОВКА MAS ЗАВЕРШЕНА УСПЕШНО" "$GREEN"
                
                safe_echo "${GREEN}🎉 Matrix Authentication Service успешно установлен!${NC}"
                echo
                safe_echo "${BOLD}${BLUE}Конфигурация для ${SERVER_TYPE:-hosting}:${NC}"
                safe_echo "• ✅ MAS сервер запущен на порту $mas_port"
                safe_echo "• ✅ Bind адрес: $BIND_ADDRESS:$mas_port"
                safe_echo "• ✅ База данных: $MAS_DB_NAME"
                safe_echo "• ✅ Synapse настроен для работы с MAS (MSC3861)"
                safe_echo "• ✅ Мобильные приложения Element X теперь поддерживаются"
                safe_echo "• ✅ Современная OAuth2/OCID аутентификация включена"
                echo
                safe_echo "${BOLD}${BLUE}Проверка работы:${NC}"
                safe_echo "• Статус MAS: ${CYAN}systemctl status matrix-auth-service${NC}"
                safe_echo "• Логи MAS: ${CYAN}journalctl -u matrix-auth-service -f${NC}"
                safe_echo "• Веб-интерфейс: ${CYAN}http://localhost:$mas_port${NC}"
                safe_echo "• Health check: ${CYAN}curl http://localhost:$mas_port/health${NC}"
                safe_echo "• Диагностика: ${CYAN}mas doctor --config $MAS_CONFIG_FILE${NC}"
                echo
                safe_echo "${BOLD}${BLUE}Следующие шаги:${NC}"
                case "${SERVER_TYPE:-hosting}" in
                    "proxmox"|"home_server"|"openvz"|"docker")
                        safe_echo "• ${YELLOW}Настройте reverse proxy на хосте для MAS${NC}"
                        safe_echo "• ${YELLOW}Добавьте маршрутизацию для /_matrix/client/*/login${NC}"
                        safe_echo "• ${YELLOW}Добавьте маршрутизацию для /_matrix/client/*/logout${NC}"
                        safe_echo "• ${YELLOW}Добавьте маршрутизацию для /_matrix/client/*/refresh${NC}"
                        safe_echo "• ${YELLOW}MAS будет доступен по домену: https://$matrix_domain${NC}"
                        ;;
                    *)
                        safe_echo "• ${YELLOW}Настройте DNS для auth.$matrix_domain${NC}"
                        safe_echo "• ${YELLOW}Настройте SSL сертификат для MAS${NC}"
                        safe_echo "• ${YELLOW}MAS будет доступен по адресу: https://auth.$matrix_domain${NC}"
                        ;;
                esac
                echo
                safe_echo "${BOLD}${BLUE}Регистрация пользователей теперь происходит через:${NC}"
                safe_echo "• Element X (мобильное приложение) ✅"
                safe_echo "• Element Web с OAuth2 ✅"
                safe_echo "• Другие современные Matrix клиенты ✅"
                safe_echo "• Веб-интерфейс MAS для управления аккаунтами ✅"
                
            else
                log "ERROR" "Ошибка перезапуска Synapse"
                return 1
            fi
        else
            log "ERROR" "MAS не запустился корректно"
            log "INFO" "Проверьте логи: journalctl -u matrix-auth-service -n 20"
            return 1
        fi
    else
        log "ERROR" "Ошибка запуска Matrix Authentication Service"
        return 1
    fi
    
    return 0
}

# Главная функция установки MAS
main() {
    # Проверяем, что PostgreSQL установлен и запущен
    if ! command -v psql &>/dev/null; then
        log "ERROR" "PostgreSQL не установлен"
        exit 1
    fi
    
    if ! systemctl is-active --quiet postgresql; then
        log "ERROR" "PostgreSQL не запущен"
        exit 1
    fi
    
    # Проверяем, что Synapse установлен
    if ! command -v synctl &>/dev/null; then
        log "ERROR" "Matrix Synapse не установлен"
        exit 1
    fi
    
    # Создаем необходимые директории
    mkdir -p "$CONFIG_DIR"
    
    # Запускаем только установку
    install_matrix_authentication_service
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi