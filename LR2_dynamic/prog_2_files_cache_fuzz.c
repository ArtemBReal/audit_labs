/*  prog_2_files_cache_fuzz.c
 *
 *  ────────────────────────────────────────────────────────────────────────
 *  Это «fuzz‑friendly» версия исходной программы.
 *
 *  * В отличие от оригинала, аргументы теперь читаться из stdin.
 *    Файл‑тест AFL++ будет передан в программу как обычный поток
 *    входных данных, и мы будем парсить его как:
 *
 *        <mode> [file]
 *
 *    (для режимов 2 и 4 путь к файлу обязателен, остальные режимы
 *    игнорируют его).  Это избавляет от необходимости писать
 *    обёртку‑шлюз; просто `afl‑fuzz -i inputs -o outputs
 *    -- ./prog_2_files_cache_fuzz` будет работать.
 *
 *  * Всё остальное (кэш, утечки, рекурсия и пр.) осталось без изменений,
 *    чтобы сохранить «физику» оригинальной программы.
 *
 *  Компиляция:
 *
 *      afl-clang-fast -O1 -g \
 *          -fsanitize-coverage=trace-pc-guard,trace-pc \
 *          -fno-inline -fno-omit-frame-pointer \
 *          -o prog_2_files_cache_fuzz prog_2_files_cache_fuzz.c
 *
 *  Фаззинг:
 *
 *      afl-fuzz -i inputs -o outputs -- ./prog_2_files_cache_fuzz
 *
 *  ----------------------------------------------------------------------- */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

#define CACHE_SIZE 5
#define MAX_PATH 256
#define BUF_SIZE 1024

/* ---------------------------------------------------------------------- */
/*  Данные кэша и вспомогательные функции                                  */
/* ---------------------------------------------------------------------- */

typedef struct cache_entry {
    char *key;
    void *data;
    size_t size;
    struct cache_entry *next;
    struct cache_entry *prev;
} CacheEntry;

typedef struct {
    CacheEntry *head;
    CacheEntry *tail;
    int count;
    int max_size;
    pthread_mutex_t lock;
} Cache;

Cache *global_cache = NULL;   /* глобальный кэш – утечка при завершении */

Cache *create_cache(int max_size) {
    Cache *cache = malloc(sizeof(Cache));
    if (!cache) return NULL;
    cache->head = NULL;
    cache->tail = NULL;
    cache->count = 0;
    cache->max_size = max_size;
    pthread_mutex_init(&cache->lock, NULL);
    return cache;
}

/* Уязвимость: утечка при ошибке в середине функции */
void add_to_cache(Cache *cache, const char *key, const void *data, size_t size) {
    if (!cache || !key || !data) return;

    pthread_mutex_lock(&cache->lock);

    /* поиск существующего ключа */
    CacheEntry *current = cache->head;
    while (current) {
        if (strcmp(current->key, key) == 0) {
            free(current->data);          /* старые данные */
            current->data = malloc(size);
            if (!current->data) {         /* ошибка – ключ не освобождается */
                pthread_mutex_unlock(&cache->lock);
                return;
            }
            memcpy(current->data, data, size);
            current->size = size;
            pthread_mutex_unlock(&cache->lock);
            return;
        }
        current = current->next;
    }

    /* создаём новую запись */
    CacheEntry *new_entry = malloc(sizeof(CacheEntry));
    if (!new_entry) { pthread_mutex_unlock(&cache->lock); return; }

    new_entry->key = malloc(strlen(key) + 1);
    if (!new_entry->key) { free(new_entry); pthread_mutex_unlock(&cache->lock); return; }
    strcpy(new_entry->key, key);

    new_entry->data = malloc(size);
    if (!new_entry->data) { /* ключ остаётся в памяти */
        free(new_entry->key);
        free(new_entry);
        pthread_mutex_unlock(&cache->lock);
        return;
    }
    memcpy(new_entry->data, data, size);
    new_entry->size = size;

    new_entry->next = cache->head;
    new_entry->prev = NULL;
    if (cache->head) cache->head->prev = new_entry;
    cache->head = new_entry;
    if (!cache->tail) cache->tail = new_entry;
    cache->count++;

    /* удаляем старые записи при переполнении */
    while (cache->count > cache->max_size && cache->tail) {
        CacheEntry *to_remove = cache->tail;
        cache->tail = to_remove->prev;
        if (cache->tail) cache->tail->next = NULL;
        else cache->head = NULL;
        /* ключ и данные забыты – утечка */
        free(to_remove);
        cache->count--;
    }

    pthread_mutex_unlock(&cache->lock);
}

