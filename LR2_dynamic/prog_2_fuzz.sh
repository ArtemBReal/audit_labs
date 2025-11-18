#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------
# prog_2_fuzz.sh – скрипт для AFL++ «прямого» фаззинга prog_2_files_cache.c
# --------------------------------------------------------------------

# ---------- Конфигурация ----------
#PROGRAM_NAME="prog_2_files_cache"
PROGRAM_NAME="prog_2_files_cache_fuzz"
INPUT_DIR="prog_2_test_inputs"
OUTPUT_DIR="prog_2_test_outputs"
TEST_DIR="test_files"

# ---------- Утилиты ----------
log() { printf '%s\n' "$*"; }

check_afl_installation() {
    if ! command -v afl-fuzz &>/dev/null; then
        log "AFL++ не найден. Установите его: sudo apt install afl++"
        exit 1
    fi
    log "AFL++ найден ($(afl-fuzz --version 2>/dev/null || echo 'unknown'))"
}

# ---------- Компиляция программы ----------
compile_program() {
    log "Поиск компилятора AFL++…"
    for c in afl-clang-fast afl-clang; do
        if command -v "$c" &>/dev/null; then
            CC=$c
            break
        fi
    done

    if [[ -z ${CC:-} ]]; then
        log "Не найден ни afl-clang-fast, ни afl-clang."
        exit 1
    fi

    log "Используем компилятор: $CC"
    log "Компиляция с instrumentation…"
    #  -O1, -g – удобно отладка и небольшая скорость
    #  -fsanitize-coverage=trace-pc-guard,trace-pc – покрытие
    #  -fno-inline – не инлайнить, чтобы проще увидеть трассы
    #  -fno-omit-frame-pointer – оставляем FP для ASan‑поддержки
    $CC -O1 -g \
        -fsanitize-coverage=trace-pc-guard,trace-pc \
        -fno-inline -fno-omit-frame-pointer \
        -o "$PROGRAM_NAME" "$PROGRAM_NAME".c -lpthread
    log "Бинарник $PROGRAM_NAME готов."
}

# ---------- Подготовка директорий ----------
setup_directories() {
    log "Создаём директории для входов и выходов…"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR" "$TEST_DIR"
    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$TEST_DIR"
}

# ---------- Создание тестовых файлов ----------
create_test_cases() {
    log "Создаём базовые тестовые файлы…"

    echo "This is a test file for fuzzing" > "$TEST_DIR/simple.txt"
    echo -e "Line 1\nLine 2\nLine 3" > "$TEST_DIR/multiline.txt"
    echo "Short" > "$TEST_DIR/short.txt"
    dd if=/dev/urandom of="$TEST_DIR/random.dat" bs=1024 count=10 2>/dev/null

    FILE_LIST=(
        "$TEST_DIR/simple.txt"
        "$TEST_DIR/multiline.txt"
        "$TEST_DIR/short.txt"
        "$TEST_DIR/random.dat"
    )

    log "Генерируем 1000 входов …"
    for i in $(seq 1 1000); do
        op=$((1 + RANDOM % 4))           # 1..4

        if [[ $op -eq 2 || $op -eq 4 ]]; then
            # операции 2 и 4 требуют путь к файлу
            if (( RANDOM % 2 )); then
                file=${FILE_LIST[RANDOM % ${#FILE_LIST[@]}]}
            else
                file="$TEST_DIR/random_file_${i}.txt"
                echo "Random content $i" > "$file"
                FILE_LIST+=("$file")
            fi
            echo "$op $file" > "$INPUT_DIR/input_$i"
        else
            # операции 1 и 3 – только номер операции
            echo "$op" > "$INPUT_DIR/input_$i"
        fi
    done

    log "1000 входов созданы в $INPUT_DIR"
    log "Базовые файлы созданы в $TEST_DIR"
}

# ---------- Очистка ----------
cleanup() {
    log "🧹  Удаляем всё, что было создано…"
    rm -f "$PROGRAM_NAME"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR" "$TEST_DIR"
    log "Очистка завершена."
}

# ---------- Показать помощь ----------
show_usage() {
    cat <<'EOF'
Использование:
  ./prog_2_fuzz.sh setup   - Создать директории, компилировать программу и генерировать 1000 тестов
  ./prog_2_fuzz.sh fuzz    - Запустить фаззинг
  ./prog_2_fuzz.sh clean   - Удалить всё, что было создано
EOF
}

# ---------- Запуск фаззинга ----------
fuzz_test() {
    export AFL_SKIP_BIN_CHECK=1
    export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
    log "Запуск фаззинга:"
    # Шлюз sh – читаем файл, разбираем его на токены и передаём как два аргумента
    afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" \
        -- sh -c 'x=$(cat "$1"); set -- $x; ./"'"$PROGRAM_NAME"'" "$@"' _ @@
}

# ---------- Основная логика ----------
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