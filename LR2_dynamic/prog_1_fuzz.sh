#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------
# Конфигурация
# ------------------------------------
PROGRAM_NAME="prog_1_structs_ways"
INPUT_DIR="prog_1_test_inputs"
OUTPUT_DIR="prog_1_test_outputs"

# ------------------------------------
# Утилиты
# ------------------------------------
log() { printf '%s\n' "$*"; }

check_afl_installation() {
    if ! command -v afl-fuzz &>/dev/null; then
        log "AFL++ не найден. Установите его: sudo apt install afl++"
        exit 1
    fi
    log "AFL++ найден ($(afl-fuzz --version 2>/dev/null || echo 'unknown'))"
}

# ------------------------------------
# Компиляция программы (без ASan)
# ------------------------------------
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
    log "Компиляция без ASan…"
    $COMPILER -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
    log "Программа $PROGRAM_NAME готова."
}

# ------------------------------------
# Создание/очистка директорий
# ------------------------------------
setup_directories() {
    log "Создаём директории для входов и выходов…"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR"
    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
}

# ------------------------------------
# Генерация 1000 тестовых файлов
# ------------------------------------
create_test_cases() {
    log "Генерируем 1000 тестовых файлов …"
    for i in $(seq 1 1000); do
        rnd=$((RANDOM % 10))
        case $rnd in
            0)  : > "$INPUT_DIR/input_$i"                     ;;
            1)  echo "abc def" > "$INPUT_DIR/input_$i"        ;;
            2)  op=$((1 + RANDOM % 4)); echo "$op" > "$INPUT_DIR/input_$i" ;;
            3)  op=$((1 + RANDOM % 4)); val=$((RANDOM % 200 - 50));
                 echo "$op $val extra" > "$INPUT_DIR/input_$i" ;;
            4)  dd if=/dev/urandom bs=1 count=$((1 + RANDOM % 20))
                 of="$INPUT_DIR/input_$i" status=none ;;
            *)  op=$((1 + RANDOM % 4)); val=$((RANDOM % 200 - 50));
                 echo "$op $val" > "$INPUT_DIR/input_$i" ;;
        esac
    done
    log "1000 файлов созданы в $INPUT_DIR"
}

# ------------------------------------
# Очистка
# ------------------------------------
cleanup() {
    log "🧹  Удаляем всё, что было создано …"
    rm -f "$PROGRAM_NAME"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR"
    log "Очистка завершена."
}

# ------------------------------------
# Показать помощь
# ------------------------------------
show_usage() {
    cat <<'EOF'
Использование: ./prog_1_fuzz.sh [команда]

Команды:
  setup   – компиляция программы и генерация 1000 входов
  fuzz    – запуск fuzz‑тестирования
  clean   – удаление бинарника и всех тестовых файлов

Пример:
  ./prog_1_fuzz.sh setup   # подготовка
  ./prog_1_fuzz.sh clean   # очистка
EOF
}

# ------------------------------------
# Запуск фаззинга (sh‑обёртка)
# ------------------------------------
fuzz_test() {
    log "Запуск фаззинга:"
    # Используем sh -c, чтобы передать тест‑файл как два аргумента
    # (операцию и значение/путь)
    afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" \
        -- sh -c 'x=$(cat "$1"); set -- $x; ./"'"$PROGRAM_NAME"'" "$@"' _ @@
}

# ------------------------------------
# Основная логика
# ------------------------------------
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
