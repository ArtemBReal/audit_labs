#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#define CACHE_SIZE 5

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

// Глобальный кэш - утечка при завершении программы
Cache *global_cache = NULL;

Cache* create_cache(int max_size) {
    Cache *cache = malloc(sizeof(Cache));
    if (!cache) return NULL;
    
    cache->head = NULL;
    cache->tail = NULL;
    cache->count = 0;
    cache->max_size = max_size;
    pthread_mutex_init(&cache->lock, NULL);
    return cache;
}

// Уязвимость: утечка при ошибке в середине функции
void add_to_cache(Cache *cache, const char *key, const void *data, size_t size) {
    if (!cache || !key || !data) return;
    
    pthread_mutex_lock(&cache->lock);
    
    // Проверяем, существует ли уже ключ
    CacheEntry *current = cache->head;
    while (current) {
        if (strcmp(current->key, key) == 0) {
            // Обновляем существующую запись
            free(current->data);  // Освобождаем старые данные
            
            current->data = malloc(size);
            if (!current->data) {
                pthread_mutex_unlock(&cache->lock);
                return;  // УТЕЧКА: current->key не освобожден при ошибке
            }
            memcpy(current->data, data, size);
            current->size = size;
            pthread_mutex_unlock(&cache->lock);
            return;
        }
        current = current->next;
    }
    
    // Создаем новую запись
    CacheEntry *new_entry = malloc(sizeof(CacheEntry));
    if (!new_entry) {
        pthread_mutex_unlock(&cache->lock);
        return;
    }
    
    new_entry->key = malloc(strlen(key) + 1);
    if (!new_entry->key) {
        free(new_entry);  // Корректно
        pthread_mutex_unlock(&cache->lock);
        return;
    }
    strcpy(new_entry->key, key);
    
    new_entry->data = malloc(size);
    if (!new_entry->data) {
        // УТЕЧКА: new_entry->key не освобожден
        free(new_entry);
        pthread_mutex_unlock(&cache->lock);
        return;
    }
    memcpy(new_entry->data, data, size);
    new_entry->size = size;
    new_entry->next = cache->head;
    new_entry->prev = NULL;
    
    if (cache->head) {
        cache->head->prev = new_entry;
    }
    cache->head = new_entry;
    
    if (!cache->tail) {
        cache->tail = new_entry;
    }
    
    cache->count++;
    
    // Удаляем старые записи если превышен лимит
    while (cache->count > cache->max_size && cache->tail) {
        CacheEntry *to_remove = cache->tail;
        cache->tail = to_remove->prev;
        
        if (cache->tail) {
            cache->tail->next = NULL;
        } else {
            cache->head = NULL;
        }
        
        // УТЕЧКА: забыли освободить to_remove->key и to_remove->data
        free(to_remove);  // Только структура, данные теряются
        cache->count--;
    }
    
    pthread_mutex_unlock(&cache->lock);
}

// Утечка при обработке ошибок в файловых операциях
int process_file_with_leak(const char *filename) {
    FILE *file = fopen(filename, "r");
    if (!file) return -1;
    
    char *buffer1 = malloc(1024);
    char *buffer2 = malloc(2048);
    
    if (fgets(buffer1, 1024, file) == NULL) {
        fclose(file);
        // УТЕЧКА: buffer1 и buffer2 не освобождаются при ошибке чтения
        return -2;
    }
    
    // Симулируем сложную обработку
    if (strlen(buffer1) > 100) {
        strcpy(buffer2, "Processing long string");
        // Какая-то обработка...
        free(buffer1);
        free(buffer2);
        fclose(file);
        return 1;
    } else {
        strcpy(buffer2, "Processing short string");
        // УТЕЧКА: в этом пути забыли free
        fclose(file);
        return 0;
    }
}

// Утечка в циклическом буфере
void circular_buffer_leak() {
    void *pointers[10];
    
    for (int i = 0; i < 10; i++) {
        pointers[i] = malloc(100);
        sprintf((char*)pointers[i], "Allocation %d", i);
    }
    
    // Симулируем циклическое использование
    for (int i = 0; i < 5; i++) {
        free(pointers[i]);
        pointers[i] = malloc(100);  // Перезаписываем указатель - утечка старой памяти
    }
    
    // Освобождаем только часть
    for (int i = 0; i < 7; i++) {
        free(pointers[i]);
    }
    // УТЕЧКА: pointers[7], pointers[8], pointers[9] не освобождены
}

void initialize_global_cache() {
    if (!global_cache) {
        global_cache = create_cache(CACHE_SIZE);
        // УТЕЧКА: глобальный кэш никогда не освобождается
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <mode> [file]\n", argv[0]);
        return 1;
    }
    
    int mode = atoi(argv[1]);
    
    initialize_global_cache();
    
    switch (mode) {
        case 1: {
            // Тестируем кэш с утечками
            char data1[] = "Important data 1";
            char data2[] = "Important data 2";
            char data3[] = "Important data 3";
            
            add_to_cache(global_cache, "key1", data1, sizeof(data1));
            add_to_cache(global_cache, "key2", data2, sizeof(data2));
            add_to_cache(global_cache, "key3", data3, sizeof(data3));
            
            // Переполняем кэш чтобы вызвать удаление с утечкой
            for (int i = 0; i < 10; i++) {
                char key[20], value[50];
                sprintf(key, "temp_key_%d", i);
                sprintf(value, "temp_value_%d", i);
                add_to_cache(global_cache, key, value, sizeof(value));
            }
            break;
        }
        case 2:
            // Обработка файла с утечками
            if (argc > 2) {
                process_file_with_leak(argv[2]);
            }
            break;
        case 3:
            // Циклический буфер с утечками
            circular_buffer_leak();
            break;
        case 4: {
            // Комбинированный сценарий
            circular_buffer_leak();
            if (argc > 2) {
                process_file_with_leak(argv[2]);
            }
            add_to_cache(global_cache, "combo_key", "combo_data", 11);
            break;
        }
    }
    
    // Глобальный кэш не освобождается - утечка при завершении
    return 0;
}