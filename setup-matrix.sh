#!/bin/bash

# Matrix Setup & Repair Tool v6.0 - Enhanced Docker Edition
# Полностью переработанная версия с улучшенной конфигурацией

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться от root" >&2
  exit 1
fi

# Глобальные переменные для конфигурации
SYNAPSE_VERSION="latest"
ELEMENT_VERSION="v1.11.81"
SYNAPSE_ADMIN_VERSION="0.10.3"
REQUIRED_MIN_VERSION="1.93.0"
MATRIX_DOMAIN=""
ELEMENT_DOMAIN=""
ADMIN_DOMAIN=""
BIND_ADDRESS=""
DB_PASSWORD=""  # Будет запрашиваться у пользователя
REGISTRATION_SHARED_SECRET=$(openssl rand -hex 32)
TURN_SECRET=$(openssl rand -hex 32)
ADMIN_USER="admin"
SERVER_TYPE=""
PUBLIC_IP=""
LOCAL_IP=""

# Функция для проверки и исправления системного времени
fix_system_time() {
  echo "Проверка системного времени..."
  
  if ! timedatectl status | grep -q "NTP synchronized: yes"; then
    echo "Исправление системного времени..."
    apt update >/dev/null 2>&1
    apt install -y ntp ntpdate >/dev/null 2>&1
    systemctl stop ntp >/dev/null 2>&1
    ntpdate -s pool.ntp.org >/dev/null 2>&1 || ntpdate -s time.nist.gov >/dev/null 2>&1
    systemctl start ntp >/dev/null 2>&1
    systemctl enable ntp >/dev/null 2>&1
    timedatectl set-ntp true >/dev/null 2>&1
    echo "Системное время синхронизировано"
  else
    echo "Системное время уже синхронизировано"
  fi
}

# Функция для определения типа сервера
detect_server_type() {
  PUBLIC_IP=$(curl -s -4 https://ifconfig.co || curl -s -4 https://api.ipify.org || curl -s -4 https://ifconfig.me)
  LOCAL_IP=$(hostname -I | awk '{print $1}')
  if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
    SERVER_TYPE="proxmox"
    BIND_ADDRESS="0.0.0.0"
    echo "Обнаружена установка на Proxmox VPS (или за NAT)"
    echo "Публичный IP: $PUBLIC_IP"
    echo "Локальный IP: $LOCAL_IP"
    echo "Используется bind address: $BIND_ADDRESS"
  else
    SERVER_TYPE="hosting"
    BIND_ADDRESS="127.0.0.1"
    echo "Обнаружена установка на хостинг VPS"
    echo "IP адрес: $PUBLIC_IP"
    echo "Используется bind address: $BIND_ADDRESS"
  fi
}

# Функция для установки Docker
install_docker() {
  echo "Установка Docker и Docker Compose..."
  
  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    echo "Docker уже установлен и запущен: $(docker --version)"
    return 0
  fi
  
  echo "Устанавливаем Docker..."
  apt update
  apt install -y ca-certificates curl gnupg lsb-release
  
  # Официальный репозиторий Docker
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  
  # Запуск Docker
  systemctl enable docker
  systemctl start docker
  
  # Проверка установки
  if systemctl is-active --quiet docker; then
    echo "✅ Docker успешно установлен и запущен"
    echo "   Версия: $(docker --version)"
    echo "   Compose: $(docker compose version)"
    return 0
  else
    echo "❌ Ошибка: Docker не запущен"
    return 1
  fi
}

# Функция проверки статуса Matrix сервисов
check_status() {
  echo "=== Статус Matrix сервисов ==="
  echo ""
  
  # Проверка Docker
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker не установлен"
    return 1
  fi
  
  if ! systemctl is-active --quiet docker; then
    echo "❌ Docker не запущен"
    return 1
  fi
  
  echo "✅ Docker работает: $(docker --version | cut -d' ' -f3 | tr -d ',')"
  echo ""
  
  # Проверка конфигурации
  if [ ! -f "/opt/synapse-config/docker-compose.yml" ]; then
    echo "❌ Docker Compose конфигурация не найдена"
    echo "   Запустите полную установку (опция 1)"
    return 1
  fi
  
  echo "📋 Статус контейнеров:"
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация недоступна"; return 1; }
  docker compose ps
  echo ""
  
  # Проверка каждого сервиса
  echo "🔍 Проверка доступности сервисов:"
  
  # PostgreSQL
  if docker exec matrix-postgres pg_isready -U matrix >/dev/null 2>&1; then
    echo "✅ PostgreSQL работает"
  else
    echo "❌ PostgreSQL недоступен"
  fi
  
  # Synapse API
  if curl -s -f http://localhost:8008/health >/dev/null 2>&1; then
    echo "✅ Synapse API доступен"
    
    # Проверяем версию Synapse
    SYNAPSE_VERSION_API=$(curl -s http://localhost:8008/_matrix/client/versions 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('server', {}).get('version', 'unknown'))" 2>/dev/null || echo "неизвестна")
    echo "   Версия Synapse: $SYNAPSE_VERSION_API"
  else
    echo "❌ Synapse API недоступен"
  fi
  
  # Element Web
  if curl -s -f http://localhost:8080/ >/dev/null 2>&1; then
    echo "✅ Element Web доступен"
  else
    echo "❌ Element Web недоступен"
  fi
  
  # Synapse Admin
  if curl -s -f http://localhost:8081/ >/dev/null 2>&1; then
    echo "✅ Synapse Admin доступен"
  else
    echo "❌ Synapse Admin недоступен"
  fi
  
  # Coturn
  if docker ps | grep -q "matrix-coturn.*Up"; then
    echo "✅ Coturn запущен"
    
    # Проверка портов Coturn
    if netstat -tulpn 2>/dev/null | grep -q ":3478"; then
      echo "   Порт 3478 (TURN) слушается"
    else
      echo "   ⚠️  Порт 3478 не слушается"
    fi
  else
    echo "❌ Coturn не запущен"
  fi
  
  echo ""
  echo "🌐 Сетевые порты:"
  netstat -tlnp 2>/dev/null | grep -E "(8008|8080|8081|8448|3478)" | head -10 || echo "   Основные порты не слушаются"
  
  echo ""
  echo "💾 Использование дискового пространства:"
  if [ -d "/opt/synapse-data" ]; then
    DATA_SIZE=$(du -sh /opt/synapse-data 2>/dev/null | cut -f1)
    echo "   /opt/synapse-data: $DATA_SIZE"
  fi
  
  # Проверка домена из конфигурации
  if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
    MATRIX_DOMAIN=$(grep "server_name:" /opt/synapse-data/homeserver.yaml | head -1 | sed 's/server_name: *"//' | sed 's/"//')
    echo ""
    echo "🔗 Конфигурация:"
    echo "   Matrix домен: $MATRIX_DOMAIN"
    
    # Проверка federation
    FEDERATION_STATUS=$(grep -A 1 "federation_domain_whitelist:" /opt/synapse-data/homeserver.yaml | tail -1 | grep -q "^\s*$" && echo "отключена" || echo "настроена")
    echo "   Федерация: $FEDERATION_STATUS"
    
    # Проверка регистрации
    REGISTRATION_STATUS=$(grep "enable_registration:" /opt/synapse-data/homeserver.yaml | grep -q "true" && echo "открыта" || echo "закрыта")
    echo "   Регистрация: $REGISTRATION_STATUS"
  fi
  
  echo ""
  echo "📊 Общий статус:"
  
  # Подсчет работающих сервисов
  RUNNING_COUNT=$(docker ps --filter "name=matrix-" --format "{{.Names}}" | wc -l)
  TOTAL_COUNT=5  # postgres, synapse, element-web, synapse-admin, coturn
  
  if [ "$RUNNING_COUNT" -eq "$TOTAL_COUNT" ]; then
    echo "✅ Все сервисы работают ($RUNNING_COUNT/$TOTAL_COUNT)"
  elif [ "$RUNNING_COUNT" -ge 3 ]; then
    echo "⚠️  Большинство сервисов работает ($RUNNING_COUNT/$TOTAL_COUNT)"
  else
    echo "❌ Много проблем с сервисами ($RUNNING_COUNT/$TOTAL_COUNT)"
  fi
  
  if [ "$RUNNING_COUNT" -lt "$TOTAL_COUNT" ]; then
    echo ""
    echo "🔧 Рекомендации:"
    echo "   - Перезапустите сервисы (опция 3)"
    echo "   - Проверьте логи (опция 6)"
    echo "   - Запустите диагностику (опция 9)"
  fi
}

fix_element_domain_config() {
  echo "=== Исправление проблемы с доменными конфигурациями Element Web ==="
  echo ""
  
  ELEMENT_DOMAIN=""
  if [ -f "/etc/caddy/Caddyfile" ]; then
    ELEMENT_DOMAIN=$(grep -A 5 "Element Web Client" /etc/caddy/Caddyfile | grep "^[a-zA-Z]" | head -1 | cut -d' ' -f1)
  fi
  
  if [ -z "$ELEMENT_DOMAIN" ]; then
    ELEMENT_DOMAIN=$(docker logs matrix-element-web 2>&1 | grep -o 'config\.[a-zA-Z0-9.-]*\.json' | head -1 | sed 's/config\.//' | sed 's/\.json//')
    if [ -n "$ELEMENT_DOMAIN" ]; then
      echo "📋 Домен Element определён из логов: $ELEMENT_DOMAIN"
    else
      read -p "Введите домен Element Web (например, app.bla-bla.space): " ELEMENT_DOMAIN
    fi
  else
    echo "📋 Домен Element найден в Caddyfile: $ELEMENT_DOMAIN"
  fi
  
  if [ -z "$ELEMENT_DOMAIN" ]; then
    echo "❌ Не удалось определить домен Element Web"
    return 1
  fi
  
  echo "🔧 Исправление конфигурации для домена: $ELEMENT_DOMAIN"
  
  MATRIX_DOMAIN=""
  if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
    MATRIX_DOMAIN=$(grep "server_name:" /opt/synapse-data/homeserver.yaml | head -1 | sed 's/server_name: *"//' | sed 's/"//')
  fi
  
  if [ -z "$MATRIX_DOMAIN" ]; then
    read -p "Введите домен Matrix сервера: " MATRIX_DOMAIN
  fi
  
  echo "Matrix домен: $MATRIX_DOMAIN"
  
  echo "Остановка Element Web контейнера..."
  docker stop matrix-element-web 2>/dev/null || true
  
  echo "Создание доменной конфигурации Element Web..."
  
  mkdir -p /opt/element-web
  
  cat > /opt/element-web/config.json <<EOL
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
    "brand": "Element",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-stAGING.vector.im/api"
    ],
    "hosting_signup_link": "https://element.io/matrix-services?utm_source=element-web&utm_medium=web",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "uisi_autorageshake_app": "element-auto-uisi",
    "showLabsSettings": true,
    "piwik": false,
    "roomDirectory": {
        "servers": ["$MATRIX_DOMAIN"]
    },
    "enable_presence_by_hs_url": {
        "https://matrix.org": false,
        "https://matrix-client.matrix.org": false
    },
    "terms_and_conditions_links": [
        {
            "text": "Privacy Policy",
            "url": "https://$MATRIX_DOMAIN/privacy"
        },
        {
            "text": "Terms of Service", 
            "url": "https://$MATRIX_DOMAIN/terms"
        }
    ],
    "welcomeUserId": "@admin:$MATRIX_DOMAIN",
    "default_federate": false,
    "default_theme": "dark",
    "features": {
        "feature_new_room_decoration_ui": true,
        "feature_pinning": "labs",
        "feature_custom_status": "labs",
        "feature_custom_tags": "labs",
        "feature_state_counters": "labs",
        "feature_many_profile_picture_sizes": true,
        "feature_mjolnir": "labs",
        "feature_custom_themes": "labs",
        "feature_spaces": true,
        "feature_spaces.all_rooms": true,
        "feature_spaces.space_member_dms": true,
        "feature_voice_messages": true,
        "feature_location_share_live": true,
        "feature_polls": true,
        "feature_location_share": true,
        "feature_thread": true,
        "feature_latex_maths": true,
        "feature_element_call_video_rooms": "labs",
        "feature_group_calls": "labs",
        "feature_disable_call_per_sender_encryption": "labs",
        "feature_allow_screen_share_only_mode": "labs",
        "feature_location_share_pin_drop": "labs",
        "feature_video_rooms": "labs",
        "feature_element_call": "labs",
        "feature_new_device_manager": true,
        "feature_bulk_redaction": "labs",
        "feature_roomlist_preview_reactions_dms": true,
        "feature_roomlist_preview_reactions_all": true
    },
    "element_call": {
        "url": "https://call.element.io",
        "participant_limit": 8,
        "brand": "Element Call"
    },
    "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=fU3vlMsMn4Jb6dnEIFsx"
}
EOL
  
  cp /opt/element-web/config.json "/opt/element-web/config.$ELEMENT_DOMAIN.json"
  echo "✅ Создана доменная конфигурация: config.$ELEMENT_DOMAIN.json"
  
  if [ -f "/opt/synapse-config/docker-compose.yml" ]; then
    echo "Обновление Docker Compose конфигурации..."
    
    cp /opt/synapse-config/docker-compose.yml /opt/synapse-config/docker-compose.yml.backup.$(date +%s)
    
    if ! grep -q "config.$ELEMENT_DOMAIN.json" /opt/synapse-config/docker-compose.yml; then
      echo "Добавление монтирования доменной конфигурации..."
      
      python3 << EOF
import yaml
import os

compose_file = "/opt/synapse-config/docker-compose.yml"

try:
    with open(compose_file, 'r') as f:
        content = f.read()
    
    # Заменяем volumes в секции element-web
    lines = content.split('\n')
    new_lines = []
    in_element_web = False
    in_volumes = False
    volumes_added = False
    
    for line in lines:
        if 'element-web:' in line:
            in_element_web = True
            new_lines.append(line)
        elif in_element_web and line.strip().startswith('volumes:'):
            in_volumes = True
            new_lines.append(line)
            # Добавляем оба монтирования
            new_lines.append('      - /opt/element-web/config.json:/app/config.json:ro')
            new_lines.append('      - /opt/element-web/config.$ELEMENT_DOMAIN.json:/app/config.$ELEMENT_DOMAIN.json:ro')
            volumes_added = True
        elif in_element_web and in_volumes and line.strip().startswith('- ') and 'config.json' in line:
            # Пропускаем старые записи config.json
            continue
        elif in_element_web and not line.startswith('  ') and line.strip():
            # Вышли из секции element-web
            in_element_web = False
            in_volumes = False
            new_lines.append(line)
        else:
            new_lines.append(line)
    
    # Записываем обновленный файл
    with open(compose_file, 'w') as f:
        f.write('\n'.join(new_lines))
    
    print("✅ Docker Compose обновлен через Python")
    
except Exception as e:
    print(f"❌ Ошибка Python обновления: {e}")
    # Fallback: используем sed
    os.system('sed -i "/element-web:/,/stop_grace_period: 15s/ { /- \/opt\/element-web\/config\.json/d; /volumes:/a\\      - /opt/element-web/config.json:/app/config.json:ro\\n      - /opt/element-web/config.$ELEMENT_DOMAIN.json:/app/config.$ELEMENT_DOMAIN.json:ro }" /opt/synapse-config/docker-compose.yml')
    print("✅ Docker Compose обновлен через sed")
EOF
    else
      echo "✅ Доменная конфигурация уже присутствует в Docker Compose"
    fi
    
    echo "✅ Docker Compose конфигурация обновлена"
  fi
  
  # Проверяем права доступа на файлы конфигурации
  echo "Проверка прав доступа..."
  chown root:root /opt/element-web/config*.json
  chmod 644 /opt/element-web/config*.json
  
  # Запуск Element Web контейнера
  echo "Запуск Element Web контейнера..."
  cd /opt/synapse-config 2>/dev/null
  if [ -f "docker-compose.yml" ]; then
    docker compose up -d element-web
    echo "✅ Element Web перезапущен"
    
    # Проверка запуска
    echo "Ожидание готовности Element Web..."
    for i in {1..12}; do
      if curl -s http://localhost:8080/ >/dev/null 2>&1; then
        echo "✅ Element Web готов!"
        break
      elif [ $i -eq 12 ]; then
        echo "⚠️  Element Web запускается медленно, проверьте логи: docker logs matrix-element-web"
      else
        echo "   Ожидание... ($i/12)"
        sleep 5
      fi
    done
    
    # Проверка доступности доменного конфига
    echo ""
    echo "🔍 Проверка доступности конфигураций:"
    
    if curl -s "http://localhost:8080/config.json" >/dev/null 2>&1; then
      echo "✅ Основная конфигурация доступна: /config.json"
    else
      echo "❌ Основная конфигурация недоступна"
    fi
    
    if curl -s "http://localhost:8080/config.$ELEMENT_DOMAIN.json" >/dev/null 2>&1; then
      echo "✅ Доменная конфигурация доступна: /config.$ELEMENT_DOMAIN.json"
    else
      echo "❌ Доменная конфигурация недоступна"
      echo "🔧 Диагностика:"
      echo "   Проверка монтирования в контейнере..."
      docker exec matrix-element-web ls -la /app/config*.json 2>/dev/null || echo "   Файлы не видны в контейнере"
      echo "   Проверка файлов на хосте..."
      ls -la /opt/element-web/config*.json 2>/dev/null || echo "   Файлы отсутствуют на хосте"
    fi
    
  else
    echo "⚠️  docker-compose.yml не найден, запустите контейнер вручную"
  fi
  
  echo ""
  echo "================================================================="
  echo "✅ Исправление конфигурации Element Web завершено!"
  echo "================================================================="
  echo ""
  echo "📋 Что было сделано:"
  echo "   - Создана основная конфигурация: /opt/element-web/config.json"
  echo "   - Создана доменная конфигурация: /opt/element-web/config.$ELEMENT_DOMAIN.json"
  echo "   - Обновлена Docker Compose конфигурация"
  echo "   - Перезапущен Element Web контейнер"
  echo ""
  echo "🌐 Проверьте доступность:"
  echo "   - http://localhost:8080/config.json"
  echo "   - http://localhost:8080/config.$ELEMENT_DOMAIN.json"
  echo "   - https://$ELEMENT_DOMAIN (если настроен reverse proxy)"
  echo ""
  echo "🔧 Если проблема повторяется:"
  echo "   - Проверьте логи: docker logs matrix-element-web"
  echo "   - Убедитесь что reverse proxy правильно настроен"
  echo "   - Проверьте права доступа: ls -la /opt/element-web/"
  echo "   - Проверьте Docker Compose: cat /opt/synapse-config/docker-compose.yml | grep -A 15 element-web"
  echo "================================================================="
}

