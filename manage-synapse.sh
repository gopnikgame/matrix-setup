#!/bin/bash

# Matrix Synapse Management Module v1.0
# Модуль для управления федерацией и регистрацией пользователей

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться от root" >&2
  exit 1
fi

# Глобальные переменные
HOMESERVER_CONFIG="/opt/synapse-data/homeserver.yaml"
DOCKER_COMPOSE_CONFIG="/opt/synapse-config/docker-compose.yml"
BACKUP_DIR="/opt/synapse-backups"

# Функция для проверки установки Synapse
check_synapse_installation() {
  if [ ! -f "$HOMESERVER_CONFIG" ]; then
    echo "❌ Конфигурация Synapse не найдена: $HOMESERVER_CONFIG"
    echo "Запустите сначала основной скрипт установки Matrix"
    return 1
  fi
  
  if ! docker ps | grep -q "matrix-synapse"; then
    echo "❌ Контейнер matrix-synapse не запущен"
    echo "Запустите: cd /opt/synapse-config && docker compose up -d synapse"
    return 1
  fi
  
  return 0
}

# Функция создания резервной копии конфигурации
backup_config() {
  local timestamp=$(date +"%Y%m%d_%H%M%S")
  local backup_file="$BACKUP_DIR/homeserver_${timestamp}.yaml"
  
  mkdir -p "$BACKUP_DIR"
  
  if cp "$HOMESERVER_CONFIG" "$backup_file"; then
    echo "✅ Резервная копия создана: $backup_file"
    return 0
  else
    echo "❌ Ошибка создания резервной копии"
    return 1
  fi
}

# Функция перезапуска Synapse
restart_synapse() {
  echo "Перезапуск Matrix Synapse..."
  
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация Docker не найдена"; return 1; }
  
  if docker compose restart synapse; then
    echo "✅ Synapse перезапущен"
    
    # Ожидание готовности
    echo "Ожидание готовности Synapse..."
    for i in {1..12}; do
      if curl -s http://localhost:8008/health >/dev/null 2>&1; then
        echo "✅ Synapse готов!"
        return 0
      else
        echo "   Ожидание... ($i/12)"
        sleep 5
      fi
    done
    
    echo "⚠️  Synapse запускается медленно, проверьте логи: docker logs matrix-synapse"
    return 1
  else
    echo "❌ Ошибка перезапуска Synapse"
    return 1
  fi
}

# =============================================================================
# УПРАВЛЕНИЕ ФЕДЕРАЦИЕЙ
# =============================================================================

# Функция получения текущего статуса федерации
get_federation_status() {
  local whitelist=$(grep -A 10 "federation_domain_whitelist:" "$HOMESERVER_CONFIG" | grep -E "^\s*-\s+" | wc -l)
  local suppress_warning=$(grep "suppress_key_server_warning:" "$HOMESERVER_CONFIG" | grep -o "true\|false")
  
  if [ "$whitelist" -eq 0 ]; then
    echo "❌ ОТКЛЮЧЕНА (пустой whitelist)"
  else
    echo "✅ ВКЛЮЧЕНА ($whitelist доменов в whitelist)"
  fi
  
  echo "Подавление предупреждений: $suppress_warning"
}

# Функция просмотра списка федерации
show_federation_domains() {
  echo "=== Список доменов федерации ==="
  echo ""
  
  local domains=$(grep -A 20 "federation_domain_whitelist:" "$HOMESERVER_CONFIG" | grep -E "^\s*-\s+" | sed 's/^\s*-\s*//')
  
  if [ -z "$domains" ]; then
    echo "📋 Федерация отключена (пустой список доменов)"
  else
    echo "📋 Разрешенные домены:"
    echo "$domains" | nl -w2 -s'. '
  fi
  
  echo ""
  local suppress=$(grep "suppress_key_server_warning:" "$HOMESERVER_CONFIG" | grep -o "true\|false")
  echo "🔇 Подавление предупреждений key server: $suppress"
}

