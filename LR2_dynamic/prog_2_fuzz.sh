#!/bin/bash

set -e  # Завершать скрипт при ошибках

# Функции
compile_program() {
    echo "=== Компиляция программы ==="
    afl-gcc-fast -fsanitize=address -g -o prog_2_files_cache prog_2_files_cache.c -lpthread
    
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции!"
        exit 1
    fi
    echo "Компиляция успешно завершена"
}

setup_directories() {
    echo "=== Настройка директорий ==="
    mkdir -p prog_2_test_inputs prog_2_test_outputs test_files
}

create_test_cases() {
    echo "=== Создание тестовых случаев ==="
    # Базовые тесты
    echo "1" > prog_2_test_inputs/test1
    echo "2" > prog_2_test_inputs/test2  
    echo "3" > prog_2_test_inputs/test3
    echo "4" > prog_2_test_inputs/test4
    
    # Тесты с файлами
    echo "2 /etc/passwd" > prog_2_test_inputs/test5
    echo "4 /etc/hosts" > prog_2_test_outputs/test6
    echo "2 /dev/null" > prog_2_test_inputs/test7
    
    # Создаем тестовые файлы
    echo "This is a test file for fuzzing" > test_files/simple.txt
    echo -e "Line 1\nLine 2\nLine 3" > test_files/multiline.txt
    dd if=/dev/urandom of=test_files/random.dat bs=1024 count=10 2>/dev/null
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

    chmod +x fuzz_wrapper.sh
}

run_fuzzing() {
    local mode="$1"
    
    echo "=== Запуск AFL++ fuzzing тестирования ==="
    echo "Целевая программа: prog_2_files_cache"
    echo "Входная директория: prog_2_test_inputs"
    echo "Выходная директория: prog_2_test_outputs"
    echo ""
    
    case "$mode" in
        "master")
            echo "Запуск master процесса..."
            afl-fuzz -i prog_2_test_inputs -o prog_2_test_outputs -M master -- ./fuzz_wrapper.sh @@
            ;;
        "slave")
            echo "Запуск slave процесса..."
            afl-fuzz -i prog_2_test_inputs -o prog_2_test_outputs -S slave1 -- ./fuzz_wrapper.sh @@
            ;;
        *)
            echo "Запуск одиночного процесса fuzzing с увеличенными лимитами..."
            afl-fuzz -i prog_2_test_inputs -o prog_2_test_outputs \
                -t 5000 \
                -m 1024 \
                -V 86400 \
                -- ./fuzz_wrapper.sh @@
            ;;
    esac
}

check_crashes() {
    echo "=== Проверка найденных крашей ==="
    
    local crash_dir=""
    
    if [ -d "prog_2_test_outputs/default/crashes" ]; then
        crash_dir="prog_2_test_outputs/default/crashes"
    elif [ -d "prog_2_test_outputs/master/crashes" ]; then
        crash_dir="prog_2_test_outputs/master/crashes"
    else
        echo "Директория с крашами не найдена"
        return 1
    fi
    
    if [ -z "$(ls -A "$crash_dir" 2>/dev/null)" ]; then
        echo "Краши не найдены"
        return 0
    fi
    
    echo "Найдены следующие краши:"
    for file in "$crash_dir"/id*; do
        if [ -f "$file" ]; then
            echo "Тестируем: $file"
            echo "Содержимое:"
            cat "$file"
            echo "--- Запуск программы ---"
            ./fuzz_wrapper.sh "$file"
            echo "--- Завершено ---"
            echo ""
        fi
    done
}

monitor_fuzzing() {
    echo "=== Мониторинг прогресса fuzzing ==="
    
    if [ -f "prog_2_test_outputs/master/fuzzer_stats" ]; then
        echo "=== Master Statistics ==="
        afl-whatsup prog_2_test_outputs
    elif [ -f "prog_2_test_outputs/default/fuzzer_stats" ]; then
        echo "=== Fuzzer Statistics ==="
        afl-whatsup prog_2_test_outputs
    else
        echo "Статистика fuzzing не найдена"
        echo "Запустите fuzzing сначала"
    fi
}

run_valgrind_check() {
    echo "=== Проверка утечек с Valgrind ==="
    valgrind --leak-check=full --show-leak-kinds=all ./prog_2_files_cache 1
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
        compile_program
        setup_directories
        create_test_cases
        create_wrapper_script
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
    "all")
        echo "=== ЗАПУСК ПОЛНОГО ЦИКЛА FUZZING ==="
        compile_program
        setup_directories
        create_test_cases
        create_wrapper_script
        echo ""
        echo "Настройка завершена. Запуск fuzzing через 3 секунды..."
        sleep 3
        run_fuzzing "single"
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