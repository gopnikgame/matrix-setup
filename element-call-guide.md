# Element Call Configuration Guide

## Что такое Element Call

Element Call - это современная альтернатива Jitsi для групповых звонков в Matrix. Это полностью децентрализованная система видеосвязи, которая работает поверх Matrix протокола.

## Преимущества Element Call

- **Децентрализация**: Работает через ваш собственный Matrix сервер
- **Шифрование**: End-to-end шифрование по умолчанию
- **Интеграция**: Глубокая интеграция с Element Web
- **Производительность**: Оптимизирован для современных браузеров

## Автоматическая конфигурация

Скрипт `setup-matrix.sh` v5.1 автоматически настраивает Element Call:

### 1. В Element Web config.json:
```json
{
    "features": {
        "feature_group_calls": false,
        "feature_element_call_video_rooms": false,
        "feature_disable_call_per_sender_encryption": false
    },
    "element_call": {
        "use_exclusively": false,
        "participant_limit": 8,
        "brand": "Element Call",
        "guest_spa_url": null
    }
}
```

### 2. В Well-known endpoints:
```json
{
    "io.element.jitsi": {
        "preferredDomain": "matrix.example.com"
    }
}
```

## Включение Element Call

### Метод 1: Через Element Web (Рекомендуется)

1. Войдите в Element Web
2. Перейдите в **Настройки** → **Labs**
3. Найдите **"New group call experience"**
4. Включите эту функцию
5. Перезагрузите Element Web

### Метод 2: Через конфигурацию (Администратор)

Отредактируйте `/opt/element-web/config.json`:

```json
{
    "features": {
        "feature_group_calls": true
    },
    "element_call": {
        "use_exclusively": false,
        "participant_limit": 8
    }
}
```

Перезапустите Element Web:
```bash
docker restart element-web
```

## Дополнительные настройки

### Увеличение лимита участников
```json
{
    "element_call": {
        "participant_limit": 16
    }
}
```

### Использование только Element Call
```json
{
    "element_call": {
        "use_exclusively": true
    }
}
```

### Отключение шифрования per-sender
```json
{
    "features": {
        "feature_disable_call_per_sender_encryption": true
    }
}
```

## Совместимость

### Поддерживаемые браузеры:
- ✅ Chrome 90+
- ✅ Firefox 88+  
- ✅ Safari 14+
- ✅ Edge 90+

### Требования к серверу:
- Matrix Synapse 1.70.0+
- Element Web v1.11.0+
- TURN сервер (уже настроен скриптом)

## Устранение неполадок

### Element Call не появляется в меню
1. Убедитесь что `feature_group_calls: true`
2. Очистите кэш браузера
3. Перезагрузите Element Web

### Проблемы с подключением
1. Проверьте TURN сервер:
```bash
systemctl status coturn
```

2. Проверьте UDP порты:
```bash
ufw status | grep 49152:65535
```

3. Проверьте логи Coturn:
```bash
tail -f /var/log/turnserver.log
```

### Низкое качество звука/видео
1. Проверьте пропускную способность
2. Уменьшите `participant_limit`
3. Включите `feature_disable_call_per_sender_encryption`

## Миграция с Jitsi

### Постепенная миграция
1. Оставьте `use_exclusively: false`
2. Пользователи могут выбирать между Element Call и Jitsi
3. После тестирования установите `use_exclusively: true`

### Полная замена
```json
{
    "element_call": {
        "use_exclusively": true
    },
    "jitsi": {
        "preferred_domain": null
    }
}
```

## Мониторинг и логи

### Проверка состояния Element Call
Откройте браузерную консоль в Element Web (F12):
- Ошибки WebRTC будут видны в Console
- Network покажет соединения с TURN сервером

### Логи сервера
```bash
# Matrix Synapse логи
tail -f /var/log/matrix-synapse/homeserver.log | grep -i call

# Coturn логи  
tail -f /var/log/turnserver.log
```

## Производительность

### Оптимальные настройки для разных сценариев:

#### Малые группы (до 4 человек):
```json
{
    "element_call": {
        "participant_limit": 4
    },
    "features": {
        "feature_disable_call_per_sender_encryption": false
    }
}
```

#### Большие группы (до 16 человек):
```json
{
    "element_call": {
        "participant_limit": 16
    },
    "features": {
        "feature_disable_call_per_sender_encryption": true
    }
}
```

## Безопасность

Element Call предоставляет:
- **E2EE шифрование** (можно отключить для производительности)
- **Аутентификация через Matrix**
- **Контроль доступа через права комнаты**
- **Нет зависимости от внешних сервисов**

## Дополнительные ресурсы

- [Element Call GitHub](https://github.com/element-hq/element-call)
- [Element Web Documentation](https://github.com/element-hq/element-web)
- [Matrix VoIP Specification](https://spec.matrix.org/latest/client-server-api/#voice-over-ip)