# Функция включения федерации
enable_federation() {
  echo "=== Включение федерации Matrix ==="
  echo ""
  
  echo "⚠️  ВАЖНО: Включение федерации позволит вашему серверу:"
  echo "   • Общаться с пользователями других Matrix серверов"
  echo "   • Присоединяться к публичным комнатам"
  echo "   • Обмениваться сообщениями с федеративной сетью"
  echo ""
  echo "🔒 Соображения безопасности:"
  echo "   • Увеличивается поверхность атаки"
  echo "   • Возможны спам и нежелательный контент"
  echo "   • Рекомендуется whitelist проверенных серверов"
  echo ""
  
  read -p "Продолжить включение федерации? (y/N): " confirm
  if [[ $confirm != [yY] ]]; then
    echo "Операция отменена"
    return 0
  fi
  
  echo ""
  echo "Выберите режим федерации:"
  echo "1. Полная федерация (все серверы) - НЕ РЕКОМЕНДУЕТСЯ"
  echo "2. Whitelist серверов (безопасно)"
  echo "3. Только проверенные серверы (matrix.org, element.io)"
  echo ""
  read -p "Выберите вариант (1-3): " fed_choice
  
  case $fed_choice in
    1)
      enable_full_federation
      ;;
    2)
      enable_whitelist_federation
      ;;
    3)
      enable_trusted_federation
      ;;
    *)
      echo "❌ Неверный выбор"
      return 1
      ;;
  esac
}

# Полная федерация (удаление whitelist)
enable_full_federation() {
  echo "⚠️  ПРЕДУПРЕЖДЕНИЕ: Полная федерация открывает сервер для ВСЕХ Matrix серверов!"
  read -p "Вы уверены? Введите 'YES' для подтверждения: " final_confirm
  
  if [ "$final_confirm" != "YES" ]; then
    echo "Операция отменена"
    return 0
  fi
  
  if ! backup_config; then
    return 1
  fi
  
  # Удаляем или комментируем federation_domain_whitelist
  sed -i 's/^federation_domain_whitelist:/# federation_domain_whitelist: # ПОЛНАЯ ФЕДЕРАЦИЯ/' "$HOMESERVER_CONFIG"
  sed -i '/^# federation_domain_whitelist: # ПОЛНАЯ ФЕДЕРАЦИЯ/,/^[a-zA-Z]/{/^[[:space:]]*-/d;}' "$HOMESERVER_CONFIG"
  
  # Включаем предупреждения key server
  sed -i 's/suppress_key_server_warning: true/suppress_key_server_warning: false/' "$HOMESERVER_CONFIG"
  
  echo "✅ Полная федерация включена"
  restart_synapse
}

# Whitelist федерация
enable_whitelist_federation() {
  echo "=== Настройка whitelist федерации ==="
  echo ""
  echo "Введите домены серверов, которым разрешена федерация"
  echo "Примеры: matrix.org, element.io, t2bot.io"
  echo "Вводите по одному домену, пустая строка завершает ввод"
  echo ""
  
  local domains=()
  while true; do
    read -p "Домен (или Enter для завершения): " domain
    
    if [ -z "$domain" ]; then
      break
    fi
    
    # Простая валидация домена
    if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      domains+=("$domain")
      echo "✅ Добавлен: $domain"
    else
      echo "❌ Неверный формат домена: $domain"
    fi
  done
  
  if [ ${#domains[@]} -eq 0 ]; then
    echo "❌ Не введено ни одного домена"
    return 1
  fi
  
  if ! backup_config; then
    return 1
  fi
  
  # Создаем новый whitelist
  local whitelist_section="federation_domain_whitelist:"
  for domain in "${domains[@]}"; do
    whitelist_section+="\n  - \"$domain\""
  done
  
  # Заменяем существующий whitelist
  sed -i '/^federation_domain_whitelist:/,/^[a-zA-Z]/{/^federation_domain_whitelist:/!{/^[a-zA-Z]/!d;}}' "$HOMESERVER_CONFIG"
  sed -i "s/^federation_domain_whitelist:.*/$whitelist_section/" "$HOMESERVER_CONFIG"
  
  # Отключаем предупреждения key server
  sed -i 's/suppress_key_server_warning: true/suppress_key_server_warning: false/' "$HOMESERVER_CONFIG"
  
  echo "✅ Whitelist федерация настроена с ${#domains[@]} доменами"
  restart_synapse
}

# Проверенные серверы
enable_trusted_federation() {
  if ! backup_config; then
    return 1
  fi
  
  # Предустановленный список проверенных серверов
  local trusted_domains=(
    "matrix.org"
    "element.io"
    "mozilla.org"
    "kde.org"
    "gnome.org"
  )
  
  local whitelist_section="federation_domain_whitelist:"
  for domain in "${trusted_domains[@]}"; do
    whitelist_section+="\n  - \"$domain\""
  done
  
  # Заменяем существующий whitelist
  sed -i '/^federation_domain_whitelist:/,/^[a-zA-Z]/{/^federation_domain_whitelist:/!{/^[a-zA-Z]/!d;}}' "$HOMESERVER_CONFIG"
  sed -i "s/^federation_domain_whitelist:.*/$whitelist_section/" "$HOMESERVER_CONFIG"
  
  # Отключаем предупреждения key server
  sed -i 's/suppress_key_server_warning: true/suppress_key_server_warning: false/' "$HOMESERVER_CONFIG"
  
  echo "✅ Федерация включена с проверенными серверами:"
  printf '%s\n' "${trusted_domains[@]}" | nl -w2 -s'. '
  
  restart_synapse
}

# Функция отключения федерации
disable_federation() {
  echo "=== Отключение федерации Matrix ==="
  echo ""
  echo "⚠️  Отключение федерации означает:"
  echo "   • Потеря связи с пользователями других серверов"
  echo "   • Невозможность присоединения к внешним комнатам"
  echo "   • Изоляция сервера (только локальные пользователи)"
  echo ""
  
  read -p "Продолжить отключение федерации? (y/N): " confirm
  if [[ $confirm != [yY] ]]; then
    echo "Операция отменена"
    return 0
  fi
  
  if ! backup_config; then
    return 1
  fi
  
  # Очищаем whitelist (делаем пустым)
  sed -i '/^federation_domain_whitelist:/,/^[a-zA-Z]/{/^federation_domain_whitelist:/!{/^[a-zA-Z]/!d;}}' "$HOMESERVER_CONFIG"
  sed -i 's/^federation_domain_whitelist:.*/federation_domain_whitelist: []/' "$HOMESERVER_CONFIG"
  
  # Включаем подавление предупреждений key server
  sed -i 's/suppress_key_server_warning: false/suppress_key_server_warning: true/' "$HOMESERVER_CONFIG"
  
  echo "✅ Федерация отключена"
  restart_synapse
}

# Функция добавления домена в федерацию
add_federation_domain() {
  echo "=== Добавление домена в федерацию ==="
  echo ""
  
  read -p "Введите домен для добавления: " domain
  
  if [ -z "$domain" ]; then
    echo "❌ Домен не может быть пустым"
    return 1
  fi
  
  # Простая валидация домена
  if ! [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "❌ Неверный формат домена: $domain"
    return 1
  fi
  
  # Проверяем, не добавлен ли уже
  if grep -A 20 "federation_domain_whitelist:" "$HOMESERVER_CONFIG" | grep -q "\"$domain\""; then
    echo "⚠️  Домен $domain уже в списке федерации"
    return 0
  fi
  
  if ! backup_config; then
    return 1
  fi
  
  # Находим последнюю строку whitelist и добавляем новый домен
  local last_line=$(grep -n -A 20 "federation_domain_whitelist:" "$HOMESERVER_CONFIG" | grep -E "^\s*-\s+" | tail -1 | cut -d: -f1)
  
  if [ -z "$last_line" ]; then
    # Если whitelist пустой, заменяем [] на список
    sed -i "s/federation_domain_whitelist: \[\]/federation_domain_whitelist:\n  - \"$domain\"/" "$HOMESERVER_CONFIG"
  else
    # Добавляем в существующий список
    sed -i "${last_line}a\\  - \"$domain\"" "$HOMESERVER_CONFIG"
  fi
  
  echo "✅ Домен $domain добавлен в федерацию"
  restart_synapse
}

# Функция удаления домена из федерации
remove_federation_domain() {
  echo "=== Удаление домена из федерации ==="
  echo ""
  
  # Показываем текущий список
  local domains=$(grep -A 20 "federation_domain_whitelist:" "$HOMESERVER_CONFIG" | grep -E "^\s*-\s+" | sed 's/^\s*-\s*"//' | sed 's/"//')
  
  if [ -z "$domains" ]; then
    echo "📋 Список федерации пуст"
    return 0
  fi
  
  echo "📋 Текущие домены в федерации:"
  echo "$domains" | nl -w2 -s'. '
  echo ""
  
  read -p "Введите домен для удаления: " domain
  
  if [ -z "$domain" ]; then
    echo "❌ Домен не может быть пустым"
    return 1
  fi
  
  # Проверяем, есть ли домен в списке
  if ! echo "$domains" | grep -q "^$domain$"; then
    echo "❌ Домен $domain не найден в списке федерации"
    return 1
  fi
  
  if ! backup_config; then
    return 1
  fi
  
  # Удаляем домен из whitelist
  sed -i "/federation_domain_whitelist:/,/^[a-zA-Z]/{/\"$domain\"/d;}" "$HOMESERVER_CONFIG"
  
  echo "✅ Домен $domain удален из федерации"
  restart_synapse
}

# =============================================================================
# УПРАВЛЕНИЕ РЕГИСТРАЦИЕЙ ПОЛЬЗОВАТЕЛЕЙ
# =============================================================================

# Функция получения статуса регистрации
get_registration_status() {
  local enable_reg=$(grep "enable_registration:" "$HOMESERVER_CONFIG" | grep -o "true\|false")
  local require_token=$(grep "registration_requires_token:" "$HOMESERVER_CONFIG" | grep -o "true\|false")
  local shared_secret=$(grep "registration_shared_secret:" "$HOMESERVER_CONFIG" | cut -d'"' -f2)
  
  echo "Публичная регистрация: $enable_reg"
  echo "Требуется токен: $require_token"
  echo "Shared secret: ${shared_secret:0:8}... (для админов)"
}

# Функция просмотра настроек регистрации
show_registration_settings() {
  echo "=== Настройки регистрации пользователей ==="
  echo ""
  
  local enable_reg=$(grep "enable_registration:" "$HOMESERVER_CONFIG" | grep -o "true\|false")
  local require_token=$(grep "registration_requires_token:" "$HOMESERVER_CONFIG" | grep -o "true\|false")
  local shared_secret=$(grep "registration_shared_secret:" "$HOMESERVER_CONFIG" | cut -d'"' -f2)
  
  echo "📝 Текущие настройки:"
  echo "   Публичная регистрация: $enable_reg"
  echo "   Требуется токен: $require_token"
  echo ""
  
  if [ "$enable_reg" = "true" ]; then
    if [ "$require_token" = "true" ]; then
      echo "🔐 Режим: Регистрация только по токенам"
    else
      echo "🌐 Режим: Открытая публичная регистрация"
    fi
  else
    echo "🚫 Режим: Регистрация отключена (только админы)"
  fi
  
  echo ""
  echo "🔑 Shared Secret (для админов): ${shared_secret:0:12}..."
  echo ""
  echo "💡 Способы создания пользователей:"
  echo "   1. Через админа с shared secret"
  echo "   2. Через токены регистрации (если включены)"
  echo "   3. Открытая регистрация (если включена)"
}

# Функция управления режимами регистрации
configure_registration() {
  echo "=== Настройка регистрации пользователей ==="
  echo ""
  echo "Выберите режим регистрации:"
  echo "1. 🚫 Отключена (только админы) - БЕЗОПАСНО"
  echo "2. 🔐 Только по токенам - УМЕРЕННО БЕЗОПАСНО"
  echo "3. 🌐 Открытая публичная - НЕ РЕКОМЕНДУЕТСЯ"
  echo ""
  read -p "Выберите режим (1-3): " reg_choice
  
  case $reg_choice in
    1)
      set_registration_disabled
      ;;
    2)
      set_registration_token_only
      ;;
    3)
      set_registration_open
      ;;
    *)
      echo "❌ Неверный выбор"
      return 1
      ;;
  esac
}

# Отключить регистрацию
set_registration_disabled() {
  echo "=== Отключение регистрации ==="
  echo ""
  echo "✅ Это безопасный режим:"
  echo "   • Новые пользователи создаются только админами"
  echo "   • Используется registration_shared_secret"
  echo "   • Полный контроль над пользователями"
  echo ""
  
  if ! backup_config; then
    return 1
  fi
  
  sed -i 's/enable_registration: true/enable_registration: false/' "$HOMESERVER_CONFIG"
  sed -i 's/registration_requires_token: false/registration_requires_token: true/' "$HOMESERVER_CONFIG"
  
  echo "✅ Регистрация отключена"
  echo "📋 Создание пользователей только через:"
  echo "   docker exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008"
  
  restart_synapse
}

# Включить регистрацию только по токенам
set_registration_token_only() {
  echo "=== Регистрация только по токенам ==="
  echo ""
  echo "⚠️  Умеренно безопасный режим:"
  echo "   • Пользователи регистрируются по специальным токенам"
  echo "   • Токены создают и управляют админы"
  echo "   • Можно ограничить количество регистраций"
  echo ""
  
  read -p "Продолжить настройку токенной регистрации? (y/N): " confirm
  if [[ $confirm != [yY] ]]; then
    echo "Операция отменена"
    return 0
  fi
  
  if ! backup_config; then
    return 1
  fi
  
  sed -i 's/enable_registration: false/enable_registration: true/' "$HOMESERVER_CONFIG"
  sed -i 's/registration_requires_token: false/registration_requires_token: true/' "$HOMESERVER_CONFIG"
  
  echo "✅ Токенная регистрация включена"
  echo ""
  echo "📋 Управление токенами:"
  echo "   • Создание: используйте Synapse Admin или команды"
  echo "   • Просмотр: docker exec matrix-synapse synapse_review_recent_signups"
  echo ""
  
  restart_synapse
}

