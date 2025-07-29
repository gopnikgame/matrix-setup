# Synapse Admin Configuration

## Основные возможности

Synapse Admin предоставляет веб-интерфейс для управления Matrix Synapse сервером.

## Требования совместимости

- Synapse v1.93.0 или выше (автоматически устанавливается скриптом)
- Доступ к эндпоинтам:
  - `/_matrix` (Matrix Client API)
  - `/_synapse/admin` (Synapse Admin API)

## Конфигурация

Скрипт автоматически:

1. **Создает ограниченную конфигурацию** (`config.json`):
```json
{
  "restrictBaseUrl": "https://your-matrix-domain.com"
}
```

2. **Настраивает Docker контейнер** с правильными volume mappings:
```yaml
volumes:
  - ./config.json:/app/config.json:ro
environment:
  - REACT_APP_SERVER_URL=https://your-matrix-domain.com
```

## Доступ к админ-панели

1. Перейдите по адресу вашего Synapse Admin домена
2. Используйте учетные данные администратора, созданные через:
   ```bash
   register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008
   ```

## Функции администрирования

- Управление пользователями
- Просмотр и управление комнатами
- Мониторинг сервера
- Настройка политик
- Управление федерацией (отключена в нашей конфигурации)

## Безопасность

- Ограничен только вашим homeserver
- Требует администраторские права в Matrix
- Доступен только через HTTPS
- Эндпоинты `/_synapse/admin` защищены от внешнего доступа