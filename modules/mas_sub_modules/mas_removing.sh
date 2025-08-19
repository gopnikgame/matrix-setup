#!/bin/bash

# Matrix Authentication Service (MAS) - Модуль удаления
# Версия: 1.1.0

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
SYNAPSE_MAS_CONFIG="/etc/matrix-synapse/conf.d/mas.yaml"
HOMESERVER_CONFIG="/etc/matrix-synapse/homeserver.yaml"
MAS_USER="matrix-synapse"
MAS_GROUP="matrix-synapse"
MAS_DB_NAME="mas_db"

# Проверка root прав
check_root

# Загружаем тип сервера
load_server_type

# Удаление MAS
uninstall_mas() {
    print_header "УДАЛЕНИЕ MATRIX AUTHENTICATION SERVICE" "$RED"

    log "WARN" "Это действие полностью удалит Matrix Authentication Service"
    log "WARN" "Включая все конфигурации, данные и интеграцию с Synapse"
    echo
    
    if ! ask_confirmation "Вы действительно хотите удалить Matrix Authentication Service?"; then
        log "INFO" "Удаление отменено"
        return 0
    fi

    log "INFO" "Начинаю удаление MAS..."

    # Остановка службы MAS
    log "INFO" "Остановка службы matrix-auth-service..."
    if systemctl is-active --quiet matrix-auth-service; then
        log "INFO" "Остановка запущенной службы matrix-auth-service..."
        if systemctl stop matrix-auth-service; then
            log "SUCCESS" "Служба matrix-auth-service остановлена"
        else
            log "WARN" "Не удалось корректно остановить службу matrix-auth-service"
        fi
    else
        log "INFO" "Служба matrix-auth-service уже остановлена"
    fi

    # Отключение автозапуска
    log "INFO" "Отключение автозапуска matrix-auth-service..."
    if systemctl is-enabled --quiet matrix-auth-service 2>/dev/null; then
        log "INFO" "Отключение автозапуска matrix-auth-service..."
        if systemctl disable matrix-auth-service 2>/dev/null; then
            log "SUCCESS" "Автозапуск службы отключен"
        else
            log "WARN" "Не удалось отключить автозапуск службы"
        fi
    else
        log "INFO" "Автозапуск службы уже отключен"
    fi

    # Удаление systemd сервиса
    log "INFO" "Удаление systemd сервиса..."
    if [ -f "/etc/systemd/system/matrix-auth-service.service" ]; then
        log "INFO" "Удаление файла службы systemd..."
        if rm -f /etc/systemd/system/matrix-auth-service.service; then
            log "SUCCESS" "Файл службы systemd удален"
            systemctl daemon-reload
            log "INFO" "systemd конфигурация перезагружена"
        else
            log "ERROR" "Не удалось удалить файл службы systemd"
        fi
    else
        log "INFO" "Файл службы systemd не найден"
    fi

    # Удаление бинарного файла MAS
    log "INFO" "Удаление бинарного файла MAS..."
    if [ -f "/usr/local/bin/mas" ]; then
        log "INFO" "Удаление /usr/local/bin/mas..."
        if rm -f /usr/local/bin/mas; then
            log "SUCCESS" "Бинарный файл MAS удален"
        else
            log "ERROR" "Не удалось удалить бинарный файл MAS"
        fi
    else
        log "INFO" "Бинарный файл MAS не найден"
    fi

    # Удаление файлов MAS share
    log "INFO" "Удаление файлов MAS share..."
    if [ -d "/usr/local/share/mas-cli" ]; then
        log "INFO" "Удаление директории /usr/local/share/mas-cli..."
        if rm -rf /usr/local/share/mas-cli; then
            log "SUCCESS" "Файлы MAS share удалены"
        else
            log "ERROR" "Не удалось удалить файлы MAS share"
        fi
    else
        log "INFO" "Директория MAS share не найдена"
    fi

    # Удаление конфигурационных файлов MAS
    log "INFO" "Удаление конфигурации MAS..."
    if [ -d "$MAS_CONFIG_DIR" ]; then
        log "INFO" "Создание резервной копии конфигурации MAS..."
        backup_file "$MAS_CONFIG_DIR" "mas_config"
        
        log "INFO" "Удаление директории $MAS_CONFIG_DIR..."
        if rm -rf "$MAS_CONFIG_DIR"; then
            log "SUCCESS" "Конфигурация MAS удалена"
        else
            log "ERROR" "Не удалось удалить конфигурацию MAS"
        fi
    else
        log "INFO" "Конфигурационная директория MAS не найдена"
    fi

    # Удаление интеграции с Synapse
    log "INFO" "Удаление интеграции с Synapse..."
    if [ -f "$SYNAPSE_MAS_CONFIG" ]; then
        log "INFO" "Создание резервной копии конфигурации интеграции..."
        backup_file "$SYNAPSE_MAS_CONFIG" "synapse_mas_integration"
        
        log "INFO" "Удаление файла интеграции $SYNAPSE_MAS_CONFIG..."
        if rm -f "$SYNAPSE_MAS_CONFIG" ]; then
            log "SUCCESS" "Файл интеграции с Synapse удален"
        else
            log "ERROR" "Не удалось удалить файл интеграции с Synapse"
        fi
        
        # Перезапуск Synapse для применения изменений
        if systemctl is-active --quiet matrix-synapse; then
            log "INFO" "Перезапуск Synapse для применения изменений..."
            if restart_service "matrix-synapse"; then
                log "SUCCESS" "Synapse перезапущен успешно"
            else
                log "ERROR" "Ошибка перезапуска Synapse"
            fi
        else
            log "WARN" "Synapse не запущен, перезапуск пропущен"
        fi
    else
        log "INFO" "Файл интеграции с Synapse не найден"
    fi

    # Удаление данных MAS
    log "INFO" "Удаление данных MAS..."
    if [ -d "/var/lib/mas" ]; then
        log "INFO" "Создание резервной копии данных MAS..."
        backup_file "/var/lib/mas" "mas_data"
        
        log "INFO" "Удаление директории /var/lib/mas..."
        if rm -rf /var/lib/mas; then
            log "SUCCESS" "Данные MAS удалены"
        else
            log "ERROR" "Не удалось удалить данные MAS"
        fi
    else
        log "INFO" "Директория данных MAS не найдена"
    fi

    # Удаление конфигурационных файлов установщика
    log "INFO" "Удаление конфигурационных файлов установщика..."
    
    if [ -f "$CONFIG_DIR/mas.conf" ]; then
        log "INFO" "Создание резервной копии mas.conf..."
        backup_file "$CONFIG_DIR/mas.conf" "mas_installer_config"
        
        if rm -f "$CONFIG_DIR/mas.conf"; then
            log "SUCCESS" "Файл mas.conf удален"
        else
            log "WARN" "Не удалось удалить файл mas.conf"
        fi
    else
        log "INFO" "Файл mas.conf не найден"
    fi
    
    if [ -f "$CONFIG_DIR/mas_database.conf" ]; then
        log "INFO" "Создание резервной копии mas_database.conf..."
        backup_file "$CONFIG_DIR/mas_database.conf" "mas_database_config"
        
        if rm -f "$CONFIG_DIR/mas_database.conf"; then
            log "SUCCESS" "Файл mas_database.conf удален"
        else
            log "WARN" "Не удалось удалить файл mas_database.conf"
        fi
    else
        log "INFO" "Файл mas_database.conf не найден"
    fi

    # Удаление базы данных MAS (опционально)
    if ask_confirmation "Удалить также базу данных MAS ($MAS_DB_NAME)?"; then
        log "INFO" "Проверка существования базы данных $MAS_DB_NAME..."
        
        # Проверяем существование базы данных более надежным способом
        if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$MAS_DB_NAME" 2>/dev/null; then
            log "INFO" "База данных $MAS_DB_NAME найдена, выполняю удаление..."
            
            # Завершаем все активные подключения к базе данных
            sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$MAS_DB_NAME';" 2>/dev/null || true
            
            # Удаляем базу данных
            if sudo -u postgres dropdb "$MAS_DB_NAME" 2>/dev/null; then
                log "SUCCESS" "База данных $MAS_DB_NAME удалена"
            else
                log "ERROR" "Не удалось удалить базу данных $MAS_DB_NAME"
                log "INFO" "Возможные причины: активные подключения, недостаточные права"
            fi
        else
            log "INFO" "База данных $MAS_DB_NAME не найдена или недоступна"
        fi
    else
        log "INFO" "Удаление базы данных пропущено"
    fi

    # Опционально удаляем пользователя matrix-synapse (только если нет Synapse)
    if ! systemctl is-active --quiet matrix-synapse && ! [ -f "/etc/matrix-synapse/homeserver.yaml" ]; then
        if ask_confirmation "Matrix Synapse не обнаружен. Удалить также системного пользователя $MAS_USER?"; then
            if id "$MAS_USER" &>/dev/null; then
                log "INFO" "Удаление пользователя $MAS_USER..."
                if userdel "$MAS_USER" 2>/dev/null; then
                    log "SUCCESS" "Пользователь $MAS_USER удален"
                else
                    log "WARN" "Не удалось удалить пользователя $MAS_USER (возможно, используется другими службами)"
                fi
            else
                log "INFO" "Пользователь $MAS_USER не найден"
            fi
        else
            log "INFO" "Удаление пользователя пропущено"
        fi
    else
        log "INFO" "Matrix Synapse обнаружен, пользователь $MAS_USER сохранен"
    fi

    # Финальная проверка и отчет
    log "INFO" "Выполнение финальной проверки удаления..."
    
    local cleanup_issues=()
    
    # Проверяем, что все критичные компоненты удалены
    [ -f "/usr/local/bin/mas" ] && cleanup_issues+=("Бинарный файл MAS")
    [ -d "/usr/local/share/mas-cli" ] && cleanup_issues+=("Файлы MAS share")
    [ -d "$MAS_CONFIG_DIR" ] && cleanup_issues+=("Конфигурация MAS")
    [ -f "/etc/systemd/system/matrix-auth-service.service" ] && cleanup_issues+=("Systemd служба")
    [ -f "$SYNAPSE_MAS_CONFIG" ] && cleanup_issues+=("Интеграция с Synapse")
    
    if [ ${#cleanup_issues[@]} -gt 0 ]; then
        log "WARN" "Некоторые компоненты не были полностью удалены:"
        for issue in "${cleanup_issues[@]}"; do
            log "WARN" "  • $issue"
        done
        log "INFO" "Рекомендуется проверить эти компоненты вручную"
    fi

    # Показываем информацию о резервных копиях
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        log "INFO" "Созданы резервные копии в директории: $BACKUP_DIR"
        log "INFO" "Список резервных копий:"
        ls -la "$BACKUP_DIR" | grep "mas" | awk '{print "  • " $9 " (" $5 " байт, " $6 " " $7 " " $8 ")"}'
    fi

    echo
    log "SUCCESS" "Matrix Authentication Service успешно удален"
    log "INFO" "Для восстановления используйте резервные копии из $BACKUP_DIR"
    log "INFO" "Для повторной установки запустите модуль установки MAS"
    echo
}

# Главная функция модуля
main() {
    # Проверяем, что MAS установлен
    if ! command -v mas >/dev/null 2>&1 && [ ! -f "$MAS_CONFIG_FILE" ] && [ ! -f "/etc/systemd/system/matrix-auth-service.service" ]; then
        print_header "MATRIX AUTHENTICATION SERVICE НЕ УСТАНОВЛЕН" "$YELLOW"
        log "WARN" "Matrix Authentication Service не найден в системе"
        log "INFO" "Нет необходимости в удалении"
        return 0
    fi
    
    uninstall_mas
}

# Если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi


