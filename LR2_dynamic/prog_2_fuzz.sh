#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------
# Скрипт компилирует программу `prog_2_files_cache.c` под AFL++
# и генерирует 1000 входных файлов.
# -------------------------------------------------------------

# ---------- Конфигурация ----------
PROGRAM_NAME="prog_2_files_cache"
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
    # <-- исправлено: правильный синтаксис command‑substitution
    log "AFL++ найден ($(afl-fuzz --version 2>/dev/null || echo 'unknown'))"
}

# ---------- Компиляция программы ----------
compile_program() {
    log "Поиск компилятора AFL++…"
    for c in afl-clang-fast afl-clang; do
        if command -v "$c" &>/dev/null; then
            COMPILER=$c
            break
        fi
    done

    if [[ -z ${COMPILER:-} ]]; then
        log "Не найден ни afl-clang-fast, ни afl-clang."
        exit 1
    fi

    log "Используем компилятор: $COMPILER"
    log "Компиляция с AddressSanitizer…"
    $COMPILER -fsanitize=address -g -o "$PROGRAM_NAME" prog_2_files_cache.c -lpthread
    log "Программа $PROGRAM_NAME готова."
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
        op=$((1 + RANDOM % 4))

        if [[ $op -eq 2 || $op -eq 4 ]]; then
            if (( RANDOM % 2 )); then
                file=${FILE_LIST[RANDOM % ${#FILE_LIST[@]}]}
            else
                file="$TEST_DIR/random_file_${i}.txt"
                echo "Random content $i" > "$file"
                FILE_LIST+=("$file")
            fi
            echo "$op $file" > "$INPUT_DIR/input_$i"
        else
            echo "$op" > "$INPUT_DIR/input_$i"
        fi
    done

    log "1000 входов созданы в $INPUT_DIR"
    log "Базовые файлы созданы в $TEST_DIR"
}

# ---------- Очистка ----------
cleanup() {
    log "🧹  Удаляем сгенерированные файлы и бинарник…"
    rm -f "$PROGRAM_NAME"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR" "$TEST_DIR"
    log "Очистка завершена."
}

# ---------- Показать помощь ----------
show_usage() {
    cat <<'EOF'
Использование: ./prog_2_fuzz.sh [команда]

Команды:
  setup   – компиляция программы и генерация 1000 входов
  fuzz    – запуск fuzz‑тестирования
  clean   – удаление бинарника и всех тестовых файлов

Пример:
  ./prog_2_fuzz.sh setup   # подготовка
  ./prog_2_fuzz.sh clean   # очистка
EOF
}

# ---------- Запуск фаззинга ----------
fuzz_test() {
    log "Запуск фаззинга:"
    # <– добавлен @@ для передачи пути к файлу как аргумент
    afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -- ./"$PROGRAM_NAME" @@
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
        echo "Проверьте: $INPUT_DIR (1000 входов), $TEST_DIR (файлы), $PROGRAM_NAME (бинарник)"
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