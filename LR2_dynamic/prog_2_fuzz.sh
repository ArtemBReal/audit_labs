#!/bin/bash

set -e  # Завершать скрипт при ошибках

# Конфигурация
PROGRAM_NAME="prog_2_files_cache"
INPUT_DIR="prog_2_test_inputs"
OUTPUT_DIR="prog_2_test_outputs"

# Функции
check_system_config() {
    echo "=== Проверка конфигурации системы ==="
    
    # Проверяем core_pattern
    local core_pattern=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
    
    if [ "$core_pattern" != "core" ] && [[ "$core_pattern" != core* ]]; then
        echo "ВНИМАНИЕ: systemd-coredump обнаружен (core_pattern: $core_pattern)"
        echo "Это может замедлить обнаружение крашей AFL++"
        echo ""
        echo "Варианты решения:"
        echo "1. Временное отключение: sudo bash -c 'echo core > /proc/sys/kernel/core_pattern'"
        echo "2. Игнорировать предупреждение: export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1"
        echo ""
        
        # Предлагаем пользователю выбор
        read -p "Выберите действие: [1] временное отключение, [2] игнорировать, [3] продолжить как есть: " -n 1 -r
        echo
        case $REPLY in
            1)
                echo "Временное отключение systemd-coredump..."
                sudo bash -c 'echo core > /proc/sys/kernel/core_pattern'
                ;;
            2)
                echo "Игнорирование предупреждения..."
                export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
                ;;
            *)
                echo "Продолжаем с текущими настройками (возможны задержки)"
                ;;
        esac
    else
        echo "Конфигурация core dump корректна"
    fi
    echo ""
}

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
            $found_compiler -fsanitize=address -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
            ;;
        *gcc*)
            if [[ "$found_compiler" == *fast* ]]; then
                echo "Компиляция с afl-gcc-fast..."
                $found_compiler -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
            else
                echo "Компиляция с стандартным gcc..."
                $found_compiler -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
            fi
            ;;
        *)
            echo "Компиляция с стандартными флагами..."
            $found_compiler -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
            ;;
    esac
    
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции с $found_compiler!"
        echo "Пробуем стандартный gcc..."
        gcc -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
        if [ $? -ne 0 ]; then
            echo "Ошибка компиляции!"
            exit 1
        fi
    fi
    
    echo "Компиляция успешно завершена с $found_compiler"
}

setup_directories() {
    echo "=== Настройка директорий ==="
    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" test_files
}

