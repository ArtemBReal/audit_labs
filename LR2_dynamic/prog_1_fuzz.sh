#!/bin/bash

set -e  # Завершать скрипт при ошибках

# Конфигурация
PROGRAM_NAME="prog_1_structs_ways"
INPUT_DIR="prog_1_test_inputs"
OUTPUT_DIR="prog_1_test_outputs"

# Функции
check_system_config() {
    echo "=== Проверка конфигурации системы ==="
    
    # Проверяем core_pattern
    if [ -f "/proc/sys/kernel/core_pattern" ]; then
        local core_pattern=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
        
        if [ "$core_pattern" != "core" ] && [[ "$core_pattern" != core* ]]; then
            echo "ВНИМАНИЕ: systemd-coredump обнаружен (core_pattern: $core_pattern)"
            echo "Это может замедлить обнаружение крашей AFL++"
            echo ""
        else
            echo "Конфигурация core dump корректна: $core_pattern"
        fi
    fi
    echo ""
}

compile_program() {
    echo "=== Компиляция программы ==="
    echo "Поиск компиляторов AFL++..."
    
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
        echo "Установите AFL++: sudo apt install afl++"
        exit 1
    fi
    
    echo "Используется компилятор: $found_compiler"
    
    # Компилируем основную программу
    case "$found_compiler" in
        *clang*)
            echo "Компиляция с clang и AddressSanitizer..."
            $found_compiler -fsanitize=address -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
            ;;
        *)
            echo "Компиляция программы..."
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
    
    # Компилируем C-враппер
    echo "Компиляция C-враппера..."
    gcc -o prog_1_fuzz_wrapper prog_1_fuzz_wrapper.c
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции C-враппера!"
        exit 1
    fi
    
    echo "Компиляция успешно завершена"
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
    
    # Дополнительные случайные тесты
    echo "1 42" > "$INPUT_DIR/test18"  # Случайный ID
    echo "3 8" > "$INPUT_DIR/test19"   # Граничное значение
    echo "4 2" > "$INPUT_DIR/test20"   # Небольшая рекурсия
    
    echo "Создано 20 тестовых случаев в директории $INPUT_DIR"
}

create_c_wrapper() {
    echo "=== Создание C-враппера ==="
    cat > prog_1_fuzz_wrapper.c << 'C_WRAPPER_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_INPUT_SIZE 1024

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <input_file>\n", argv[0]);
        return 1;
    }
    
    FILE *file = fopen(argv[1], "r");
    if (!file) {
        return 1;
    }
    
    char buffer[MAX_INPUT_SIZE];
    if (fgets(buffer, sizeof(buffer), file) == NULL) {
        fclose(file);
        // Если файл пустой, используем значения по умолчанию
        return system("./prog_1_structs_ways 1 1");
    }
    fclose(file);
    
    // Удаляем символ новой строки
    buffer[strcspn(buffer, "\n")] = 0;
    
    // Парсим входные данные
    int operation = 0;
    int value = 0;
    
    if (sscanf(buffer, "%d %d", &operation, &value) == 2) {
        // Оба значения успешно прочитаны
        if (operation >= 1 && operation <= 4) {
            char command[256];
            snprintf(command, sizeof(command), "./prog_1_structs_ways %d %d", operation, value);
            return system(command);
        }
    } else if (sscanf(buffer, "%d", &operation) == 1) {
        // Только операция прочитана
        if (operation >= 1 && operation <= 4) {
            char command[256];
            snprintf(command, sizeof(command), "./prog_1_structs_ways %d 0", operation);
            return system(command);
        }
    }
    
    // Случайные данные - генерируем случайную операцию и значение
    int random_op = (rand() % 4) + 1;
    int random_val = rand() % 20;
    
    char command[256];
    snprintf(command, sizeof(command), "./prog_1_structs_ways %d %d", random_op, random_val);
    return system(command);
}
C_WRAPPER_EOF

    echo "C-враппер создан"
}

check_afl_installation() {
    echo "=== Проверка установки AFL++ ==="
    
    if ! command -v afl-fuzz &> /dev/null; then
        echo "Ошибка: AFL++ не найден в системе!"
        echo ""
        echo "Установите AFL++:"
        echo "  Ubuntu/Debian: sudo apt install afl++"
        echo "  Или из исходников: https://github.com/AFLplusplus/AFLplusplus"
        exit 1
    else
        echo "AFL++ найден: $(afl-fuzz --version 2>/dev/null | head -n1 || echo 'версия неизвестна')"
    fi
}

run_fuzzing() {
    local mode="$1"
    
    echo "=== Запуск AFL++ fuzzing ==="
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
    
    # Проверяем C-враппер
    if [ ! -f "./prog_1_fuzz_wrapper" ]; then
        echo "Ошибка: C-враппер не найден"
        echo "Сначала выполните: $0 setup"
        exit 1
    fi
    
    # Устанавливаем переменную для игнорирования предупреждений о core dump
    export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
    echo "Установлена переменная AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1"
    echo ""
    
    case "$mode" in
        "master")
            echo "Запуск master процесса..."
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -M master -- ./prog_1_fuzz_wrapper @@
            ;;
        "slave")
            echo "Запуск slave процесса..."
            afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -S slave1 -- ./prog_1_fuzz_wrapper @@
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
                -- ./prog_1_fuzz_wrapper @@
            ;;
    esac
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
            timeout 5 ./prog_1_fuzz_wrapper "$file"
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
    elif [ -f "$OUTPUT_DIR/slave1/fuzzer_stats" ]; then
        echo "=== Slave1 Statistics ==="
        afl-whatsup "$OUTPUT_DIR"
    else
        echo "Статистика fuzzing не найдена"
        echo "Запустите fuzzing сначала: $0 fuzz"
        echo "Или проверьте директорию: $OUTPUT_DIR"
    fi
}

cleanup() {
    echo "=== Очистка ==="
    rm -f "$PROGRAM_NAME" prog_1_fuzz_wrapper prog_1_fuzz_wrapper.c
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
        create_c_wrapper
        compile_program
        setup_directories
        create_test_cases
        echo ""
        echo "=== Настройка завершена ==="
        echo "Созданы:"
        echo "  - Основная программа: $PROGRAM_NAME"
        echo "  - C-враппер: prog_1_fuzz_wrapper"
        echo "  - Тестовые случаи: 20 штук в $INPUT_DIR"
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
    "clean")
        cleanup
        ;;
    "all")
        echo "=== ЗАПУСК ПОЛНОГО ЦИКЛА FUZZING ==="
        check_system_config
        check_afl_installation
        create_c_wrapper
        compile_program
        setup_directories
        create_test_cases
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