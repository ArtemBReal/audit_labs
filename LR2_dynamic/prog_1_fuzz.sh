#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------
# Конфигурация
# --------------------------------------------------------------------
PROGRAM_NAME="prog_1_structs_ways"
INPUT_DIR="prog_1_test_inputs"
OUTPUT_DIR="prog_1_test_outputs"

# --------------------------------------------------------------------
# Проверка наличия AFL++
# --------------------------------------------------------------------
check_afl_installation() {
    if ! command -v afl-fuzz &>/dev/null; then
        echo "AFL++ не найден. Установите его:"
        echo "     sudo apt install afl++"
        exit 1
    fi
}

# --------------------------------------------------------------------
# Компиляция программы
# --------------------------------------------------------------------
compile_program() {
    echo "Компилируем программу с AFL++ инструментированием …"
    if command -v afl-clang &>/dev/null; then
        AFL_COMPILER=afl-clang
    elif command -v afl-clang-fast &>/dev/null; then
        AFL_COMPILER=afl-clang-fast
    else
        echo "Не найден ни afl-clang, ни afl-clang-fast."
        exit 1
    fi

    # AFL‑clang уже добавляет покрытие. Добавляем –fsanitize=address,
    # чтобы быстро отлавливать утечки и ошибки памяти.
    $AFL_COMPILER -fsanitize=address -g -o "$PROGRAM_NAME" prog_1_structs_ways.c
    echo "Бинарник $PROGRAM_NAME готов."
}

# --------------------------------------------------------------------
# Создание/очистка директорий
# --------------------------------------------------------------------
setup_directories() {
    echo "Создаём директории для входных и выходных файлов …"
    rm -rf "$INPUT_DIR" "$OUTPUT_DIR"
    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
}

# --------------------------------------------------------------------
# Генерация 1000 тестовых файлов
# --------------------------------------------------------------------
create_test_cases() {
    echo "Генерируем 1000 тестовых файлов …"
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
    echo "1000 файлов созданы в $INPUT_DIR"
}

# --------------------------------------------------------------------
# Очистка
# --------------------------------------------------------------------
cleanup() {
    echo "Удаляем всё, что было создано …"
    rm -rf "$PROGRAM_NAME" "$INPUT_DIR" "$OUTPUT_DIR"
    echo "Очистка завершена."
}

# --------------------------------------------------------------------
# Показать помощь
# --------------------------------------------------------------------
show_usage() {
    cat <<'EOF'
Использование:
  ./prog_1_fuzz.sh setup   - Создать директории, компилировать программу и генерировать 1000 тестов
  ./prog_1_fuzz.sh clean   - Удалить всё, что было создано
  ./prog_1_fuzz.sh fuzz    - Запустить фаззинг
EOF
}

# --------------------------------------------------------------------
# Создание обёртки для фаззинга
# --------------------------------------------------------------------
create_wrapper() {
    cat > "$INPUT_DIR/wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Путь к реальной программе (можно менять при вызове скрипта)
PROG="${PROG:-./prog_1_structs_ways}"

# AFL подставляет имя тест‑файла через @@
TEST_FILE="$1"

# Читаем содержимое тест‑файла и разбиваем его на аргументы
ARGS=$(<"$TEST_FILE")
# Переводим в массив: $1…$N – отдельные токены
set -- $ARGS

# Запускаем реальную программу с этими аргументами
exec "$PROG" "$@"
EOF
    chmod +x "$INPUT_DIR/wrapper.sh"
}

# --------------------------------------------------------------------
# Запуск фаззинга
# --------------------------------------------------------------------
fuzz_test() {
    echo "Запуск фаззинга:"
    create_wrapper
    # Используем wrapper как «прокси» для программы
    afl-fuzz -i "$INPUT_DIR" -o "$OUTPUT_DIR" -- "$INPUT_DIR/wrapper.sh" @@
}

# --------------------------------------------------------------------
# Основной код
# --------------------------------------------------------------------
case "${1:-}" in
    setup)
        check_afl_installation
        compile_program
        setup_directories
        create_test_cases
        echo
        echo "Подготовка завершена."
        ;;
    clean)
        cleanup
        ;;
    fuzz)
        fuzz_test
        ;;
    *)
        show_usage
        exit 1
        ;;
esac