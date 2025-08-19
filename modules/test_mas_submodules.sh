#!/bin/bash

# Тестовый скрипт для проверки загрузки подмодулей MAS
# Запуск: ./modules/test_mas_submodules.sh

set -e  # Остановиться при первой ошибке

echo "=== ТЕСТ ЗАГРУЗКИ ПОДМОДУЛЕЙ MAS ==="
echo

# Определение директории скрипта
if [[ -L "${BASH_SOURCE[0]}" ]]; then
    REAL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    REAL_SCRIPT_PATH="${BASH_SOURCE[0]}"
fi

SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" && pwd)"
echo "SCRIPT_DIR: $SCRIPT_DIR"

# Подключение общей библиотеки
COMMON_LIB="${SCRIPT_DIR}/../common/common_lib.sh"
echo "COMMON_LIB: $COMMON_LIB"

if [ ! -f "$COMMON_LIB" ]; then
    echo "❌ ОШИБКА: Общая библиотека не найдена: $COMMON_LIB"
    exit 1
fi

echo "✅ Общая библиотека найдена"
source "$COMMON_LIB"
echo "✅ Общая библиотека загружена"

# Проверка наличия директории подмодулей
MAS_MODULES_DIR="${SCRIPT_DIR}/mas_sub_modules"
echo "MAS_MODULES_DIR: $MAS_MODULES_DIR"

if [ ! -d "$MAS_MODULES_DIR" ]; then
    echo "❌ ОШИБКА: Директория подмодулей не найдена: $MAS_MODULES_DIR"
    echo
    echo "Содержимое SCRIPT_DIR (${SCRIPT_DIR}):"
    ls -la "${SCRIPT_DIR}/"
    exit 1
fi

echo "✅ Директория подмодулей найдена"
echo
echo "Содержимое директории mas_sub_modules:"
ls -la "$MAS_MODULES_DIR"

echo
echo "=== ТЕСТИРОВАНИЕ ЗАГРУЗКИ КАЖДОГО ПОДМОДУЛЯ ==="

# Список подмодулей для тестирования
declare -A submodules=(
    ["mas_removing.sh"]="uninstall_mas"
    ["mas_diagnosis_and_recovery.sh"]="diagnose_mas"
    ["mas_manage_mas_registration.sh"]="manage_mas_registration"
    ["mas_manage_sso.sh"]="manage_sso_providers"
    ["mas_manage_captcha.sh"]="manage_captcha_settings"
    ["mas_manage_ban_usernames.sh"]="manage_banned_usernames"
)

total_modules=${#submodules[@]}
loaded_modules=0
failed_modules=()

for module_file in "${!submodules[@]}"; do
    expected_function="${submodules[$module_file]}"
    module_path="${MAS_MODULES_DIR}/${module_file}"
    
    echo
    echo "Тестирование: $module_file"
    echo "  Путь: $module_path"
    echo "  Ожидаемая функция: $expected_function"
    
    # Проверка существования файла
    if [ ! -f "$module_path" ]; then
        echo "  ❌ Файл не найден"
        failed_modules+=("$module_file")
        continue
    fi
    echo "  ✅ Файл найден"
    
    # Проверка прав доступа
    if [ ! -r "$module_path" ]; then
        echo "  ❌ Файл недоступен для чтения"
        failed_modules+=("$module_file")
        continue
    fi
    echo "  ✅ Файл доступен для чтения"
    
    # Проверка синтаксиса
    if ! bash -n "$module_path" 2>/dev/null; then
        echo "  ❌ Ошибка синтаксиса:"
        bash -n "$module_path" 2>&1 | sed 's/^/    /'
        failed_modules+=("$module_file")
        continue
    fi
    echo "  ✅ Синтаксис корректен"
    
    # Попытка загрузки модуля
    if source "$module_path" 2>/dev/null; then
        echo "  ✅ Модуль загружен без ошибок"
    else
        echo "  ❌ Ошибка загрузки модуля:"
        source "$module_path" 2>&1 | head -10 | sed 's/^/    /'
        failed_modules+=("$module_file")
        continue
    fi
    
    # Проверка доступности ожидаемой функции
    if command -v "$expected_function" >/dev/null 2>&1; then
        echo "  ✅ Функция $expected_function доступна"
        ((loaded_modules++))
    else
        echo "  ❌ Функция $expected_function недоступна"
        failed_modules+=("$module_file")
    fi
done

echo
echo "=== РЕЗУЛЬТАТЫ ТЕСТИРОВАНИЯ ==="
echo "Всего модулей: $total_modules"
echo "Успешно загружено: $loaded_modules"
echo "Ошибок: ${#failed_modules[@]}"

if [ ${#failed_modules[@]} -eq 0 ]; then
    echo "🎉 Все подмодули успешно загружены!"
    exit 0
else
    echo "❌ Проблемы с модулями:"
    for failed_module in "${failed_modules[@]}"; do
        echo "  - $failed_module"
    done
    
    echo
    echo "💡 Рекомендации:"
    echo "1. Проверьте права доступа к файлам"
    echo "2. Убедитесь, что общая библиотека common_lib.sh корректно загружена"
    echo "3. Проверьте синтаксис проблемных модулей"
    echo "4. Запустите: chmod +x modules/mas_sub_modules/*.sh"
    
    exit 1
fi