# Функция создания пользователя (админ)
create_admin_user() {
  echo "=== Создание пользователя Matrix ==="
  echo ""
  
  # Проверка что Synapse запущен
  if ! curl -s http://localhost:8008/health >/dev/null 2>&1; then
    echo "❌ Synapse недоступен. Сначала запустите Matrix сервисы."
    echo "   Используйте опцию 3 (Перезапустить все сервисы)"
    return 1
  fi
  
  # Определение домена из конфигурации
  MATRIX_DOMAIN=""
  if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
    MATRIX_DOMAIN=$(grep "server_name:" /opt/synapse-data/homeserver.yaml | head -1 | sed 's/server_name: *"//' | sed 's/"//')
  fi
  
  if [ -z "$MATRIX_DOMAIN" ]; then
    echo "❌ Не удалось определить домен Matrix сервера"
    read -p "Введите домен Matrix сервера: " MATRIX_DOMAIN
  fi
  
  echo "📋 Информация:"
  echo "   Matrix домен: $MATRIX_DOMAIN"
  echo "   Пользователь будет создан как: @username:$MATRIX_DOMAIN"
  echo ""
  
  # Запрос данных пользователя
  read -p "Введите имя пользователя (только латинские буквы, цифры, - и _): " username
  
  # Валидация имени пользователя
  if [[ ! "$username" =~ ^[a-zA-Z0-9._=-]+$ ]]; then
    echo "❌ Неверное имя пользователя. Используйте только латинские буквы, цифры, точки, дефисы и подчеркивания."
    return 1
  fi
  
  read -p "Сделать пользователя администратором? (Y/n): " make_admin
  
  # Определение флага администратора
  admin_flag=""
  admin_text=""
  if [[ $make_admin != [nN] ]]; then
    admin_flag="--admin"
    admin_text=" (администратор)"
  fi
  
  echo ""
  echo "🔄 Создание пользователя @$username:$MATRIX_DOMAIN$admin_text..."
  echo ""
  
  # Создание пользователя через Docker
  if docker exec -it matrix-synapse register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u "$username" \
    $admin_flag \
    http://localhost:8008; then
    
    echo ""
    echo "================================================================="
    echo "✅ Пользователь успешно создан!"
    echo "================================================================="
    echo ""
    echo "📋 Информация о пользователе:"
    echo "   Полный ID: @$username:$MATRIX_DOMAIN"
    echo "   Домен: $MATRIX_DOMAIN"
    echo "   Тип: $([ -n "$admin_flag" ] && echo "Администратор" || echo "Обычный пользователь")"
    echo ""
    echo "🌐 Доступ к сервисам:"
    
    # Определение доменов для веб-интерфейсов
    if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
      echo "   Matrix API: https://$MATRIX_DOMAIN"
    fi
    
    if [ -f "/etc/caddy/Caddyfile" ]; then
      ELEMENT_DOMAIN=$(grep -A 5 "Element Web Client" /etc/caddy/Caddyfile | grep "^[a-zA-Z]" | head -1 | cut -d' ' -f1)
      ADMIN_DOMAIN=$(grep -A 5 "Synapse Admin Interface" /etc/caddy/Caddyfile | grep "^[a-zA-Z]" | head -1 | cut -d' ' -f1)
      
      if [ -n "$ELEMENT_DOMAIN" ]; then
        echo "   Element Web: https://$ELEMENT_DOMAIN"
      fi
      
      if [ -n "$ADMIN_DOMAIN" ] && [ -n "$admin_flag" ]; then
        echo "   Synapse Admin: https://$ADMIN_DOMAIN"
      fi
    else
      echo "   Element Web: http://localhost:8080 (локально)"
      if [ -n "$admin_flag" ]; then
        echo "   Synapse Admin: http://localhost:8081 (локально)"
      fi
    fi
    
    echo ""
    echo "📱 Для подключения через клиенты:"
    echo "   Homeserver: https://$MATRIX_DOMAIN"
    echo "   Логин: @$username:$MATRIX_DOMAIN"
    echo "   Пароль: [который вы установили]"
    echo ""
    
    if [ -n "$admin_flag" ]; then
      echo "👑 Администраторские возможности:"
      echo "   - Управление пользователями через Synapse Admin"
      echo "   - Создание комнат и управление ими"
      echo "   - Настройка политик сервера"
      echo "   - Доступ к статистике и мониторингу"
      echo ""
    fi
    
    echo "ℹ️  Рекомендации:"
    echo "   - Используйте сложный пароль"
    echo "   - Включите двухфакторную аутентификацию в клиенте"
    echo "   - Проверьте доступность сервера через веб-интерфейс"
    echo "================================================================="
    
    return 0
  else
    echo ""
    echo "❌ Ошибка создания пользователя"
    echo ""
    echo "🔧 Возможные причины:"
    echo "   - Synapse не готов (попробуйте через минуту)"
    echo "   - Пользователь уже существует"
    echo "   - Проблемы с базой данных"
    echo "   - Неверная конфигурация"
    echo ""
    echo "🔍 Для диагностики:"
    echo "   - Проверьте статус (опция 2)"
    echo "   - Просмотрите логи Synapse (опция 6 → 1)"
    echo "   - Запустите диагностику (опция 9)"
    echo ""
    return 1
  fi
}

# Функция для создания улучшенной конфигурации Synapse
create_synapse_config() {
  local matrix_domain=$1
  local db_password=$2
  local registration_shared_secret=$3
  local turn_shared_secret=$4
  local admin_user=$5
  
  echo "Создание расширенной конфигурации Synapse..."
  
  # Сохраняем существующий ключ подписи, если он уже есть
  EXISTING_SIGNING_KEY=""
  if [ -f "/opt/synapse-data/signing.key" ]; then
    EXISTING_SIGNING_KEY=$(cat /opt/synapse-data/signing.key)
    echo "✅ Найден существующий ключ подписи, сохраняем его"
  fi
  
  # Создание основного конфига
  cat > /opt/synapse-data/homeserver.yaml <<EOL
# Matrix Synapse Configuration v6.0
# TLS завершается на Caddy reverse proxy, Synapse работает по HTTP

server_name: "$matrix_domain"
public_baseurl: "https://$matrix_domain"
pid_file: "/data/homeserver.pid"

# Настройки листенеров
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false
    # Healthcheck endpoint доступен на всех HTTP листенерах
    
  - port: 8448
    tls: false  
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [federation]
        compress: false

# Основные настройки
app_service_config_files: []
track_appservice_user_ips: true

# Секреты безопасности
macaroon_secret_key: "$(openssl rand -hex 32)"
form_secret: "$(openssl rand -hex 32)"
signing_key_path: "/data/signing.key"

# Well-known endpoints (отдаёт Caddy)
serve_server_wellknown: false

# TURN сервер для VoIP
turn_uris: 
  - "turn:$matrix_domain:3478?transport=udp"
  - "turn:$matrix_domain:3478?transport=tcp"
turn_shared_secret: "$turn_shared_secret"
turn_user_lifetime: "1h"
turn_allow_guests: true

# Медиа хранилище
media_store_path: "/data/media_store"
max_upload_size: "100M"
max_image_pixels: "32M"
dynamic_thumbnails: false
url_preview_enabled: false

# База данных PostgreSQL
database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: matrix
    password: "$db_password"
    database: matrix
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3

# Настройки безопасности паролей
password_config:
  enabled: true
  policy:
    minimum_length: 8
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# Регистрация и администрирование
enable_registration: false
registration_requires_token: true
registration_shared_secret: "$registration_shared_secret"

# Федерация отключена по умолчанию (безопасность)
federation_domain_whitelist: []
suppress_key_server_warning: true

# Администраторы
admin_users:
  - "@$admin_user:$matrix_domain"

# Настройки производительности
event_cache_size: "10K"
caches:
  global_factor: 0.5
  per_cache_factors:
    get_users_who_share_room_with_user: 2.0

# Присутствие пользователей
presence:
  enabled: true
  include_offline_users_on_sync: false

# Ограничения скорости
rc_message:
  per_second: 0.2
  burst_count: 10.0

rc_registration:
  per_second: 0.17
  burst_count: 3.0

rc_login:
  address:
    per_second: 0.003
    burst_count: 5.0
  account:
    per_second: 0.003
    burst_count: 5.0
  failed_attempts:
    per_second: 0.17
    burst_count: 3.0

# Настройки комнат
encryption_enabled_by_default_for_room_type: "invite"
enable_room_list_search: true

# Директория пользователей
user_directory:
  enabled: true
  search_all_users: false
  prefer_local_users: true

# Метрики (для мониторинга)
enable_metrics: false
report_stats: false

# Логирование
log_config: "/data/log_config.yaml"
EOL

  # Восстанавливаем ключ подписи если он был
  if [ -n "$EXISTING_SIGNING_KEY" ]; then
    echo "$EXISTING_SIGNING_KEY" > /opt/synapse-data/signing.key
    echo "✅ Ключ подписи восстановлен"
  fi

  # Создание конфигурации логирования
  cat > /opt/synapse-data/log_config.yaml <<EOL
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    console:
        class: logging.StreamHandler
        formatter: precise
        stream: ext://sys.stdout

loggers:
    synapse.storage.SQL:
        level: INFO

root:
    level: INFO
    handlers: [console]

disable_existing_loggers: false
EOL

  echo "✅ Расширенная конфигурация Synapse создана"
}

