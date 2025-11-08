#include <stdio.h>
#include <stdlib.h>
int main() {
    int *uninitialized_data = malloc(sizeof(int));
    // Условие зависит от случайного мусора в памяти 
    // (того, что было там раньше), что непредсказуемо.
    if (*uninitialized_data == 12345) { 
        printf("Condition met unpredictably.\n");
    } else {
        printf("Condition not met.\n");
    }
    free(uninitialized_data);
    return 0;
}