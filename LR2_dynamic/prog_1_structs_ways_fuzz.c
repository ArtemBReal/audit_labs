/*  prog_1_structs_ways_fuzz.c
 *  ─────────────────────────────────────────────────────────────────────
 *  Фuzz‑friendly версия оригинальной программы со списком узлов.
 *
 *  * Программа не принимает аргументы командной строки.
 *  * Читает два целых числа из stdin: <operation> <value>.
 *  * Остальная логика (список, утечки, рекурсия) оставлена без изменений.
 *
 *  Компиляция (с AFL++):
 *      afl-clang-fast -O1 -g \
 *          -fsanitize-coverage=trace-pc-guard,trace-pc \
 *          -fno-inline -fno-omit-frame-pointer \
 *          -o prog_1_structs_ways_fuzz prog_1_structs_ways_fuzz.c
 *
 *  Запуск фаззинга:
 *      afl-fuzz -i <input_dir> -o <output_dir> -- ./prog_1_structs_ways_fuzz
 *
 *  -------------------------------------------------------------------- */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>      /* не используется, но оставляем – из‑за совместимости */

/* --------------------------------------------------------------------- */
/*  Данные и функции для работы со списком                               */
/*  -------------------------------------------------------------------- */

typedef struct node {
    int id;
    char *data;
    struct node *next;
    struct node *prev;
} Node;

typedef struct list {
    Node *head;
    Node *tail;
    int size;
} List;

List* create_list(void) {
    List *list = malloc(sizeof(List));
    if (!list) return NULL;
    list->head = NULL;
    list->tail = NULL;
    list->size = 0;
    return list;
}

void add_node(List *list, int id, const char *data) {
    Node *new_node = malloc(sizeof(Node));
    if (!new_node) return;

    new_node->id = id;
    new_node->data = malloc(strlen(data) + 1);
    if (!new_node->data) {
        free(new_node);
        return;
    }
    strcpy(new_node->data, data);
    new_node->next = NULL;
    new_node->prev = list->tail;

    if (list->tail) {
        list->tail->next = new_node;
    } else {
        list->head = new_node;
    }
    list->tail = new_node;
    list->size++;
}

/* Уязвимость: частичное удаление в циклическом списке */
int remove_node_by_id(List *list, int id) {
    if (!list || !list->head) return -1;
    Node *current = list->head;
    while (current) {
        if (current->id == id) {
            if (current->prev) {
                current->prev->next = current->next;
            } else {
                list->head = current->next;
            }
            if (current->next) {
                current->next->prev = current->prev;
            } else {
                list->tail = current->prev;
            }
            /* УТЕЧКА: забыли освободить current->data */
            free(current);  /* только узел */
            list->size--;
            return 0;
        }
        current = current->next;
    }
    return -1;
}

/* Уязвимость: неполное уничтожение списка */
void destroy_list_partial(List *list) {
    if (!list) return;
    Node *current = list->head;
    while (current) {
        Node *next = current->next;
        free(current->data);
        free(current);
        current = next;
    }
    /* УТЕЧКА: забыли освободить саму структуру List */
}

/* --------------------------------------------------------------------- */
/*  Функции, демонстрирующие различные типы утечек                       */
/*  -------------------------------------------------------------------- */

void conditional_memory_operation(int condition1, int condition2) {
    char *buffer1 = malloc(100);
    char *buffer2 = malloc(200);
    if (!buffer1 || !buffer2) { free(buffer1); free(buffer2); return; }

    if (condition1) {
        sprintf(buffer1, "Condition 1 executed");
        if (condition2) {
            sprintf(buffer2, "Both conditions true");
            /* все освобождается */
            free(buffer1);
            free(buffer2);
            return;
        }
        /* УТЕЧКА: при condition1=true и condition2=false buffer2 не освобождается */
        free(buffer1);
    } else {
        sprintf(buffer2, "Condition 1 false");
        /* УТЕЧКА: при condition1=false buffer1 не освобождается */
        free(buffer2);
    }
}

void recursive_leak(int depth, int max_depth) {
    char *local_buffer = malloc(50);
    if (!local_buffer) return;
    sprintf(local_buffer, "Depth: %d", depth);
    if (depth < max_depth) recursive_leak(depth + 1, max_depth);
    /* УТЕЧКА: забыли free(local_buffer) */
}

/* --------------------------------------------------------------------- */
/*  Функция main – «fuzz‑friendly»                                        */
/*  -------------------------------------------------------------------- */

int main(void) {
    int operation, value;

    /* Читаем два целых числа из stdin.  Если это не удаётся – сообщаем
       об ошибке.  Это позволяет AFL подать любой поток байтов, но
       только корректно сформированные «число число» будут использоваться. */
    if (fscanf(stdin, "%d %d", &operation, &value) != 2) {
        fprintf(stderr, "Usage: <operation> <value>\n");
        return 1;
    }

    /* Инициализируем список (тут есть «умные» узлы) */
    List *my_list = create_list();
    if (!my_list) return 1;

    /* Добавляем три узла – чтобы всегда был некоторый контекст */
    add_node(my_list, 1, "First node");
    add_node(my_list, 2, "Second node");
    add_node(my_list, 3, "Third node");

    /* Выполняем выбранную операцию */
    switch (operation) {
        case 1:
            remove_node_by_id(my_list, value);
            break;
        case 2:
            destroy_list_partial(my_list);
            my_list = NULL;      /* теперь нельзя освободить List */
            break;
        case 3:
            conditional_memory_operation(value > 5, value < 10);
            break;
        case 4:
            recursive_leak(0, value);
            break;
        default:
            /* Если операция не распознана – ничего не делаем. */
            break;
    }

    /* Сохраняем логику «не всегда освобождаем список» из оригинала. */
    if (operation != 2 && my_list) {
        destroy_list_partial(my_list);  /* но структура List всё равно утечка */
    }

    return 0;
}