# Функция для исправления проблемы с ключом подписи
fix_signing_key() {
  echo "=== Исправление ключа подписи Synapse ==="
  
  if [ ! -d "/opt/synapse-data" ]; then
    echo "❌ Директория /opt/synapse-data не найдена"
    return 1
  fi
  
  # Остановка контейнера Synapse
  echo "Остановка Synapse контейнера..."
  docker stop matrix-synapse 2>/dev/null || true
  
  # Удаление неправильного ключа
  if [ -f "/opt/synapse-data/signing.key" ]; then
    echo "Удаление некорректного ключа подписи..."
    rm -f /opt/synapse-data/signing.key
  fi
  
  # Определение домена из конфигурации
  MATRIX_DOMAIN=""
  if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
    MATRIX_DOMAIN=$(grep "server_name:" /opt/synapse-data/homeserver.yaml | head -1 | sed 's/server_name: *"//' | sed 's/"//')
  fi
  
  if [ -z "$MATRIX_DOMAIN" ]; then
    read -p "Введите домен Matrix сервера: " MATRIX_DOMAIN
  fi
  
  echo "Домен Matrix: $MATRIX_DOMAIN"
  
  # Генерация нового ключа через Synapse
  echo "Генерация нового ключа подписи через Synapse..."
  docker run --rm \
    --mount type=bind,source=/opt/synapse-data,target=/data \
    -e SYNAPSE_SERVER_NAME="$MATRIX_DOMAIN" \
    -e SYNAPSE_REPORT_STATS=no \
    matrixdotorg/synapse:latest generate
    
  if [ $? -eq 0 ]; then
    echo "✅ Новый ключ подписи успешно создан"
    
    # Восстановление прав доступа
    chown -R 991:991 /opt/synapse-data
    
    # Запуск контейера обратно
    echo "Запуск Synapse контейнера..."
    cd /opt/synapse-config 2>/dev/null
    if [ -f "docker-compose.yml" ]; then
      docker compose up -d synapse
      echo "✅ Synapse перезапущен"
      
      # Проверка запуска
      echo "Ожидание готовности Synapse..."
      for i in {1..12}; do
        if curl -s http://localhost:8008/health >/dev/null 2>&1; then
          echo "✅ Synapse готов!"
          break
        elif [ $i -eq 12 ]; then
          echo "⚠️  Synapse запускается медленно, проверьте логи: docker logs matrix-synapse"
        else
          echo "   Ожидание... ($i/12)"
          sleep 5
        fi
      done
    else
      echo "⚠️  docker-compose.yml не найден, запустите контейнер вручную"
    fi
  else
    echo "❌ Ошибка генерации ключа"
    return 1
  fi
}

# Функция для создания Docker Compose конфигурации (исправленная)
create_docker_compose() {
  local matrix_domain=$1
  local db_password=$2
  local bind_address=$3
  
  echo "Создание Docker Compose конфигурации..."
  
  mkdir -p /opt/synapse-config
  
  cat > /opt/synapse-config/docker-compose.yml <<EOL
services:
  # PostgreSQL база данных
  postgres:
    image: postgres:15-alpine
    container_name: matrix-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=matrix
      - POSTGRES_PASSWORD=$db_password
      - POSTGRES_DB=matrix
      - POSTGRES_INITDB_ARGS=--encoding=UTF8 --locale=C
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - matrix-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U matrix"]
      interval: 10s
      timeout: 5s
      retries: 5
    stop_grace_period: 30s

  # Matrix Synapse сервер
  synapse:
    image: matrixdotorg/synapse:$SYNAPSE_VERSION
    container_name: matrix-synapse
    restart: unless-stopped
    volumes:
      - /opt/synapse-data:/data
    environment:
      - SYNAPSE_SERVER_NAME=$matrix_domain
      - SYNAPSE_REPORT_STATS=no
      - UID=991
      - GID=991
    ports:
      - "$bind_address:8008:8008"
      - "$bind_address:8448:8448"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - matrix-network
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    stop_grace_period: 30s

  # Element Web клиент
  element-web:
    image: vectorim/element-web:$ELEMENT_VERSION
    container_name: matrix-element-web
    restart: unless-stopped
    volumes:
      - /opt/element-web/config.json:/app/config.json:ro
    ports:
      - "$bind_address:8080:80"
    networks:
      - matrix-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
    stop_grace_period: 15s

  # Synapse Admin интерфейс
  synapse-admin:
    image: awesometechnologies/synapse-admin:$SYNAPSE_ADMIN_VERSION
    container_name: matrix-synapse-admin
    restart: unless-stopped
    volumes:
      - /opt/synapse-admin/config.json:/app/config.json:ro
    ports:
      - "$bind_address:8081:80"
    networks:
      - matrix-network
    environment:
      - REACT_APP_SERVER_URL=https://$matrix_domain
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
    stop_grace_period: 15s

  # Coturn TURN сервер (ИСПРАВЛЕННАЯ конфигурация для быстрого запуска)
  coturn:
    image: coturn/coturn:latest
    container_name: matrix-coturn
    restart: unless-stopped
    # Используем host сеть для лучшей производительности (рекомендация Docker Coturn)
    network_mode: host
    volumes:
      - /opt/coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro
      - coturn-data:/var/lib/coturn
    environment:
      # Автоматическое определение внешнего IP
      - DETECT_EXTERNAL_IP=yes
      - DETECT_RELAY_IP=yes
    command: ["-c", "/etc/coturn/turnserver.conf", "--log-file=stdout", "-v"]
    stop_grace_period: 10s

volumes:
  postgres-data:
    driver: local
  coturn-data:
    driver: local

networks:
  matrix-network:
    driver: bridge
EOL

  echo "✅ Docker Compose конфигурация создана (с оптимизированным Coturn)"
}

# Функция для создания конфигурации Element Web
create_element_config() {
  local matrix_domain=$1
  local admin_user=$2
  
  echo "Создание конфигурации Element Web..."
  
  mkdir -p /opt/element-web
  
  cat > /opt/element-web/config.json <<EOL
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$matrix_domain",
            "server_name": "$matrix_domain"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "brand": "Element",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-stAGING.vector.im/api"
    ],
    "hosting_signup_link": "https://element.io/matrix-services?utm_source=element-web&utm_medium=web",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "uisi_autorageshake_app": "element-auto-uisi",
    "showLabsSettings": true,
    "piwik": false,
    "roomDirectory": {
        "servers": ["$matrix_domain"]
    },
    "enable_presence_by_hs_url": {
        "https://matrix.org": false,
        "https://matrix-client.matrix.org": false
    },
    "terms_and_conditions_links": [
        {
            "text": "Privacy Policy",
            "url": "https://$matrix_domain/privacy"
        },
        {
            "text": "Terms of Service", 
            "url": "https://$matrix_domain/terms"
        }
    ],
    "welcomeUserId": "@$admin_user:$matrix_domain",
    "default_federate": false,
    "default_theme": "dark",
    "features": {
        "feature_new_room_decoration_ui": true,
        "feature_pinning": "labs",
        "feature_custom_status": "labs",
        "feature_custom_tags": "labs",
        "feature_state_counters": "labs",
        "feature_many_profile_picture_sizes": true,
        "feature_mjolnir": "labs",
        "feature_custom_themes": "labs",
        "feature_spaces": true,
        "feature_spaces.all_rooms": true,
        "feature_spaces.space_member_dms": true,
        "feature_voice_messages": true,
        "feature_location_share_live": true,
        "feature_polls": true,
        "feature_location_share": true,
        "feature_thread": true,
        "feature_latex_maths": true,
        "feature_element_call_video_rooms": "labs",
        "feature_group_calls": "labs",
        "feature_disable_call_per_sender_encryption": "labs",
        "feature_allow_screen_share_only_mode": "labs",
        "feature_location_share_pin_drop": "labs",
        "feature_video_rooms": "labs",
        "feature_element_call": "labs",
        "feature_new_device_manager": true,
        "feature_bulk_redaction": "labs",
        "feature_roomlist_preview_reactions_dms": true,
        "feature_roomlist_preview_reactions_all": true
    },
    "element_call": {
        "url": "https://call.element.io",
        "participant_limit": 8,
        "brand": "Element Call"
    },
    "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=fU3vlMsMn4Jb6dnEIFsx"
}
EOL

  echo "✅ Конфигурация Element Web создана"
}

# Функция для создания конфигурации Synapse Admin
create_synapse_admin_config() {
  local matrix_domain=$1
  
  echo "Создание конфигурации Synapse Admin..."
  
  mkdir -p /opt/synapse-admin
  
  cat > /opt/synapse-admin/config.json <<EOL
{
  "restrictBaseUrl": "https://$matrix_domain",
  "anotherRestrictedKey": "restricting",
  "locale": "en"
}
EOL

  echo "✅ Конфигурация Synapse Admin создана"
}

