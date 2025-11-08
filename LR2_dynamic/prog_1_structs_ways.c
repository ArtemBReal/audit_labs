#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

List* create_list() {
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
        free(new_node);  // Корректно, но есть скрытая утечка при определенных условиях
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

// Уязвимость: частичное удаление в циклическом списке
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
            
            // УТЕЧКА: забыли освободить current->data
            free(current);  // Освободили узел, но не данные
            list->size--;
            return 0;
        }
        current = current->next;
    }
    return -1;
}

// Уязвимость: неполное уничтожение списка
void destroy_list_partial(List *list) {
    if (!list) return;
    
    Node *current = list->head;
    while (current) {
        Node *next = current->next;
        free(current->data);  // Освободили данные
        free(current);        // Освободили узел
        current = next;
    }
    // УТЕЧКА: забыли освободить саму структуру List
}

// Сложная условная утечка
void conditional_memory_operation(int condition1, int condition2) {
    char *buffer1 = malloc(100);
    char *buffer2 = malloc(200);
    
    if (condition1) {
        sprintf(buffer1, "Condition 1 executed");
        if (condition2) {
            sprintf(buffer2, "Both conditions true");
            // В этом пути все освобождается
            free(buffer1);
            free(buffer2);
            return;
        }
        // УТЕЧКА: при condition1=true и condition2=false buffer2 не освобождается
        free(buffer1);
    } else {
        sprintf(buffer2, "Condition 1 false");
        // УТЕЧКА: при condition1=false buffer1 не освобождается
        free(buffer2);
    }
}

// Утечка в рекурсивной функции
void recursive_leak(int depth, int max_depth) {
    char *local_buffer = malloc(50);
    sprintf(local_buffer, "Depth: %d", depth);
    
    if (depth < max_depth) {
        recursive_leak(depth + 1, max_depth);
    }
    
    // УТЕЧКА: забыли free(local_buffer) - теряем память на каждом уровне рекурсии
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        printf("Usage: %s <operation> <value>\n", argv[0]);
        return 1;
    }
    
    int operation = atoi(argv[1]);
    int value = atoi(argv[2]);
    
    List *my_list = create_list();
    
    // Добавляем узлы
    add_node(my_list, 1, "First node");
    add_node(my_list, 2, "Second node");
    add_node(my_list, 3, "Third node");
    
    switch (operation) {
        case 1:
            // Удаляем с утечкой данных
            remove_node_by_id(my_list, value);
            break;
        case 2:
            // Частичное уничтожение
            destroy_list_partial(my_list);
            my_list = NULL;  // Теперь невозможно освободить структуру List
            break;
        case 3:
            // Сложная условная утечка
            conditional_memory_operation(value > 5, value < 10);
            break;
        case 4:
            // Рекурсивная утечка
            recursive_leak(0, value);
            break;
    }
    
    // Не всегда освобождаем список
    if (operation != 2 && my_list) {
        destroy_list_partial(my_list);  // Все равно утечка структуры List
    }
    
    return 0;
}