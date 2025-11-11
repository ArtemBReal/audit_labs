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
    echo "=== Компиляция программы с инструментацией AFL++ ==="
    echo "Поиск компиляторов AFL++..."
    
    # Пробуем разные компиляторы по порядку
    local compilers=("afl-gcc-fast" "afl-gcc" "afl-clang-fast" "afl-clang")
    local found_compiler=""
    
    for compiler in "${compilers[@]}"; do
        if command -v "$compiler" &> /dev/null; then
            echo "Найден компилятор AFL++: $compiler"
            found_compiler="$compiler"
            break
        fi
    done
    
    if [ -z "$found_compiler" ]; then
        echo "Ошибка: не найден компилятор AFL++!"
        echo "Установите AFL++: sudo apt install afl++"
        echo "Или используйте QEMU режим: $0 qemu"
        exit 1
    fi
    
    echo "Используется компилятор: $found_compiler"
    
    # Компилируем основную программу с инструментацией AFL++
    case "$found_compiler" in
        *clang*)
            echo "Компиляция с afl-clang и AddressSanitizer..."
            $found_compiler -fsanitize=address -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
            ;;
        *)
            echo "Компиляция с инструментацией AFL++..."
            $found_compiler -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
            ;;
    esac
    
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции с $found_compiler!"
        exit 1
    fi
    
    # Компилируем C-враппер обычным gcc (ему не нужна инструментация)
    echo "Компиляция C-враппера..."
    gcc -o prog_2_fuzz_wrapper prog_2_fuzz_wrapper.c
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции C-враппера!"
        exit 1
    fi
    
    echo "Компиляция успешно завершена"
}

compile_with_qemu() {
    echo "=== Компиляция для QEMU режима ==="
    
    # Компилируем обычным gcc для QEMU режима
    echo "Компиляция программы стандартным gcc..."
    gcc -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
    
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции!"
        exit 1
    fi
    
    # Компилируем C-враппер
    echo "Компиляция C-враппера..."
    gcc -o prog_2_fuzz_wrapper prog_2_fuzz_wrapper.c
    if [ $? -ne 0 ]; then
        echo "Ошибка компиляции C-враппера!"
        exit 1
    fi
    
    echo "Компиляция для QEMU режима завершена"
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
    
    echo "Создано 11 тестовых случаев в директории $INPUT_DIR"
}

create_c_wrapper() {
    echo "=== Создание C-враппера ==="
    cat > prog_2_fuzz_wrapper.c << 'C_WRAPPER_EOF'
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
        return system("./prog_2_files_cache 1");
    }
    fclose(file);
    
    // Удаляем символ новой строки
    buffer[strcspn(buffer, "\n")] = 0;
    
    // Парсим входные данные
    int mode = 0;
    char filename[256] = "";
    
    if (sscanf(buffer, "%d %255s", &mode, filename) == 2) {
        // Оба значения успешно прочитаны
        if (mode >= 1 && mode <= 4) {
            char command[512];
            snprintf(command, sizeof(command), "./prog_2_files_cache %d \"%s\"", mode, filename);
            return system(command);
        }
    } else if (sscanf(buffer, "%d", &mode) == 1) {
        // Только режим прочитан
        if (mode >= 1 && mode <= 4) {
            char command[256];
            snprintf(command, sizeof(command), "./prog_2_files_cache %d", mode);
            return system(command);
        }
    }
    
    // Случайные данные - генерируем случайный режим
    int random_mode = (rand() % 4) + 1;
    
    char command[256];
    snprintf(command, sizeof(command), "./prog_2_files_cache %d", random_mode);
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
        exit 1
    else
        echo "AFL++ найден: $(afl-fuzz --version 2>/dev/null | head -n1 || echo 'версия неизвестна')"
    fi
}