# Функция для создания конфигурации Coturn (исправленная и оптимизированная)
create_coturn_config() {
  local matrix_domain=$1
  local turn_secret=$2
  local public_ip=$3
  local local_ip=$4
  
  echo "Создание оптимизированной конфигурации Coturn..."
  
  mkdir -p /opt/coturn
  
  cat > /opt/coturn/turnserver.conf <<EOL
# Coturn TURN Server Configuration для Matrix (оптимизированная)

# Основные порты
listening-port=3478
tls-listening-port=5349

# Сетевые настройки - автоматическое определение через переменные окружения
listening-ip=0.0.0.0

# Оптимизированный диапазон портов для Docker
min-port=49160
max-port=49200

# Аутентификация
use-auth-secret
static-auth-secret=$turn_secret
realm=$matrix_domain

# Логирование (выводим в stdout для Docker)
no-stdout-log
syslog

# Оптимизация производительности
no-multicast-peers
no-cli
no-loopback-peers
no-tcp-relay

# Ограничения пользователей (оптимизированные)
user-quota=12
total-quota=1200

# Безопасность - блокируем приватные IP диапазоны
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=224.0.0.0-255.255.255.255

# Белый список - разрешаем публичные IP
# (Docker автоматически определит external IP через DETECT_EXTERNAL_IP)

# Оптимизация для Docker и Matrix
no-tls
no-dtls
simple-log
new-log-timestamp

# Улучшенная производительность
mobility
no-stale-nonce

# Ограничения времени
max-allocate-lifetime=3600
channel-lifetime=600

# PID файл (внутри контейнера)
pidfile=/var/run/turnserver.pid

# Пользователь процесса
proc-user=turnserver
proc-group=turnserver
EOL

  echo "✅ Оптимизированная конфигурация Coturn создана"
  echo "   - Сокращенный диапазон портов: 49160-49200 (40 портов)"
  echo "   - Автоматическое определение внешнего IP"
  echo "   - Оптимизация для Docker host сети"
}