# Включить открытую регистрацию
set_registration_open() {
  echo "=== ОТКРЫТАЯ ПУБЛИЧНАЯ РЕГИСТРАЦИЯ ==="
  echo ""
  echo "🚨 ПРЕДУПРЕЖДЕНИЕ:"
  echo "   • Любой может зарегистрироваться на вашем сервере"
  echo "   • Риск спама и злоупотреблений"
  echo "   • Повышенная нагрузка на сервер"
  echo "   • Возможные правовые проблемы"
  echo ""
  echo "🛡️  Рекомендуется настроить:"
  echo "   • Rate limiting (ограничения скорости)"
  echo "   • CAPTCHA защиту"
  echo "   • Модерацию контента"
  echo ""
  
  read -p "ВЫ УВЕРЕНЫ? Введите 'OPEN' для подтверждения: " final_confirm
  
  if [ "$final_confirm" != "OPEN" ]; then
    echo "Операция отменена"
    return 0
  fi
  
  if ! backup_config; then
    return 1
  fi
  
  sed -i 's/enable_registration: false/enable_registration: true/' "$HOMESERVER_CONFIG"
  sed -i 's/registration_requires_token: true/registration_requires_token: false/' "$HOMESERVER_CONFIG"
  
  echo "✅ Открытая регистрация включена"
  echo ""
  echo "⚠️  ВАЖНО: Настройте дополнительные меры безопасности!"
  echo "   • Мониторинг новых регистраций"
  echo "   • Правила сообщества"
  echo "   • Модерацию контента"
  
  restart_synapse
}

# =============================================================================
# УПРАВЛЕНИЕ ТОКЕНАМИ РЕГИСТРАЦИИ
# =============================================================================

# Функция создания токена регистрации
create_registration_token() {
  echo "=== Создание токена регистрации ==="
  echo ""
  
  if ! docker ps | grep -q "matrix-synapse"; then
    echo "❌ Matrix Synapse не запущен"
    return 1
  fi
  
  read -p "Имя токена (для идентификации): " token_name
  read -p "Количество использований (0 = неограниченно): " token_uses
  read -p "Срок действия в днях (0 = бессрочно): " token_days
  
  # Валидация ввода
  if ! [[ "$token_uses" =~ ^[0-9]+$ ]]; then
    echo "❌ Количество использований должно быть числом"
    return 1
  fi
  
  if ! [[ "$token_days" =~ ^[0-9]+$ ]]; then
    echo "❌ Срок действия должен быть числом"
    return 1
  fi
  
  # Создание токена через Admin API
  local matrix_domain=$(grep "server_name:" "$HOMESERVER_CONFIG" | head -1 | sed 's/server_name: *"//' | sed 's/"//')
  local token_data="{\"uses_allowed\":$token_uses"
  
  if [ "$token_days" -gt 0 ]; then
    local expiry_time=$(($(date +%s) + $token_days * 86400))
    token_data="$token_data,\"expiry_time\":${expiry_time}000"
  fi
  
  token_data="$token_data}"
  
  echo "Создание токена..."
  
  # Создаем токен через SQL запрос в контейнере
  local token=$(openssl rand -hex 16)
  local sql_query="INSERT INTO registration_tokens (token, uses_allowed, pending, completed, expiry_time) VALUES ('$token', $token_uses, 0, 0, "
  
  if [ "$token_days" -gt 0 ]; then
    local expiry_ms=$(($(date +%s) * 1000 + $token_days * 86400000))
    sql_query="${sql_query}${expiry_ms});"
  else
    sql_query="${sql_query}NULL);"
  fi
  
  if docker exec matrix-postgres psql -U matrix -d matrix -c "$sql_query" >/dev/null 2>&1; then
    echo "✅ Токен регистрации создан:"
    echo ""
    echo "🎫 Токен: $token"
    echo "📝 Имя: $token_name"
    echo "🔢 Использований: $([ $token_uses -eq 0 ] && echo "неограниченно" || echo $token_uses)"
    echo "⏰ Срок действия: $([ $token_days -eq 0 ] && echo "бессрочно" || echo "$token_days дней")"
    echo ""
    echo "📋 Использование:"
    echo "   При регистрации в Element Web введите этот токен"
    echo "   Или используйте в API: ?access_token=$token"
    
    # Сохраняем информацию о токене
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $token_name | $token | $token_uses uses | $token_days days" >> "$BACKUP_DIR/registration_tokens.log"
    
  else
    echo "❌ Ошибка создания токена"
    return 1
  fi
}