create_test_cases() {
    echo "=== Создание тестовых случаев ==="
    
    # Очищаем предыдущие тесты
    rm -f "$INPUT_DIR"/*
    
    # Базовые тесты
    echo "1" > "$INPUT_DIR/test1"
    echo "2" > "$INPUT_DIR/test2"  
    echo "3" > "$INPUT_DIR/test3"
    echo "4" > "$INPUT_DIR/test4"
    
    # Тесты с файлами
    echo "2 /etc/passwd" > "$INPUT_DIR/test5"
    echo "4 /etc/hosts" > "$INPUT_DIR/test6"
    echo "2 /dev/null" > "$INPUT_DIR/test7"
    
    # Дополнительные тесты для лучшего покрытия
    echo "1" > "$INPUT_DIR/test8"
    echo "2 ./test_files/simple.txt" > "$INPUT_DIR/test9"
    echo "3" > "$INPUT_DIR/test10"
    echo "4 ./test_files/multiline.txt" > "$INPUT_DIR/test11"
    
    # Создаем тестовые файлы
    echo "This is a test file for fuzzing" > test_files/simple.txt
    echo -e "Line 1\nLine 2\nLine 3" > test_files/multiline.txt
    echo "Short" > test_files/short.txt
    dd if=/dev/urandom of=test_files/random.dat bs=1024 count=10 2>/dev/null
    
    echo "Создано 11 тестовых случаев"
}

create_wrapper_script() {
    echo "=== Создание wrapper скрипта ==="
    cat > prog_2_fuzz_wrapper.sh << 'WRAPPER_EOF'
#!/bin/bash

# Читаем входные данные от afl-fuzz
INPUT_FILE="$1"
TEMP_FILE="/tmp/fuzz_input_$$.txt"

# Копируем входные данные для обработки
cp "$INPUT_FILE" "$TEMP_FILE" 2>/dev/null || exit 1

# Парсим входные данные - могут быть в разных форматах
first_char=$(head -c 1 "$TEMP_FILE" 2>/dev/null)

# Определяем режим на основе входных данных
case "$first_char" in
    "1"|"2"|"3"|"4")
        # Формат: "mode" или "mode filename"
        MODE=$(head -n 1 "$TEMP_FILE" | cut -d' ' -f1)
        FILENAME=$(head -n 1 "$TEMP_FILE" | cut -d' ' -f2-)
        
        if [ -n "$FILENAME" ] && [ "$MODE" = "2" -o "$MODE" = "4" ]; then
            # Проверяем существование файла, если указан
            if [ -f "$FILENAME" ]; then
                ./prog_2_files_cache "$MODE" "$FILENAME"
            else
                # Создаем временный файл для тестирования
                TEMP_TEST_FILE="/tmp/test_file_$$.txt"
                head -c 100 "$TEMP_FILE" 2>/dev/null > "$TEMP_TEST_FILE"
                ./prog_2_files_cache "$MODE" "$TEMP_TEST_FILE"
                rm -f "$TEMP_TEST_FILE" 2>/dev/null
            fi
        else
            ./prog_2_files_cache "$MODE"
        fi
        ;;
    *)
        # Случайные данные - генерируем случайный режим
        MODE=$((RANDOM % 4 + 1))
        if [ $MODE -eq 2 -o $MODE -eq 4 ]; then
            # Создаем временный файл с содержимым входных данных
            TEMP_TEST_FILE="/tmp/fuzz_file_$$.txt"
            head -c 1000 "$TEMP_FILE" 2>/dev/null > "$TEMP_TEST_FILE"
            ./prog_2_files_cache "$MODE" "$TEMP_TEST_FILE"
            rm -f "$TEMP_TEST_FILE" 2>/dev/null
        else
            ./prog_2_files_cache "$MODE"
        fi
        ;;
esac

# Очистка
rm -f "$TEMP_FILE" 2>/dev/null

exit 0
WRAPPER_EOF

    chmod +x prog_2_fuzz_wrapper.sh
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
    
    # Устанавливаем переменную для игнорирования предупреждений о core dump
    export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
    
    case "$mode" in
        "master")
            echo "Запуск master процесса..."
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -M master -- ./prog_2_fuzz_wrapper.sh @@
            ;;
        "slave")
            echo "Запуск slave процесса..."
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -S slave1 -- ./prog_2_fuzz_wrapper.sh @@
            ;;
        *)
            echo "Запуск одиночного процесса fuzzing..."
            echo "Используемые параметры:"
            echo "  - Timeout: 5000ms"
            echo "  - Memory: 1024MB" 
            echo "  - Time: 24 hours"
            echo "  - AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 (для обхода systemd-coredump)"
            echo ""
            echo "Для остановки нажмите Ctrl+C"
            echo ""
            
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" \
                -t 5000 \
                -m 1024 \
                -V 86400 \
                -- ./prog_2_fuzz_wrapper.sh @@
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
            timeout 10 valgrind --leak-check=summary --error-exitcode=1 ./prog_2_fuzz_wrapper.sh "$test_file" 2>&1 | grep -E "ERROR SUMMARY|leak" || true
            echo "--- Завершено ---"
            echo ""
        fi
    done
    
    echo "Ручная проверка основных сценариев:"
    echo "1. Режим 1 (тестирование кэша)..."
    valgrind --leak-check=full ./"$PROGRAM_NAME" 1 2>&1 | tail -n 10
    
    echo ""
    echo "2. Режим 2 (обработка файла)..."
    valgrind --leak-check=full ./"$PROGRAM_NAME" 2 "./test_files/simple.txt" 2>&1 | tail -n 10
    
    echo ""
    echo "3. Режим 3 (циклический буфер)..."
    valgrind --leak-check=full ./"$PROGRAM_NAME" 3 2>&1 | tail -n 10
    
    echo ""
    echo "4. Режим 4 (комбинированный)..."
    valgrind --leak-check=full ./"$PROGRAM_NAME" 4 "./test_files/multiline.txt" 2>&1 | tail -n 10
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
    for file in "$crash_dir"/id:* "$crash_dir"/id*; do
        if [ -f "$file" ]; then
            count=$((count + 1))
            echo "Краш #$count: $file"
            echo "Содержимое:"
            cat "$file" 2>/dev/null || echo "(бинарные данные)"
            echo "--- Запуск программы ---"
            timeout 5 ./prog_2_fuzz_wrapper.sh "$file"
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
    
    echo "1. Режим 1 (тестирование кэша):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 1
    
    echo ""
    echo "2. Режим 2 (обработка файла):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 2 "./test_files/simple.txt"
    
    echo ""
    echo "3. Режим 3 (циклический буфер):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 3
    
    echo ""
    echo "4. Режим 4 (комбинированный):"
    valgrind --leak-check=full --show-leak-kinds=all ./"$PROGRAM_NAME" 4 "./test_files/multiline.txt"
}

cleanup() {
    echo "=== Очистка ==="
    rm -f "$PROGRAM_NAME" prog_2_fuzz_wrapper.sh
    rm -rf test_files
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
        check_system_config
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
        check_system_config
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