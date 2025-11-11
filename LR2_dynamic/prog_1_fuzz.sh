#!/bin/bash

set -e  # Завершать скрипт при ошибках

# Конфигурация
PROGRAM_NAME="prog_1_structs_ways"
INPUT_DIR="prog1_test_inputs"
OUTPUT_DIR="prog1_test_outputs"

# Функции
compile_program() {
    echo "=== Компиляция программы ==="
    echo "Попытка компиляции с различными компиляторами AFL++..."
    
    # Пробуем разные компиляторы по порядку
    local compilers=("afl-gcc-fast" "afl-gcc" "afl-clang-fast" "afl-clang" "gcc")
    local found_compiler=""
    
    for compiler in "${compilers[@]}"; do
        if command -v "$compiler" &> /dev/null; then
            echo "Найден компилятор: $compiler"
            found_compiler="$compiler"
            break
        fi
    done
    
    if [ -z "$found_compiler" ]; then
        echo "Ошибка: не найден ни один компилятор!"
        echo "Установите AFL++ или gcc"
        exit 1
    fi
    
    echo "Используется компилятор: $found_compiler"
    
    # Разные флаги для разных компиляторов
    case "$found_compiler" in
        *clang*)
            echo "Компиляция с clang и AddressSanitizer..."
            $found_compiler -fsanitize=address -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
            ;;
        *gcc*)
            if [[ "$found_compiler" == *fast* ]]; then
                echo "Компиляция с afl-gcc-fast..."
                $found_compiler -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
            else
                echo "Компиляция с стандартным gcc и инструментацией..."
                $found_compiler -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
            fi
            ;;
        *)
            echo "Компиляция с стандартными флагами..."
            $found_compiler -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
            ;;
    esac
    
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции с $found_compiler!"
        echo "Пробуем стандартный gcc..."
        gcc -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
        if [ $? -ne 0 ]; then
            echo "Ошибка компиляции!"
            exit 1
        fi
    fi
    
    echo "Компиляция успешно завершена с $found_compiler"
}

setup_directories() {
    echo "=== Настройка директорий ==="
    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
}