# Функция просмотра токенов регистрации
list_registration_tokens() {
  echo "=== Токены регистрации ==="
  echo ""
  
  if ! docker ps | grep -q "matrix-synapse"; then
    echo "❌ Matrix Synapse не запущен"
    return 1
  fi
  
  local tokens=$(docker exec matrix-postgres psql -U matrix -d matrix -t -c "SELECT token, uses_allowed, pending, completed, expiry_time FROM registration_tokens ORDER BY expiry_time DESC;" 2>/dev/null)
  
  if [ -z "$tokens" ]; then
    echo "📋 Токены регистрации не найдены"
    echo ""
    echo "💡 Создайте токен с помощью функции 'Создать токен регистрации'"
    return 0
  fi
  
  echo "📋 Активные токены:"
  echo ""
  printf "%-20s %-12s %-8s %-8s %-15s\n" "ТОКЕН" "ИСПОЛЬЗОВАНИЙ" "ОЖИДАЕТ" "ЗАВЕРШЕНО" "ИСТЕКАЕТ"
  echo "--------------------------------------------------------------------------------"
  
  echo "$tokens" | while IFS='|' read -r token uses_allowed pending completed expiry_time; do
    # Очищаем пробелы
    token=$(echo "$token" | xargs)
    uses_allowed=$(echo "$uses_allowed" | xargs)
    pending=$(echo "$pending" | xargs)
    completed=$(echo "$completed" | xargs)
    expiry_time=$(echo "$expiry_time" | xargs)
    
    # Форматируем дату истечения
    if [ "$expiry_time" = "" ] || [ "$expiry_time" = "null" ]; then
      expiry_str="бессрочно"
    else
      expiry_str=$(date -d "@$((expiry_time / 1000))" "+%Y-%m-%d" 2>/dev/null || echo "ошибка даты")
    fi
    
    # Форматируем количество использований
    uses_str=$([ "$uses_allowed" = "null" ] && echo "∞" || echo "$uses_allowed")
    
    printf "%-20s %-12s %-8s %-8s %-15s\n" "${token:0:20}" "$uses_str" "$pending" "$completed" "$expiry_str"
  done
}

# Функция удаления токена регистрации
delete_registration_token() {
  echo "=== Удаление токена регистрации ==="
  echo ""
  
  if ! docker ps | grep -q "matrix-synapse"; then
    echo "❌ Matrix Synapse не запущен"
    return 1
  fi
  
  # Показываем список токенов
  list_registration_tokens
  echo ""
  
  read -p "Введите токен для удаления: " token_to_delete
  
  if [ -z "$token_to_delete" ]; then
    echo "❌ Токен не может быть пустым"
    return 1
  fi
  
  # Проверяем существование токена
  local token_exists=$(docker exec matrix-postgres psql -U matrix -d matrix -t -c "SELECT COUNT(*) FROM registration_tokens WHERE token='$token_to_delete';" 2>/dev/null | xargs)
  
  if [ "$token_exists" != "1" ]; then
    echo "❌ Токен не найден"
    return 1
  fi
  
  # Удаляем токен
  if docker exec matrix-postgres psql -U matrix -d matrix -c "DELETE FROM registration_tokens WHERE token='$token_to_delete';" >/dev/null 2>&1; then
    echo "✅ Токен удален: $token_to_delete"
  else
    echo "❌ Ошибка удаления токена"
    return 1
  fi
}

