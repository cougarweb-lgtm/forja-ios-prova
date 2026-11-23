#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    printf("ola ios argc=%d\n", argc);
    fflush(stdout);
    fprintf(stderr, "ola stderr\n");
    return 42;
}