/* ---------------------------------------------------------------------- */
/*  Утечки в работе с файлами                                              */
/* ---------------------------------------------------------------------- */

int process_file_with_leak(const char *filename) {
    FILE *file = fopen(filename, "r");
    if (!file) return -1;

    char *buffer1 = malloc(1024);
    char *buffer2 = malloc(2048);
    if (!buffer1 || !buffer2) { free(buffer1); free(buffer2); fclose(file); return -3; }

    if (fgets(buffer1, 1024, file) == NULL) {
        fclose(file);
        free(buffer1); free(buffer2); /* утечка в оригинале */
        return -2;
    }

    if (strlen(buffer1) > 100) {
        strcpy(buffer2, "Processing long string");
        free(buffer1);
        free(buffer2);
        fclose(file);
        return 1;
    } else {
        strcpy(buffer2, "Processing short string");
        free(buffer2); /* buffer1 не освобождается – утечка */
        fclose(file);
        return 0;
    }
}

/* ---------------------------------------------------------------------- */
/*  Утечка в циклическом буфере                                            */
/* ---------------------------------------------------------------------- */

void circular_buffer_leak(void) {
    void *pointers[10];
    for (int i = 0; i < 10; i++) {
        pointers[i] = malloc(100);
        sprintf((char*)pointers[i], "Allocation %d", i);
    }

    for (int i = 0; i < 5; i++) {
        free(pointers[i]);
        pointers[i] = malloc(100);   /* старое освобождается только на 5 первых */
    }

    for (int i = 0; i < 7; i++) free(pointers[i]); /* 7–9 остаются в памяти */
}

/* ---------------------------------------------------------------------- */
/*  Инициализация глобального кэша                                          */
/* ---------------------------------------------------------------------- */

void initialize_global_cache(void) {
    if (!global_cache) {
        global_cache = create_cache(CACHE_SIZE);
        /* утечка: кэш не освобождается */
    }
}

/* ---------------------------------------------------------------------- */
/*  Главная функция – читаем один строковый ввод: <mode> [file]             */
/* ---------------------------------------------------------------------- */

int main(void) {
    char line[BUF_SIZE];
    if (!fgets(line, sizeof(line), stdin)) return 1;

    int mode = 0;
    char file_path[MAX_PATH] = "";
    /* Парсим: сначала номер режима, после него опционально путь к файлу */
    if (sscanf(line, "%d %255s", &mode, file_path) < 1) return 1;

    initialize_global_cache();

    switch (mode) {
        case 1: {   /* тестируем кэш с утечками */
            char data1[] = "Important data 1";
            char data2[] = "Important data 2";
            char data3[] = "Important data 3";
            add_to_cache(global_cache, "key1", data1, sizeof(data1));
            add_to_cache(global_cache, "key2", data2, sizeof(data2));
            add_to_cache(global_cache, "key3", data3, sizeof(data3));

            for (int i = 0; i < 10; i++) {
                char key[20], value[50];
                sprintf(key, "temp_key_%d", i);
                sprintf(value, "temp_value_%d", i);
                add_to_cache(global_cache, key, value, sizeof(value));
            }
            break;
        }
        case 2: /* обработка файла с утечками */
            if (file_path[0]) process_file_with_leak(file_path);
            break;
        case 3: /* циклический буфер */
            circular_buffer_leak();
            break;
        case 4: /* комбинированный сценарий */
            circular_buffer_leak();
            if (file_path[0]) process_file_with_leak(file_path);
            add_to_cache(global_cache, "combo_key", "combo_data", 11);
            break;
        default:
            /* неизвестный режим – просто завершаем без ошибок */
            break;
    }

    /* глобальный кэш не освобождается – утечка при завершении */
    return 0;
}