#include <stdlib.h>
#include <stdio.h>
#include <string.h>
int main() {
    char *ptr = malloc(20);
    if (ptr == NULL) return 1;
    strcpy(ptr, "Hello, World!");
    // Освобождаем память
    free(ptr); 
    // Повторное использование освобожденной памяти (УЯЗВИМОСТЬ)
    printf("Accessing freed memory: %c\n", ptr[0]); 
    // Попытка записи в освобожденную память 
    // Valgrind также может поймать это как Invalid write 
    // strcpy(ptr, "New value"); 
    return 0;
}