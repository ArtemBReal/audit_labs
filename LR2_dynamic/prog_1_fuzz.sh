#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Конфигурация
# ----------------------------------------
#PROGRAM_NAME="prog_1_structs_ways"
PROGRAM_NAME="prog_1_structs_ways_fuzz"
INPUT_DIR="prog_1_test_inputs"
OUTPUT_DIR="prog_1_test_outputs"

# ----------------------------------------
# Утилиты
# ----------------------------------------
log() { printf '%s\n' "$*"; }

check_afl_installation() {
    if ! command -v afl-fuzz &>/dev/null; then
        log "AFL++ не найден. Установите его: sudo apt install afl++"
        exit 1
    fi
    log "AFL++ найден ($(afl-fuzz --version 2>/dev/null || echo 'unknown'))"
}

# ----------------------------------------
# Компиляция программы
# ----------------------------------------
compile_program() {
    log "Поиск компилятора AFL++…"
    if command -v afl-clang-fast &>/dev/null; then
        CC=afl-clang-fast
    elif command -v afl-clang &>/dev/null; then
        CC=afl-clang
    else
        log "Не найден ни afl-clang-fast, ни afl-clang."
        exit 1
    fi

    log "Компилируем с $CC ..."
    $CC -O1 -g \
        -fsanitize-coverage=trace-pc-guard,trace-pc \
        -fno-inline -fno-omit-frame-pointer \
        -o "$PROGRAM_NAME" "$PROGRAM_NAME".c
    log "Бинарник $PROGRAM_NAME готов."
}

# ----------------------------------------
# Создание/очистка директорий
# ----------------------------------------
setup_directories() {
    log "Создаём директории для входов и выходов…"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR"
    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
}

# ----------------------------------------
# Генерация тестовых файлов
# ----------------------------------------
create_test_cases() {
    log "Генерируем 1000 тестовых файлов…"

    for i in $(seq 1 1000); do
        # 20 % «плохих» тестов
        if (( RANDOM % 5 == 0 )); then
            case $((RANDOM % 5)) in
                0)  : > "$INPUT_DIR/input_$i"                      ;; # пустой
                1)  echo "$((1 + RANDOM % 4))" > "$INPUT_DIR/input_$i" ;; # только операция
                2)  echo "$((1 + RANDOM % 4)) abc" > "$INPUT_DIR/input_$i" ;; # строка без цифр
                3)  echo "$((1 + RANDOM % 4)) 42 extra" > "$INPUT_DIR/input_$i" ;; # лишний аргумент
                4)  echo "abc def" > "$INPUT_DIR/input_$i"                ;; # строка без чисел вообще
            esac
        else
            # 80 % валидных тестов
            op=$((1 + RANDOM % 4))
            val=$((RANDOM % 200 - 50))
            echo "$op $val" > "$INPUT_DIR/input_$i"
        fi
    done

    log "1000 файлов созданы в $INPUT_DIR"
}

# ----------------------------------------
# Очистка
# ----------------------------------------
cleanup() {
    log "🧹  Удаляем всё, что было создано…"
    rm -f "$PROGRAM_NAME"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR"
    log "Очистка завершена."
}

# ----------------------------------------
# Показать помощь
# ----------------------------------------
show_usage() {
    cat <<'EOF'
Использование:
  ./prog_1_fuzz.sh setup   - Создать директории, компилировать программу и генерировать 1000 тестов
  ./prog_1_fuzz.sh clean   - Удалить всё, что было создано
  ./prog_1_fuzz.sh fuzz    - Запустить фаззинг
EOF
}

# ----------------------------------------
# Запуск фаззинга
# ----------------------------------------
fuzz_test() {
    export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
    export AFL_SKIP_BIN_CHECK=1
    log "Запуск фаззинга:"
    # Файл‑тест передаётся как два аргумента через обёртку sh -c
    afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" \
        -- sh -c 'x=$(cat "$1"); set -- $x; ./"'"$PROGRAM_NAME"'" "$@"' _ @@
}

# ----------------------------------------
# Основная логика
# ----------------------------------------
case "${1:-}" in
    setup)
        check_afl_installation
        compile_program
        setup_directories
        create_test_cases
        echo
        echo "Подготовка завершена."
        ;;
    fuzz)
        fuzz_test
        ;;
    clean)
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