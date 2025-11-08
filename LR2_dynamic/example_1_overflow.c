#include <stdlib.h>
#include <string.h>
#include <stdio.h>
int main() {
    // Выделяем буфер размером 10 байт
    char *buf = malloc(10); 
    if (buf == NULL) {
        perror("malloc failed");
        return 1;
    }
    // Копируем строку длиной 40 символов в буфер на 10 байт
    // Это приводит к записи за пределами выделенной памяти
    strcpy(buf, "This string is way too long for the buffer!"); 
    printf("Buffer content: %s\n", buf);
    free(buf);
    return 0;
}