# =============================================================================
# ГЛАВНОЕ МЕНЮ И ОСНОВНЫЕ ФУНКЦИИ
# =============================================================================

# Функция показа информации о конфигурации
show_synapse_info() {
  echo "=== Информация о Matrix Synapse ==="
  echo ""
  
  if ! check_synapse_installation; then
    return 1
  fi
  
  local matrix_domain=$(grep "server_name:" "$HOMESERVER_CONFIG" | head -1 | sed 's/server_name: *"//' | sed 's/"//')
  local version=$(docker exec matrix-synapse python -m synapse.app.homeserver --version 2>/dev/null | head -1 || echo "неизвестно")
  
  echo "🏠 Сервер: $matrix_domain"
  echo "🐳 Контейнер: $(docker ps --filter 'name=matrix-synapse' --format '{{.Status}}')"
  echo "📦 Версия Synapse: $version"
  echo ""
  
  echo "🌐 ФЕДЕРАЦИЯ:"
  get_federation_status
  echo ""
  
  echo "👥 РЕГИСТРАЦИЯ:"
  get_registration_status
  echo ""
  
  echo "📁 Файлы конфигурации:"
  echo "   Основной: $HOMESERVER_CONFIG"
  echo "   Docker: $DOCKER_COMPOSE_CONFIG"
  echo "   Бэкапы: $BACKUP_DIR"
}

# Функция управления федерацией
manage_federation() {
  while true; do
    clear
    echo "=================================================================="
    echo "               Управление федерацией Matrix"
    echo "=================================================================="
    show_federation_domains
    echo ""
    echo "1. 🌐 Включить федерацию"
    echo "2. 🚫 Отключить федерацию"
    echo "3. ➕ Добавить домен"
    echo "4. ➖ Удалить домен"
    echo "5. 📋 Показать статус"
    echo "6. ⬅️  Назад"
    echo ""
    read -p "Выберите действие (1-6): " fed_choice
    
    case $fed_choice in
      1) enable_federation ;;
      2) disable_federation ;;
      3) add_federation_domain ;;
      4) remove_federation_domain ;;
      5) show_federation_domains ;;
      6) return 0 ;;
      *) echo "❌ Неверный выбор"; sleep 2 ;;
    esac
    
    if [ $fed_choice -ne 5 ]; then
      read -p "Нажмите Enter для продолжения..."
    fi
  done
}

# Функция управления регистрацией
manage_registration() {
  while true; do
    clear
    echo "=================================================================="
    echo "             Управление регистрацией пользователей"
    echo "=================================================================="
    show_registration_settings
    echo ""
    echo "1. ⚙️  Настроить режим регистрации"
    echo "2. 🎫 Создать токен регистрации"
    echo "3. 📋 Показать токены"
    echo "4. 🗑️  Удалить токен"
    echo "5. 👤 Создать пользователя (админ)"
    echo "6. 📊 Показать статус"
    echo "7. ⬅️  Назад"
    echo ""
    read -p "Выберите действие (1-7): " reg_choice
    
    case $reg_choice in
      1) configure_registration ;;
      2) create_registration_token ;;
      3) list_registration_tokens ;;
      4) delete_registration_token ;;
      5) create_admin_user_direct ;;
      6) show_registration_settings ;;
      7) return 0 ;;
      *) echo "❌ Неверный выбор"; sleep 2 ;;
    esac
    
    if [ $reg_choice -ne 6 ]; then
      read -p "Нажмите Enter для продолжения..."
    fi
  done
}

# Функция создания пользователя напрямую
create_admin_user_direct() {
  echo "=== Создание пользователя через shared secret ==="
  echo ""
  
  if ! docker ps | grep -q "matrix-synapse"; then
    echo "❌ Matrix Synapse не запущен"
    return 1
  fi
  
  read -p "Введите имя пользователя: " username
  read -p "Сделать администратором? (Y/n): " make_admin
  
  local admin_flag=""
  if [[ $make_admin != [nN] ]]; then
    admin_flag="--admin"
  fi
  
  echo "Создание пользователя..."
  docker exec -it matrix-synapse register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u "$username" \
    $admin_flag \
    http://localhost:8008
    
  if [ $? -eq 0 ]; then
    echo "✅ Пользователь @$username успешно создан"
  else
    echo "❌ Ошибка создания пользователя"
  fi
}