create_test_cases() {
    echo "=== Создание тестовых случаев ==="
    
    # Очищаем предыдущие тесты
    rm -f "$INPUT_DIR"/*
    
    # Базовые тесты для всех операций
    echo "1 1" > "$INPUT_DIR/test1"    # Удаление узла с id=1
    echo "1 2" > "$INPUT_DIR/test2"    # Удаление узла с id=2  
    echo "1 3" > "$INPUT_DIR/test3"    # Удаление узла с id=3
    echo "1 99" > "$INPUT_DIR/test4"   # Удаление несуществующего узла
    
    echo "2 0" > "$INPUT_DIR/test5"    # Частичное уничтожение
    
    # Тесты для условных утечек
    echo "3 1" > "$INPUT_DIR/test6"    # condition1=false
    echo "3 6" > "$INPUT_DIR/test7"    # condition1=true, condition2=false
    echo "3 7" > "$INPUT_DIR/test8"    # condition1=true, condition2=true
    echo "3 15" > "$INPUT_DIR/test9"   # condition1=true, condition2=false
    
    # Тесты для рекурсивных утечек
    echo "4 0" > "$INPUT_DIR/test10"   # Рекурсия depth=0
    echo "4 1" > "$INPUT_DIR/test11"   # Рекурсия depth=1
    echo "4 5" > "$INPUT_DIR/test12"   # Рекурсия depth=5
    echo "4 10" > "$INPUT_DIR/test13"  # Рекурсия depth=10
    
    # Граничные значения
    echo "1 0" > "$INPUT_DIR/test14"   # Удаление с id=0
    echo "1 -1" > "$INPUT_DIR/test15"  # Удаление с отрицательным id
    echo "3 5" > "$INPUT_DIR/test16"   # Граница condition1
    echo "3 10" > "$INPUT_DIR/test17"  # Граница condition2
    
    echo "Создано 17 тестовых случаев"
}

create_wrapper_script() {
    echo "=== Создание wrapper скрипта ==="
    cat > fuzz_wrapper.sh << 'WRAPPER_EOF'
#!/bin/bash

# Читаем входные данные от afl-fuzz
INPUT_FILE="$1"
TEMP_FILE="/tmp/fuzz_input_$$.txt"

# Копируем входные данные для обработки
cp "$INPUT_FILE" "$TEMP_FILE" 2>/dev/null || exit 1

# Парсим входные данные
first_line=$(head -n 1 "$TEMP_FILE" 2>/dev/null)

if [ -n "$first_line" ]; then
    # Пытаемся извлечь два числа
    OPERATION=$(echo "$first_line" | awk '{print $1}')
    VALUE=$(echo "$first_line" | awk '{print $2}')
    
    # Проверяем валидность операции (1-4)
    if [ "$OPERATION" -ge 1 ] 2>/dev/null && [ "$OPERATION" -le 4 ] 2>/dev/null; then
        # Проверяем валидность значения
        if [ "$VALUE" -eq "$VALUE" ] 2>/dev/null; then
            ./prog_1_structs_ways "$OPERATION" "$VALUE"
        else
            # Если значение не число, используем 0
            ./prog_1_structs_ways "$OPERATION" 0
        fi
    else
        # Случайные данные - генерируем случайную операцию и значение
        RAND_OP=$((RANDOM % 4 + 1))
        RAND_VAL=$((RANDOM % 20))
        ./prog_1_structs_ways "$RAND_OP" "$RAND_VAL"
    fi
else
    # Пустой файл - используем значения по умолчанию
    ./prog_1_structs_ways 1 1
fi

# Очистка
rm -f "$TEMP_FILE" 2>/dev/null

exit 0
WRAPPER_EOF

    chmod +x fuzz_wrapper.sh
}

check_afl_installation() {
    echo "=== Проверка установки AFL++ ==="
    
    if ! command -v afl-fuzz &> /dev/null; then
        echo "AFL++ не найден в системе!"
        echo ""
        echo "Варианты установки:"
        echo "1. Ubuntu/Debian: sudo apt install afl++"
        echo "2. Вручную: https://github.com/AFLplusplus/AFLplusplus"
        echo ""
        echo "Можно использовать стандартный gcc для компиляции, но fuzzing будет ограничен"
        read -p "Продолжить без AFL++? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "AFL++ найден: $(afl-fuzz --version 2>/dev/null | head -n1 || echo 'версия неизвестна')"
    fi
}

run_fuzzing() {
    local mode="$1"
    
    echo "=== Запуск fuzzing тестирования ==="
    echo "Целевая программа: $PROGRAM_NAME"
    echo "Входная директория: $INPUT_DIR"
    echo "Выходная директория: $OUTPUT_DIR"
    echo ""
    
    # Проверяем существование программы
    if [ ! -f "./$PROGRAM_NAME" ]; then
        echo "Ошибка: программа $PROGRAM_NAME не найдена"
        echo "Сначала выполните: $0 setup"
        exit 1
    fi
    
    # Проверяем AFL++
    if ! command -v afl-fuzz &> /dev/null; then
        echo "AFL++ не установлен, используем альтернативный метод тестирования..."
        run_alternative_testing
        return
    fi
    
    case "$mode" in
        "master")
            echo "Запуск master процесса..."
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -M master -- ./fuzz_wrapper.sh @@
            ;;
        "slave")
            echo "Запуск slave процесса..."
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -S slave1 -- ./fuzz_wrapper.sh @@
            ;;
        *)
            echo "Запуск одиночного процесса fuzzing..."
            echo "Используемые параметры:"
            echo "  - Timeout: 5000ms"
            echo "  - Memory: 1024MB" 
            echo "  - Time: 24 hours"
            echo ""
            echo "Для остановки нажмите Ctrl+C"
            echo ""
            
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" \
                -t 5000 \
                -m 1024 \
                -V 86400 \
                -- ./fuzz_wrapper.sh @@
            ;;
    esac
}

run_alternative_testing() {
    echo "=== Альтернативное тестирование (без AFL++) ==="
    echo "Запуск тестовых случаев с Valgrind для обнаружения утечек..."
    echo ""
    
    for test_file in "$INPUT_DIR"/test*; do
        if [ -f "$test_file" ]; then
            echo "Тестируем: $(basename "$test_file")"
            echo "Содержимое: $(cat "$test_file")"
            echo "--- Результат Valgrind ---"
            timeout 10 valgrind --leak-check=summary --error-exitcode=1 ./fuzz_wrapper.sh "$test_file" 2>&1 | grep -E "ERROR SUMMARY|leak"
            echo "--- Завершено ---"
            echo ""
        fi
    done
    
    echo "Ручная проверка основных сценариев:"
    echo "1. Проверка утечек при удалении узлов..."
    valgrind --leak-check=full ./"$PROGRAM_NAME" 1 1 2>&1 | tail -n 10
    
    echo ""
    echo "2. Проверка частичного уничтожения..."
    valgrind --leak-check=full ./"$PROGRAM_NAME" 2 0 2>&1 | tail -n 10
    
    echo ""
    echo "3. Проверка условных утечек..."
    valgrind --leak-check=full ./"$PROGRAM_NAME" 3 7 2>&1 | tail -n 10
}

check_crashes() {
    echo "=== Проверка найденных крашей ==="
    
    local crash_dir=""
    
    # Ищем директорию с крашами
    for dir in "$OUTPUT_DIR/default/crashes" "$OUTPUT_DIR/master/crashes" "$OUTPUT_DIR/slave1/crashes"; do
        if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
            crash_dir="$dir"
            break
        fi
    done
    
    if [ -z "$crash_dir" ]; then
        echo "Краши не найдены"
        return 0
    fi
    
    echo "Найдены краши в директории: $crash_dir"
    echo ""
    
    local count=0
    for file in "$crash_dir"/id:*; do
        if [ -f "$file" ]; then
            count=$((count + 1))
            echo "Краш #$count: $file"
            echo "Содержимое:"
            cat "$file" 2>/dev/null || echo "(бинарные данные)"
            echo "--- Запуск программы ---"
            timeout 5 ./fuzz_wrapper.sh "$file"
            echo "--- Завершено (статус: $?) ---"
            echo ""
        fi
    done
    
    if [ $count -eq 0 ]; then
        echo "Файлы крашей не найдены"
    fi
}

monitor_fuzzing() {
    echo "=== Мониторинг прогресса fuzzing ==="
    
    if [ -f "$OUTPUT_DIR/master/fuzzer_stats" ]; then
        echo "=== Master Statistics ==="
        afl-whatsup "$OUTPUT_DIR"
    elif [ -f "$OUTPUT_DIR/default/fuzzer_stats" ]; then
        echo "=== Fuzzer Statistics ==="
        afl-whatsup "$OUTPUT_DIR"
    else
        echo "Статистика fuzzing не найдена"
        echo "Запустите fuzzing сначала: $0 fuzz"
    fi
}

run_valgrind_check() {
    echo "=== Проверка утечек с Valgrind ==="
    echo "Тестирование различных сценариев..."
    echo ""
    
    echo "1. Операция 1 (удаление узла):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 1 2
    
    echo ""
    echo "2. Операция 2 (частичное уничтожение):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 2 0
    
    echo ""
    echo "3. Операция 3 (условная утечка):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 3 7
    
    echo ""
    echo "4. Операция 4 (рекурсивная утечка):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 4 3
}

cleanup() {
    echo "=== Очистка ==="
    rm -f "$PROGRAM_NAME" fuzz_wrapper.sh
    echo "Очистка завершена"
}

show_usage() {
    echo "Использование: $0 [команда]"
    echo ""
    echo "Команды:"
    echo "  setup       - Настройка окружения (компиляция + создание тестов)"
    echo "  fuzz        - Запуск fuzzing (одиночный режим)"
    echo "  master      - Запуск master процесса"
    echo "  slave       - Запуск slave процесса"  
    echo "  monitor     - Просмотр статистики fuzzing"
    echo "  check       - Проверка найденных крашей"
    echo "  valgrind    - Проверка утечек с Valgrind"
    echo "  clean       - Очистка скомпилированных файлов"
    echo "  all         - Полный цикл (setup + fuzz)"
    echo ""
    echo "Примеры:"
    echo "  $0 setup     # Настройка окружения"
    echo "  $0 fuzz      # Запуск fuzzing"
    echo "  $0 all       # Полный цикл"
}

# Основная логика
case "${1:-}" in
    "setup")
        check_afl_installation
        compile_program
        setup_directories
        create_test_cases
        create_wrapper_script
        echo ""
        echo "=== Настройка завершена ==="
        ;;
    "fuzz")
        run_fuzzing "single"
        ;;
    "master")
        run_fuzzing "master"
        ;;
    "slave")
        run_fuzzing "slave"
        ;;
    "monitor")
        monitor_fuzzing
        ;;
    "check")
        check_crashes
        ;;
    "valgrind")
        run_valgrind_check
        ;;
    "clean")
        cleanup
        ;;
    "all")
        echo "=== ЗАПУСК ПОЛНОГО ЦИКЛА ТЕСТИРОВАНИЯ ==="
        check_afl_installation
        compile_program
        setup_directories
        create_test_cases
        create_wrapper_script
        echo ""
        echo "Настройка завершена."
        if command -v afl-fuzz &> /dev/null; then
            echo "Запуск fuzzing через 3 секунды..."
            sleep 3
            run_fuzzing "single"
        else
            echo "Запуск альтернативного тестирования..."
            run_alternative_testing
        fi
        ;;
    "")
        show_usage
        ;;
    *)
        echo "Неизвестная команда: $1"
        show_usage
        exit 1
        ;;
esac