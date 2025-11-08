#include <stdlib.h>
void allocate_memory() {
    // Выделяем память и теряем указатель на нее
    char *ptr = malloc(50); 
    // Нет free(ptr);
    // Функция завершается, память "теряется"
}
int main() {
    for (int i = 0; i < 10; i++) {
        allocate_memory();
    }
    return 0;
}