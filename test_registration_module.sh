#!/bin/bash

# Тестовый скрипт для проверки модуля registration_control.sh

echo "Тестирование модуля registration_control.sh..."

# Проверка синтаксиса
echo "1. Проверка синтаксиса bash..."
if bash -n "modules/registration_control.sh" 2>/dev/null; then
    echo "✅ Синтаксис bash корректен"
else
    echo "❌ Ошибка синтаксиса bash"
    bash -n "modules/registration_control.sh"
    exit 1
fi

# Проверка shebang
echo "2. Проверка shebang..."
first_line=$(head -n1 "modules/registration_control.sh")
if [[ "$first_line" == "#!/bin/bash" ]]; then
    echo "✅ Shebang корректен"
else
    echo "❌ Неверный shebang: $first_line"
fi

# Проверка исполняемых прав
echo "3. Проверка прав доступа..."
if [[ -x "modules/registration_control.sh" ]]; then
    echo "✅ Файл имеет права на выполнение"
else
    echo "⚠️ Файл не имеет прав на выполнение"
    echo "Установка прав на выполнение..."
    chmod +x "modules/registration_control.sh" 2>/dev/null || echo "Не удалось установить права"
fi

# Проверка кодировки
echo "4. Проверка кодировки..."
if command -v file >/dev/null 2>&1; then
    encoding=$(file -b --mime-encoding "modules/registration_control.sh")
    if [[ "$encoding" == "us-ascii" ]] || [[ "$encoding" == "utf-8" ]]; then
        echo "✅ Кодировка корректна: $encoding"
    else
        echo "⚠️ Возможные проблемы с кодировкой: $encoding"
    fi
else
    echo "⚠️ Команда file недоступна, проверка кодировки пропущена"
fi

# Проверка размера файла
echo "5. Проверка размера файла..."
if [[ -f "modules/registration_control.sh" ]]; then
    size=$(wc -c < "modules/registration_control.sh" 2>/dev/null || echo "unknown")
    if [[ "$size" != "unknown" ]] && [[ "$size" -gt 100 ]]; then
        echo "✅ Размер файла: $size байт"
    else
        echo "❌ Файл слишком мал или поврежден"
    fi
else
    echo "❌ Файл не найден"
fi

# Проверка основных функций
echo "6. Проверка наличия основных функций..."
required_functions=(
    "check_registration_status"
    "enable_open_registration"
    "enable_email_registration"
    "enable_token_registration"
    "disable_registration"
    "show_main_menu"
)

for func in "${required_functions[@]}"; do
    if grep -q "^${func}()" "modules/registration_control.sh"; then
        echo "✅ Функция $func найдена"
    else
        echo "❌ Функция $func не найдена"
    fi
done

# Проверка подключения библиотеки
echo "7. Проверка подключения общей библиотеки..."
if grep -q "source.*common_lib.sh" "modules/registration_control.sh"; then
    echo "✅ Подключение общей библиотеки найдено"
else
    echo "❌ Подключение общей библиотеки не найдено"
fi

# Проверка конфигурационных переменных
echo "8. Проверка конфигурационных переменных..."
config_vars=(
    "CONFIG_DIR"
    "REGISTRATION_CONFIG"
    "HOMESERVER_CONFIG"
)

for var in "${config_vars[@]}"; do
    if grep -q "^${var}=" "modules/registration_control.sh"; then
        echo "✅ Переменная $var определена"
    else
        echo "❌ Переменная $var не определена"
    fi
done

echo ""
echo "Тестирование завершено!"
echo ""
echo "Для полного тестирования функциональности требуется:"
echo "- Установленный Matrix Synapse"
echo "- Права root"
echo "- Запущенная служба matrix-synapse"