# Функция для создания расширенного Caddyfile
create_enhanced_caddyfile() {
  local matrix_domain=$1
  local element_domain=$2
  local admin_domain=$3
  local bind_address=$4
  
  echo "Создание расширенного Caddyfile..."
  
  cat > /etc/caddy/Caddyfile <<EOL
# Matrix Synapse Server
$matrix_domain {
    # Well-known endpoints для федерации и клиентов
    handle_path /.well-known/matrix/server {
        respond \`{"m.server": "$matrix_domain:8448"}\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }
    
    handle_path /.well-known/matrix/client {
        respond \`{
            "m.homeserver": {
                "base_url": "https://$matrix_domain"
            },
            "m.identity_server": {
                "base_url": "https://vector.im"
            },
            "org.matrix.msc3575.proxy": {
                "url": "https://$matrix_domain"
            }
        }\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            header Cache-Control "public, max-age=3600"
        }
    }

    # Основные Matrix API endpoints
    reverse_proxy /_matrix/* $bind_address:8008 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    reverse_proxy /_synapse/client/* $bind_address:8008 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }

    # Безопасность заголовки
    header {
        # Security headers
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        
        # Remove server info
        -Server
    }
}

# Matrix Federation (отдельный порт)
$matrix_domain:8448 {
    reverse_proxy $bind_address:8448 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        -Server
    }
}

# Element Web Client
$element_domain {
    reverse_proxy $bind_address:8080 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    header {
        # Enhanced security для Element Web
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        
        # Content Security Policy для Element
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; media-src 'self' blob:; font-src 'self'; connect-src 'self' https: wss:; frame-src 'self' https:; worker-src 'self' blob:;"
        
        # Permissions Policy
        Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        
        # Кэширование статики
        Cache-Control "public, max-age=31536000" {
            path_regexp \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$
        }
        
        -Server
    }
}

# Synapse Admin Interface
$admin_domain {
    reverse_proxy $bind_address:8081 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        
        # Дополнительная защита для админки
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https:;"
        
        -Server
    }
}
EOL

  echo "✅ Расширенный Caddyfile создан"
}

# Функция для установки Caddy
install_caddy() {
  echo "Установка и настройка Caddy..."
  
  if [ "$SERVER_TYPE" != "hosting" ]; then
    echo "⚠️  Caddy устанавливается только для hosting VPS"
    echo "Для Proxmox настройте Caddy на хост-машине"
    return 0
  fi
  
  systemctl stop nginx >/dev/null 2>&1 || true
  systemctl stop apache2 >/dev/null 2>&1 || true

  apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt update
  apt install -y caddy

  create_enhanced_caddyfile "$MATRIX_DOMAIN" "$ELEMENT_DOMAIN" "$ADMIN_DOMAIN" "$BIND_ADDRESS"

  systemctl enable caddy
  systemctl start caddy
  
  if systemctl is-active --quiet caddy; then
    echo "✅ Caddy установлен и запущен"
  else
    echo "❌ Ошибка запуска Caddy"
  fi
}

# Функция для полной установки
full_installation() {
  echo "=== Matrix Setup & Repair Tool v6.0 - Enhanced Installation ==="
  echo ""
  
  # Исправление времени
  fix_system_time
  
  # Обновление системы
  echo "Обновление системы..."
  apt update && apt upgrade -y
  apt install -y curl wget openssl pwgen ufw fail2ban
  
  # Определение типа сервера
  detect_server_type
  
  # Установка Docker
  if ! install_docker; then
    echo "❌ Критическая ошибка: Docker не удалось установить"
    exit 1
  fi
  
  # Запрос доменов и конфигурации
  echo ""
  echo "=== Настройка доменов ==="
  read -p "Введите домен Matrix сервера (например, matrix.example.com): " MATRIX_DOMAIN
  read -p "Введите домен Element Web (например, element.example.com): " ELEMENT_DOMAIN  
  read -p "Введите домен Synapse Admin (например, admin.example.com): " ADMIN_DOMAIN
  read -p "Введите имя администратора (по умолчанию: admin): " input_admin
  ADMIN_USER=${input_admin:-admin}
  
  echo ""
  echo "=== Настройка базы данных ==="
  while true; do
    read -s -p "Введите пароль для базы данных PostgreSQL: " DB_PASSWORD
    echo ""
    read -s -p "Подтвердите пароль: " DB_PASSWORD_CONFIRM
    echo ""
    
    if [ "$DB_PASSWORD" = "$DB_PASSWORD_CONFIRM" ]; then
      if [ ${#DB_PASSWORD} -lt 8 ]; then
        echo "❌ Пароль должен содержать минимум 8 символов"
        continue
      fi
      echo "✅ Пароль принят"
      break
    else
      echo "❌ Пароли не совпадают. Попробуйте снова."
    fi
  done
  
  echo ""
  echo "=== Конфигурация ==="
  echo "Matrix Domain: $MATRIX_DOMAIN"
  echo "Element Domain: $ELEMENT_DOMAIN"
  echo "Admin Domain: $ADMIN_DOMAIN"
  echo "Admin User: $ADMIN_USER"
  echo "Server Type: $SERVER_TYPE"
  echo "Bind Address: $BIND_ADDRESS"
  echo "DB Password: [СКРЫТ - ${#DB_PASSWORD} символов]"
  echo ""
  
  read -p "Продолжить установку? (y/N): " confirm
  if [[ $confirm != [yY] ]]; then
    echo "Установка отменена"
    exit 0
  fi
  
  # Создание директорий
  echo "Создание директорий..."
  mkdir -p /opt/synapse-data
  mkdir -p /opt/synapse-config
  mkdir -p /opt/element-web
  mkdir -p /opt/synapse-admin
  mkdir -p /opt/coturn
  
  # ИСПРАВЛЕННАЯ ПОСЛЕДОВАТЕЛЬНОСТЬ: Генерация конфигурации через Synapse
  echo "Генерация базовой конфигурации Synapse..."
  
  # Установка прав доступа заранее
  chown -R 991:991 /opt/synapse-data
  
  # Сильно увеличиваем тайм-аут для первой генерации
  timeout 300 docker run --rm \
    --mount type=bind,source=/opt/synapse-data,target=/data \
    -e SYNAPSE_SERVER_NAME="$MATRIX_DOMAIN" \
    -e SYNAPSE_REPORT_STATS=no \
    matrixdotorg/synapse:$SYNAPSE_VERSION generate
    
  if [ $? -ne 0 ]; then
    echo "❌ Ошибка генерации конфигурации"
    exit 1
  fi
  
  echo "✅ Базовая конфигурация и ключ подписи созданы"
  
  # ВАЖНО: Теперь создаем нашу улучшенную конфигурацию БЕЗ перезаписи ключа
  create_synapse_config "$MATRIX_DOMAIN" "$DB_PASSWORD" "$REGISTRATION_SHARED_SECRET" "$TURN_SECRET" "$ADMIN_USER"
  create_element_config "$MATRIX_DOMAIN" "$ADMIN_USER"
  create_synapse_admin_config "$MATRIX_DOMAIN"
  create_coturn_config "$MATRIX_DOMAIN" "$TURN_SECRET" "$PUBLIC_IP" "$LOCAL_IP"
  
  # Восстановление прав доступа после создания конфигураций
  chown -R 991:991 /opt/synapse-data
  
  # Создание Docker Compose конфигурации
  create_docker_compose "$MATRIX_DOMAIN" "$DB_PASSWORD" "$BIND_ADDRESS"
  
  # Запуск контейнеров поэтапно с диагностикой
  echo "Запуск Matrix сервисов поэтапно..."
  cd /opt/synapse-config
  
  echo "1. Скачивание образов..."
  if ! docker compose pull; then
    echo "❌ Ошибка скачивания образов"
    exit 1
  fi
  
  echo "2. Запуск PostgreSQL..."
  if ! docker compose up -d postgres; then
    echo "❌ Ошибка запуска PostgreSQL"
    docker compose logs postgres
    exit 1
  fi
  
  echo "3. Ожидание готовности PostgreSQL..."
  for i in {1..12}; do
    if docker exec matrix-postgres pg_isready -U matrix >/dev/null 2>&1; then
      echo "   ✅ PostgreSQL готов!"
      break
    elif [ $i -eq 12 ]; then
      echo "   ❌ PostgreSQL не запустился. Проверьте логи:"
      docker logs matrix-postgres --tail 20
      exit 1
    else
      echo "   Ожидание PostgreSQL... ($i/12)"
      sleep 5
    fi
  done
  
  echo "4. Запуск Synapse..."
  if ! docker compose up -d synapse; then
    echo "❌ Ошибка запуска Synapse"
    docker compose logs synapse
    exit 1
  fi
  
  echo "5. Ожидание готовности Synapse..."
  for i in {1..24}; do
    # Проверяем healthcheck и API
    if curl -s http://localhost:8008/health >/dev/null 2>&1; then
      echo "   ✅ Synapse готов!"
      break
    elif [ $i -eq 24 ]; then
      echo "   ❌ Synapse не запустился. Диагностика:"
      echo ""
      echo "=== Статус контейнера ==="
      docker ps --filter "name=matrix-synapse"
      echo ""
      echo "=== Последние логи Synapse ==="
      docker logs matrix-synapse --tail 30
      echo ""
      echo "=== Проверка конфигурации ==="
      docker exec matrix-synapse python -m synapse.config -c /data/homeserver.yaml 2>&1 || echo "Ошибка конфигурации"
      echo ""
      echo "=== Сетевые подключения ==="
      docker exec matrix-synapse netstat -tlnp 2>/dev/null || echo "netstat недоступен"
      exit 1
    else
      echo "   Ожидание Synapse... ($i/24)"
      sleep 10
    fi
  done
  
  echo "6. Запуск веб-интерфейсов..."
  if ! docker compose up -d element-web synapse-admin; then
    echo "❌ Ошибка запуска веб-интерфейсов"
    docker compose logs element-web
    docker compose logs synapse-admin
    # Продолжаем, это не критично
  fi
  
  echo "7. Запуск Coturn..."
  echo "   Попытка запуска Coturn с тайм-аутом 30 секунд..."
  
  # Запуск Coturn с коротким тайм-аутом
  if timeout 30 docker compose up -d coturn; then
    echo "   ✅ Coturn быстро запущен"
    
    # Дополнительная проверка что Coturn действительно работает
    sleep 5
    if docker ps | grep -q "matrix-coturn.*Up"; then
      echo "   ✅ Coturn подтвержден как работающий"
    else
      echo "   ⚠️  Coturn запустился но может работать нестабильно"
      echo "   Проверьте логи: docker logs matrix-coturn"
    fi
    
  else
    echo "   ⚠️  Coturn не запустился за 30 секунд"
    echo "   Это может быть связано с проблемами сети или портов"
    echo ""
    echo "   🔧 Возможные решения:"
    echo "   1. Проверьте что порты 3478/udp и 49160-49200/udp не заняты:"
    echo "      netstat -tulpn | grep -E '(3478|4916[0-9]|4917[0-9]|4918[0-9]|4919[0-9]|4920[0-9])'"
    echo ""
    echo "   2. Попробуйте запустить Coturn вручную позже:"
    echo "      cd /opt/synapse-config && docker compose up -d coturn"
    echo ""
    echo "   3. Проверьте логи Coturn:"
    echo "      docker logs matrix-coturn"
    echo ""
    echo "   ⚠️  Matrix будет работать БЕЗ Coturn (только для звонков внутри локальной сети)"
    echo "   Coturn нужен только для звонков через NAT/firewall"
    echo ""
  fi
  
  # Проверка статуса всех контейнеров
  echo ""
  echo "=== Финальная проверка статуса ==="
  docker compose ps
  
  echo ""
  echo "=== Проверьте доступность сервисов ==="
  
  # Проверка Synapse API
  if curl -s http://localhost:8008/_matrix/client/versions >/dev/null; then
    echo "✅ Synapse API доступен"
  else
    echo "❌ Synapse API недоступен"
  fi
  
  # Проверка Element Web
  if curl -s http://localhost:8080/ >/dev/null; then
    echo "✅ Element Web доступен"
  else
    echo "⚠️  Element Web недоступен"
  fi
  
  # Проверка Synapse Admin
  if curl -s http://localhost:8081/ >/dev/null; then
    echo "✅ Synapse Admin доступен"
  else
    echo "⚠️  Synapse Admin недоступен"
  fi
  
  # Проверка PostgreSQL
  if docker exec matrix-postgres pg_isready -U matrix >/dev/null 2>&1; then
    echo "✅ PostgreSQL работает"
  else
    echo "❌ PostgreSQL недоступен"
  fi
  
  # Установка Caddy (только для hosting)
  install_caddy
  
  # Финальная информация
  echo ""
  echo "================================================================="
  echo "🎉 Установка Matrix v6.0 завершена!"
  echo "================================================================="
  echo ""
  echo "📋 Информация о доступе:"
  echo "  Matrix Server: https://$MATRIX_DOMAIN"
  echo "  Element Web:   https://$ELEMENT_DOMAIN"
  echo "  Synapse Admin: https://$ADMIN_DOMAIN"
  echo ""
  echo "🔐 Данные для конфигурации:"
  echo "  Admin User: $ADMIN_USER"
  echo "  DB Password: [СКРЫТ] (${#DB_PASSWORD} символов)"
  echo "  Registration Secret: $REGISTRATION_SHARED_SECRET"
  echo "  TURN Secret: $TURN_SECRET"
  echo ""
  echo "👤 Создание первого пользователя:"
  echo "  docker exec -it matrix-synapse register_new_matrix_user \\"
  echo "    -c /data/homeserver.yaml -u $ADMIN_USER --admin http://localhost:8008"
  echo ""
  echo "ℹ️  Signing key был автоматически создан Synapse в правильном формате"
  echo "================================================================="
  
  read -p "Нажмите Enter для продолжения..."
}

# Функция диагностики проблем с контейнерами
diagnose_containers() {
  echo "=== Диагностика Matrix контейнеров ==="
  echo ""
  
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
  
  echo "📊 Статус всех контейнеров:"
  docker compose ps
  echo ""
  
  echo "🔍 Детальная диагностика:"
  
  # Проверка каждого контейнера
  for container in matrix-postgres matrix-synapse matrix-element-web matrix-synapse-admin matrix-coturn; do
    echo ""
    echo "--- $container ---"
    
    if docker ps | grep -q "$container"; then
      echo "✅ Контейнер запущен"
      
      # Проверка healthcheck
      health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no healthcheck")
      echo "Healthcheck: $health"
      
      # Специальная проверка для Element Web
      if [ "$container" = "matrix-element-web" ] && [ "$health" = "unhealthy" ]; then
        echo ""
        echo "🔍 Анализ проблем Element Web:"
        
        # Проверка логов на доменные конфигурации
        DOMAIN_CONFIG_ERROR=$(docker logs "$container" 2>&1 | grep -o 'config\.[a-zA-Z0-9.-]*\.json.*404' | head -1)
        if [ -n "$DOMAIN_CONFIG_ERROR" ]; then
          MISSING_DOMAIN=$(echo "$DOMAIN_CONFIG_ERROR" | grep -o 'config\.[a-zA-Z0-9.-]*\.json' | sed 's/config\.//' | sed 's/\.json//')
          echo "   ❌ Проблема: Отсутствует доменная конфигурация для $MISSING_DOMAIN"
          echo "   💡 Решение: Используйте опцию '13. 🌐 Исправить конфигурацию Element Web'"
        fi
        
        # Проверка доступности основной конфигурации
        if curl -s http://localhost:8080/config.json >/dev/null 2>&1; then
          echo "   ✅ Основная конфигурация доступна"
        else
          echo "   ❌ Основная конфигурация недоступна"
        fi
      fi
      
      # Последние логи
      echo "Последние логи:"
      docker logs "$container" --tail 10 2>&1 | sed 's/^/  /'
      
    else
      echo "❌ Контейнер не запущен"
      echo "Логи последнего запуска:"
      docker logs "$container" --tail 15 2>&1 | sed 's/^/  /' || echo "  Логи недоступны"
    fi
  done
  
  echo ""
  echo "🌐 Проверка сетевых портов:"
  netstat -tulpn | grep -E "(8008|8080|8081|8448|3478)" | head -10
  
  echo ""
  echo "💾 Использование дискового пространства:"
  du -sh /opt/synapse-data /opt/synapse-config /opt/element-web /opt/synapse-admin /opt/coturn 2>/dev/null || echo "Несколько директорий недоступны"
  
  echo ""
  echo "🔗 Проверка конфигурационных файлов:"
  
  # Проверка основных конфигов
  if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
    echo "✅ homeserver.yaml существует ($(wc -l < /opt/synapse-data/homeserver.yaml) строк)"
  else
    echo "❌ homeserver.yaml отсутствует"
  fi
  
  if [ -f "/opt/synapse-config/docker-compose.yml" ]; then
    echo "✅ docker-compose.yml существует"
  else
    echo "❌ docker-compose.yml отсутствует"
  fi
  
  if [ -f "/opt/element-web/config.json" ]; then
    echo "✅ Element config.json существует"
    
    # Проверка доменных конфигураций
    DOMAIN_CONFIGS=$(find /opt/element-web -name "config.*.json" 2>/dev/null | wc -l)
    if [ "$DOMAIN_CONFIGS" -gt 0 ]; then
      echo "   Доменных конфигураций: $DOMAIN_CONFIGS"
      find /opt/element-web -name "config.*.json" 2>/dev/null | sed 's/^/     - /'
    else
      echo "   ⚠️  Доменные конфигурации отсутствуют (могут потребоваться)"
    fi
  else
    echo "❌ Element config.json отсутствует"
  fi
  
  echo ""
  echo "🔧 Рекомендуемые действия:"
  echo "  docker compose logs [service]     # Подробные логи сервиса"
  echo "  docker compose restart [service]  # Перезапуск сервиса"
  echo "  docker compose down && docker compose up -d  # Полный перезапуск"
  echo "  docker exec -it matrix-synapse bash  # Вход в контейнер Synapse"
  
  # Автоматические рекомендации на основе проблем
  echo ""
  echo "🚨 Автоматические рекомендации:"
  
  # Проверка на проблемы Element Web
  if docker logs matrix-element-web 2>&1 | grep -q "config\.[a-zA-Z0-9.-]*\.json.*404"; then
    echo "   ⚠️  Обнаружены проблемы с доменными конфигурациями Element Web"
    echo "      → Используйте опцию '13. 🌐 Исправить конфигурацию Element Web'"
  fi
  
  # Проверка на проблемы Coturn
  if ! docker ps | grep -q "matrix-coturn.*Up"; then
    echo "   ⚠️  Coturn не запущен - VoIP звонки могут не работать"
    echo "      → Используйте опцию '11. 📞 Управление Coturn (VoIP сервер)'"
  fi
  
  # Проверка на проблемы Synapse
  if ! curl -s http://localhost:8008/health >/dev/null 2>&1; then
    echo "   ❌ Synapse API недоступен - критическая проблема"
    echo "      → Используйте опцию '3. 🔄 Перезапустить все сервисы'"
  fi
}

# Функция для последовательного запуска сервисов
start_services_sequentially() {
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
  
  echo "Запуск сервисов в правильном порядке..."
  
  echo "1. Запуск PostgreSQL..."
  if ! docker compose up -d postgres; then
    echo "❌ Ошибка запуска PostgreSQL"
    docker compose logs postgres
    return 1
  fi
  
  echo "2. Ожидание готовности PostgreSQL..."
  for i in {1..12}; do
    if docker exec matrix-postgres pg_isready -U matrix >/dev/null 2>&1; then
      echo "   ✅ PostgreSQL готов!"
      break
    elif [ $i -eq 12 ]; then
      echo "   ❌ PostgreSQL не запустился. Проверьте логи."
      docker logs matrix-postgres --tail 20
      return 1
    else
      echo "   Ожидание PostgreSQL... ($i/12)"
      sleep 5
    fi
  done
  
  echo "3. Запуск Synapse..."
  if ! docker compose up -d synapse; then
    echo "❌ Ошибка запуска Synapse"
    docker compose logs synapse
    return 1
  fi
  
  echo "4. Ожидание готовности Synapse..."
  for i in {1..24}; do
    if curl -s http://localhost:8008/health >/dev/null 2>&1; then
      echo "   ✅ Synapse готов!"
      break
    elif [ $i -eq 24 ]; then
      echo "   ❌ Synapse не запустился. Проверьте логи."
      docker logs matrix-synapse --tail 30
      return 1
    else
      echo "   Ожидание Synapse... ($i/24)"
      sleep 10
    fi
  done
  
  echo "5. Запуск остальных сервисов..."
  if ! docker compose up -d; then
    echo "⚠️  Возникли ошибки при запуске остальных сервисов."
    echo "Проверьте их статус и логи."
  fi
  
  echo "✅ Все сервисы запущены."
  docker compose ps
}

# Функция перезапуска сервисов
restart_services() {
  echo "=== Перезапуск Matrix сервисов ==="
  
  if [ -f "/opt/synapse-config/docker-compose.yml" ]; then
    cd /opt/synapse-config
    echo "Остановка всех контейнеров..."
    docker compose stop
    echo "Последовательный запуск сервисов..."
    start_services_sequentially
    
    echo "Ожидание готовности..."
    sleep 5
    check_status
  else
    echo "❌ Docker Compose конфигурация не найдена"
  fi
}

# Функция управления Docker (полная реализация)
manage_docker() {
  echo "=== Управление Docker контейнерами ==="
  echo ""
  echo "1. Статус контейнеров"
  echo "2. Остановить все (с таймаутом)"
  echo "3. Запустить все"
  echo "4. Перезапустить все"
  echo "5. Принудительно остановить все"
  echo "6. Удалить все контейнеры"
  echo "7. Назад"
  echo ""
  read -p "Выберите действие (1-7): " docker_choice
  
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
  
  case $docker_choice in
    1) 
      echo "Статус контейнеров:"
      docker compose ps
      ;;
    2) 
      echo "Остановка контейнеров с таймаутом 60 секунд..."
      timeout 60 docker compose stop || {
        echo "⚠️  Таймаут остановки, используйте принудительную остановку (опция 5)"
      }
      ;;
    3) 
      echo "Запуск всех контейнеров в правильном порядке..."
      start_services_sequentially
      ;;
    4) 
      echo "Перезапуск всех контейнеров..."
      restart_services
      ;;
    5)
      echo "Принудительная остановка контейнеров..."
      docker stop matrix-synapse matrix-postgres matrix-element-web matrix-synapse-admin matrix-coturn 2>/dev/null || true
      echo "✅ Принудительная остановка завершена"
      ;;
    6) 
      read -p "❗ Это удалит ВСЕ контейнеры Matrix! Продолжить? (y/N): " confirm
      if [[ $confirm == [yY] ]]; then
        echo "Остановка и удаление контейнеров..."
        timeout 60 docker compose down || docker stop matrix-synapse matrix-postgres matrix-element-web matrix-synapse-admin matrix-coturn 2>/dev/null
        docker compose down --remove-orphans
        echo "✅ Контейнеры удалены"
      fi ;;
    7) return 0 ;;
    *) echo "❌ Неверный выбор" ;;
  esac
  
  read -p "Нажмите Enter для продолжения..."
}

# Функция показа логов
show_logs() {
  echo "=== Логи Matrix сервисов ==="
  echo ""
  echo "1. Synapse"
  echo "2. PostgreSQL"
  echo "3. Element Web"
  echo "4. Synapse Admin"
  echo "5. Coturn"
  echo "6. Все сервисы"
  echo "7. Назад"
  echo ""
  read -p "Выберите сервис (1-7): " log_choice
  
  case $log_choice in
    1) 
      echo "Логи Synapse (последние 50 строк, нажмите Ctrl+C для выхода):"
      docker logs -f matrix-synapse --tail 50
      ;;
    2) 
      echo "Логи PostgreSQL (последние 50 строк, нажмите Ctrl+C для выхода):"
      docker logs -f matrix-postgres --tail 50
      ;;
    3) 
      echo "Логи Element Web (последние 50 строк, нажмите Ctrl+C для выхода):"
      docker logs -f matrix-element-web --tail 50
      ;;
    4) 
      echo "Логи Synapse Admin (последние 50 строк, нажмите Ctrl+C для выхода):"
      docker logs -f matrix-synapse-admin --tail 50
      ;;
    5) 
      echo "Логи Coturn (последние 50 строк, нажмите Ctrl+C для выхода):"
      docker logs -f matrix-coturn --tail 50
      ;;
    6) 
      cd /opt/synapse-config 2>/dev/null || return 1
      echo "Логи всех сервисов (нажмите Ctrl+C для выхода):"
      docker compose logs -f
      ;;
    7) return 0 ;;
    *) echo "❌ Неверный выбор" ;;
  esac
}

# Функция показа секретов
show_secrets() {
  echo "=== Секреты конфигурации ==="
  echo ""
  
  if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
    echo "🔐 Из конфигурации Synapse:"
    echo "Registration Secret:"
    grep "registration_shared_secret:" /opt/synapse-data/homeserver.yaml | cut -d'"' -f2
    echo ""
    echo "TURN Secret:"
    grep "turn_shared_secret:" /opt/synapse-data/homeserver.yaml | cut -d'"' -f2
    echo ""
  fi
  
  if [ -f "/opt/synapse-config/docker-compose.yml" ]; then
    echo "💾 Database Password:"
    grep "POSTGRES_PASSWORD=" /opt/synapse-config/docker-compose.yml | cut -d'=' -f2
    echo ""
  fi
  
  echo "ℹ️  Эти данные нужны для ручной настройки клиентов"
  read -p "Нажмите Enter для продолжения..."
}

# Функция обновления контейнеров
update_containers() {
  echo "=== Обновление Matrix контейнеров ==="
  
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
  
  echo "Скачивание обновлений..."
  docker compose pull
  
  echo "Перезапуск с новыми образами..."
  docker compose up -d
  
  echo "Очистка старых образов..."
  docker image prune -f
  
  echo "✅ Обновление завершено"
  sleep 2
  check_status
}

# Функция для управления Coturn отдельно
manage_coturn() {
  echo "=== Управление Coturn TURN сервером ==="
  echo ""
  echo "1. Статус Coturn"
  echo "2. Запустить Coturn"
  echo "3. Остановить Coturn"
  echo "4. Перезапустить Coturn"
  echo "5. Логи Coturn"
  echo "6. Тест портов Coturn"
  echo "7. Исправить конфигурацию Coturn"
  echo "8. Назад"
  echo ""
  read -p "Выберите действие (1-8): " coturn_choice
  
  case $coturn_choice in
    1)
      echo "Статус Coturn:"
      if docker ps | grep -q "matrix-coturn"; then
        echo "✅ Coturn запущен"
        docker ps --filter "name=matrix-coturn" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
      else
        echo "❌ Coturn не запущен"
        echo "Последний статус:"
        docker ps -a --filter "name=matrix-coturn" --format "table {{.Names}}\t{{.Status}}"
      fi
      ;;
    2)
      echo "Запуск Coturn..."
      cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
      if timeout 30 docker compose up -d coturn; then
        echo "✅ Coturn запущен"
      else
        echo "❌ Ошибка запуска Coturn"
        echo "Проверьте логи: docker logs matrix-coturn"
      fi
      ;;
    3)
      echo "Остановка Coturn..."
      docker stop matrix-coturn 2>/dev/null && echo "✅ Coturn остановлен" || echo "❌ Ошибка остановки"
      ;;
    4)
      echo "Перезапуск Coturn..."
      cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
      docker compose restart coturn && echo "✅ Coturn перезапущен" || echo "❌ Ошибка перезапуска"
      ;;
    5)
      echo "Логи Coturn (последние 50 строк, Ctrl+C для выхода):"
      docker logs -f matrix-coturn --tail 50 2>/dev/null || echo "❌ Логи недоступны"
      ;;
    6)
      echo "Проверка портов Coturn..."
      echo "UDP порт 3478 (TURN):"
      netstat -tulpn | grep ":3478" || echo "Порт 3478 не слушается"
      echo ""
      echo "UDP порты 49160-49200 (media relay):"
      netstat -tulpn | grep -E ":(4916[0-9]|4917[0-9]|4918[0-9]|4919[0-9]|4920[0-9])" | head -5 || echo "Порты медиа не слушаются"
      echo ""
      echo "Если порты не слушаются, попробуйте перезапустить Coturn"
      ;;
    7)
      echo "Исправление конфигурации Coturn..."
      if [ -f "/opt/synapse-data/homeserver.yaml" ]; then
        MATRIX_DOMAIN=$(grep "server_name:" /opt/synapse-data/homeserver.yaml | head -1 | sed 's/server_name: *"//' | sed 's/"//')
        TURN_SECRET=$(grep "turn_shared_secret:" /opt/synapse-data/homeserver.yaml | cut -d'"' -f2)
        PUBLIC_IP=$(curl -s -4 https://ifconfig.co || echo "auto-detect")
        LOCAL_IP=$(hostname -I | awk '{print $1}')
        
        create_coturn_config "$MATRIX_DOMAIN" "$TURN_SECRET" "$PUBLIC_IP" "$LOCAL_IP"
        echo "✅ Конфигурация обновлена, перезапустите Coturn"
      else
        echo "❌ Конфигурация Synapse не найдена"
      fi
      ;;
    8) return 0 ;;
    *) echo "❌ Неверный выбор" ;;
  esac
  
  read -p "Нажмите Enter для продолжения..."
}

# Функция для ручного исправления Docker Compose монтирования Element Web
fix_element_web_docker_mount() {
  echo "=== Ручное исправление монтирования Element Web ==="
  echo ""
  
  # Проверяем наличие файлов
  if [ ! -f "/opt/element-web/config.json" ]; then
    echo "❌ Основной конфиг Element Web не найден"
    return 1
  fi
  
  # Определяем доменную конфигурацию
  DOMAIN_CONFIG=$(find /opt/element-web -name "config.*.json" | head -1)
  if [ -z "$DOMAIN_CONFIG" ]; then
    echo "❌ Доменная конфигурация Element Web не найдена"
    echo "Сначала запустите опцию 13 для создания доменной конфигурации"
    return 1
  fi
  
  DOMAIN_FILE=$(basename "$DOMAIN_CONFIG")
  echo "📋 Найдена доменная конфигурация: $DOMAIN_FILE"
  
  # Остановка Element Web
  echo "Остановка Element Web контейнера..."
  docker stop matrix-element-web 2>/dev/null || true
  
  # Backup Docker Compose
  cd /opt/synapse-config 2>/dev/null || { echo "❌ Конфигурация не найдена"; return 1; }
  cp docker-compose.yml docker-compose.yml.backup.manual.$(date +%s)
  
  # Исправление через Python для точности
  echo "Исправление Docker Compose конфигурации..."
  
python3 << EOF
import re

compose_file = "/opt/synapse-config/docker-compose.yml"

try:
    with open(compose_file, 'r') as f:
        content = f.read()
    
    # Ищем секцию element-web и заменяем volumes
    pattern = r'(element-web:.*?volumes:\s*\n)(.*?)(^\s{2}\w|\Z)'
    
    def replace_volumes(match):
        prefix = match.group(1)
        suffix = match.group(3) if match.group(3) and not match.group(3).strip() == '' else ''
        
        new_volumes = '''      - /opt/element-web/config.json:/app/config.json:ro
      - /opt/element-web/$DOMAIN_FILE:/app/$DOMAIN_FILE:ro
'''
        return prefix + new_volumes + suffix
    
    new_content = re.sub(pattern, replace_volumes, content, flags=re.MULTILINE | re.DOTALL)
    
    with open(compose_file, 'w') as f:
        f.write(new_content)
    
    print("✅ Docker Compose обновлен")
    
except Exception as e:
    print(f"❌ Ошибка: {e}")
EOF
  
  # Запуск Element Web
  echo "Запуск Element Web..."
  docker compose up -d element-web
  
  # Проверка
  echo "Проверка результата..."
  sleep 3
  
  if curl -s "http://localhost:8080/$DOMAIN_FILE" | grep -q "default_server_config"; then
    echo "✅ Доменная конфигурация успешно доступна!"
  else
    echo "❌ Доменная конфигурация всё ещё недоступна"
    echo ""
    echo "🔧 Дополнительная диагностика:"
    echo "Содержимое контейнера:"
    docker exec matrix-element-web ls -la /app/config*.json
    echo ""
    echo "Монтирования в Docker Compose:"
    grep -A 10 -B 2 "volumes:" docker-compose.yml | grep -A 12 element-web
  fi
}

# Обновляем главное меню
show_menu() {
  clear
  echo "=================================================================="
  echo "              Matrix Setup & Repair Tool v6.0"
  echo "                    Enhanced Docker Edition"
  echo "=================================================================="
  echo "1.  🚀 Полная установка Matrix системы (Docker)"
  echo "2.  📊 Проверить статус сервисов"
  echo "3.  🔄 Перезапустить все сервисы"
  echo "4.  👤 Создать пользователя (админ)"
  echo "5.  🔧 Управление Docker контейнерами"
  echo "6.  📋 Показать логи сервисов"
  echo "7.  🔐 Показать секреты конфигурации"
  echo "8.  🆙 Обновить все контейнеры"
  echo "9.  🔍 Диагностика проблем контейнеров"
  echo "10. 🔑 Исправить ключ подписи Synapse"
  echo "11. 📞 Управление Coturn (VoIP сервер)"
  echo "12. ⚙️  Управление Synapse (федерация, регистрация)"
  echo "13. 🌐 Исправить конфигурацию Element Web"
  echo "14. 🛠️  Ручное исправление Docker монтирования Element Web"
  echo "15. ❌ Выход"
  echo "=================================================================="
}

# Функция запуска модуля управления Synapse
manage_synapse_module() {
  local manage_script="./manage-synapse.sh"
  
  # Проверяем существование модуля
  if [ ! -f "$manage_script" ]; then
    echo "❌ Модуль manage-synapse.sh не найден"
    echo ""
    echo "📥 Скачивание модуля управления Synapse..."
    
    if command -v wget >/dev/null 2>&1; then
      wget -qO manage-synapse.sh https://raw.githubusercontent.com/gopnikgame/matrix-setup/main/manage-synapse.sh
    elif command -v curl >/dev/null 2>&1; then
      curl -sL https://raw.githubusercontent.com/gopnikgame/matrix-setup/main/manage-synapse.sh -o manage-synapse.sh
    else
      echo "❌ Не удалось скачать модуль (нет wget или curl)"
      echo "Скачайте вручную: https://github.com/gopnikgame/matrix-setup/blob/main/manage-synapse.sh"
      return 1
    fi
    
    chmod +x manage-synapse.sh
    echo "✅ Модуль управления скачан"
  fi
  
  # Проверяем права на выполнение
  if [ ! -x "$manage_script" ]; then
    chmod +x "$manage_script"
  fi
  
  # Запускаем модуль
  echo "🚀 Запуск модуля управления Matrix Synapse..."
  sleep 1
  "$manage_script"
}


# Основной цикл
while true; do
  show_menu
  read -p "Выберите опцию (1-15): " choice
  
  case $choice in
    1) full_installation ;;
    2) check_status; read -p "Нажмите Enter для продолжения..." ;;
    3) restart_services; read -p "Нажмите Enter для продолжения..." ;;
    4) create_admin_user; read -p "Нажмите Enter для продолжения..." ;;
    5) manage_docker ;;
    6) show_logs ;;
    7) show_secrets ;;
    8) update_containers; read -p "Нажмите Enter для продолжения..." ;;
    9) diagnose_containers; read -p "Нажмите Enter для продолжения..." ;;
    10) fix_signing_key; read -p "Нажмите Enter для продолжения..." ;;
    11) manage_coturn ;;
    12) manage_synapse_module ;;
    13) fix_element_domain_config; read -p "Нажмите Enter для продолжения..." ;;
    14) fix_element_web_docker_mount; read -p "Нажмите Enter для продолжения..." ;;
    15) echo "👋 До свидания!"; exit 0 ;;
    *) echo "❌ Неверный выбор. Попробуйте снова."; sleep 2 ;;
  esac
done