# Функция восстановления из резервной копии
restore_config() {
  echo "=== Восстановление конфигурации ==="
  echo ""
  
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "❌ Директория резервных копий не найдена: $BACKUP_DIR"
    return 1
  fi
  
  local backups=$(ls "$BACKUP_DIR"/homeserver_*.yaml 2>/dev/null | sort -r)
  
  if [ -z "$backups" ]; then
    echo "❌ Резервные копии не найдены"
    return 1
  fi
  
  echo "📋 Доступные резервные копии:"
  echo "$backups" | nl -w2 -s'. ' | sed 's|.*/||'
  echo ""
  
  read -p "Выберите номер резервной копии для восстановления: " backup_num
  
  local selected_backup=$(echo "$backups" | sed -n "${backup_num}p")
  
  if [ -z "$selected_backup" ]; then
    echo "❌ Неверный номер резервной копии"
    return 1
  fi
  
  echo "Восстановление из: $(basename "$selected_backup")"
  read -p "Продолжить? (y/N): " confirm
  
  if [[ $confirm != [yY] ]]; then
    echo "Операция отменена"
    return 0
  fi
  
  # Создаем резервную копию текущей конфигурации
  backup_config
  
  # Восстанавливаем из выбранной копии
  if cp "$selected_backup" "$HOMESERVER_CONFIG"; then
    echo "✅ Конфигурация восстановлена"
    restart_synapse
  else
    echo "❌ Ошибка восстановления"
    return 1
  fi
}

# Главное меню
show_main_menu() {
  clear
  echo "=================================================================="
  echo "            Matrix Synapse Management Module v1.0"
  echo "          Управление федерацией и регистрацией пользователей"
  echo "=================================================================="
  echo ""
  
  if check_synapse_installation >/dev/null 2>&1; then
    echo "✅ Matrix Synapse подключен и готов к управлению"
  else
    echo "❌ Matrix Synapse недоступен - проверьте установку"
  fi
  
  echo ""
  echo "1.  ℹ️  Информация о сервере"
  echo "2.  🌐 Управление федерацией"
  echo "3.  👥 Управление регистрацией"
  echo "4.  🎫 Быстрое создание токена"
  echo "5.  👤 Быстрое создание пользователя"
  echo "6.  📁 Резервное копирование конфигурации"
  echo "7.  🔄 Восстановление конфигурации"
  echo "8.  🔄 Перезапуск Synapse"
  echo "9.  ❌ Выход"
  echo "=================================================================="
}

# Основной цикл программы
main() {
  # Создаем директорию для резервных копий
  mkdir -p "$BACKUP_DIR"
  
  while true; do
    show_main_menu
    read -p "Выберите опцию (1-9): " choice
    
    case $choice in
      1) 
        show_synapse_info
        read -p "Нажмите Enter для продолжения..."
        ;;
      2) 
        if check_synapse_installation; then
          manage_federation
        else
          read -p "Нажмите Enter для продолжения..."
        fi
        ;;
      3) 
        if check_synapse_installation; then
          manage_registration
        else
          read -p "Нажмите Enter для продолжения..."
        fi
        ;;
      4) 
        if check_synapse_installation; then
          create_registration_token
        fi
        read -p "Нажмите Enter для продолжения..."
        ;;
      5) 
        if check_synapse_installation; then
          create_admin_user_direct
        fi
        read -p "Нажмите Enter для продолжения..."
        ;;
      6) 
        backup_config
        read -p "Нажмите Enter для продолжения..."
        ;;
      7) 
        restore_config
        read -p "Нажмите Enter для продолжения..."
        ;;
      8) 
        if check_synapse_installation; then
          restart_synapse
        fi
        read -p "Нажмите Enter для продолжения..."
        ;;
      9) 
        echo "👋 До свидания!"
        exit 0
        ;;
      *) 
        echo "❌ Неверный выбор. Попробуйте снова."
        sleep 2
        ;;
    esac
  done
}

# Запуск программы, если скрипт выполняется напрямую
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  main "$@"
fi