run_fuzzing() {
    local mode="$1"
    local use_qemu="$2"
    
    echo "=== Запуск AFL++ fuzzing ==="
    echo "Целевая программа: $PROGRAM_NAME"
    echo "Входная директория: $INPUT_DIR"
    echo "Выходная директория: $OUTPUT_DIR"
    
    if [ "$use_qemu" = "qemu" ]; then
        echo "Режим: QEMU (без инструментации)"
    else
        echo "Режим: инструментированный бинарник"
    fi
    echo ""
    
    # Проверяем существование программы
    if [ ! -f "./$PROGRAM_NAME" ]; then
        echo "Ошибка: программа $PROGRAM_NAME не найдена"
        echo "Сначала выполните: $0 setup"
        exit 1
    fi
    
    # Проверяем C-враппер
    if [ ! -f "./prog_2_fuzz_wrapper" ]; then
        echo "Ошибка: C-враппер не найден"
        echo "Сначала выполните: $0 setup"
        exit 1
    fi
    
    # Устанавливаем переменную для игнорирования предупреждений о core dump
    export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
    
    # Базовые параметры AFL++
    local afl_params=(
        -i "$INPUT_DIR"
        -o "$OUTPUT_DIR"
        -t 5000
        -m 1024
        -V 86400
    )
    
    # Добавляем QEMU режим если нужно
    if [ "$use_qemu" = "qemu" ]; then
        afl_params+=(-Q)
        echo "Используется QEMU режим (-Q)"
    fi
    
    case "$mode" in
        "master")
            echo "Запуск master процесса..."
            afl-fuzz "${afl_params[@]}" -M master -- ./prog_2_fuzz_wrapper @@
            ;;
        "slave")
            echo "Запуск slave процесса..."
            afl-fuzz "${afl_params[@]}" -S slave1 -- ./prog_2_fuzz_wrapper @@
            ;;
        *)
            echo "Запуск одиночного процесса fuzzing..."
            echo "Используемые параметры:"
            echo "  - Timeout: 5000ms"
            echo "  - Memory: 1024MB" 
            echo "  - Time: 24 hours"
            if [ "$use_qemu" = "qemu" ]; then
                echo "  - QEMU mode: enabled"
            fi
            echo ""
            echo "Для остановки нажмите Ctrl+C"
            echo ""
            
            afl-fuzz "${afl_params[@]}" -- ./prog_2_fuzz_wrapper @@
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
            timeout 5 ./prog_2_fuzz_wrapper "$file"
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
    rm -f "$PROGRAM_NAME" prog_2_fuzz_wrapper prog_2_fuzz_wrapper.c
    rm -rf test_files
    echo "Очистка завершена"
}

show_usage() {
    echo "Использование: $0 [команда]"
    echo ""
    echo "Команды:"
    echo "  setup       - Настройка с инструментацией AFL++"
    echo "  qemu        - Настройка для QEMU режима"
    echo "  fuzz        - Запуск fuzzing (инструментированный)"
    echo "  fuzz-qemu   - Запуск fuzzing в QEMU режиме"
    echo "  master      - Запуск master процесса"
    echo "  slave       - Запуск slave процесса"  
    echo "  monitor     - Просмотр статистики fuzzing"
    echo "  check       - Проверка найденных крашей"
    echo "  clean       - Очистка скомпилированных файлов"
    echo ""
    echo "Примеры:"
    echo "  $0 setup     # Настройка с инструментацией"
    echo "  $0 qemu      # Настройка для QEMU режима"
    echo "  $0 fuzz      # Запуск fuzzing"
    echo "  $0 fuzz-qemu # Запуск в QEMU режиме"
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
        echo "  - Инструментированная программа: $PROGRAM_NAME"
        echo "  - C-враппер: prog_2_fuzz_wrapper"
        echo "  - Тестовые случаи: 11 штук в $INPUT_DIR"
        ;;
    "qemu")
        check_system_config
        check_afl_installation
        create_c_wrapper
        compile_with_qemu
        setup_directories
        create_test_cases
        echo ""
        echo "=== Настройка для QEMU режима завершена ==="
        echo "Созданы:"
        echo "  - Программа для QEMU: $PROGRAM_NAME"
        echo "  - C-враппер: prog_2_fuzz_wrapper"
        echo "  - Тестовые случаи: 11 штук в $INPUT_DIR"
        ;;
    "fuzz")
        run_fuzzing "single" "normal"
        ;;
    "fuzz-qemu")
        run_fuzzing "single" "qemu"
        ;;
    "master")
        run_fuzzing "master" "normal"
        ;;
    "slave")
        run_fuzzing "slave" "normal"
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
    "")
        show_usage
        ;;
    *)
        echo "Неизвестная команда: $1"
        show_usage
        exit 1
        ;;
esac