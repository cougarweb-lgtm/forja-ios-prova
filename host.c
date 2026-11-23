// host.c - programa host do CI da fatia I5 (dylib iOS da Forja): carrega um .dylib por dlopen, resolve os exports por dlsym e chama.
// Uso: host <suite> <caminho_ou_@rpath/nome.dylib>
//   suites: aritmetica (soma, fatorial, contar), heap (heap_soma, heap_mapa), texto (ola_texto + forja_liberar, tamanho_texto)
// Saida em stdout no formato `nome(args)=valor`, uma linha por chamada; exit 0 se tudo carregou e chamou, 3 se dlopen/dlsym falhou, 4 suite desconhecida.
// Build (simulador): xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=15.0 -o host host.c
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int32_t (*Fn_i32_i32_i32)(int32_t, int32_t);
typedef int64_t (*Fn_i64_i32)(int32_t);
typedef int32_t (*Fn_i32_i32)(int32_t);
typedef const char *(*Fn_cstr_i32)(int32_t);
typedef void (*Fn_void_cstr)(const char *);
typedef void *(*Fn_ptr)(void);

static void *g_lib;

static void *resolver(const char *nome) {
    void *p = dlsym(g_lib, nome);
    if (!p) {
        fprintf(stderr, "dlsym(%s) falhou: %s\n", nome, dlerror());
    }
    return p;
}

static int suite_aritmetica(void) {
    Fn_i32_i32_i32 soma = (Fn_i32_i32_i32)resolver("soma");
    Fn_i64_i32 fatorial = (Fn_i64_i32)resolver("fatorial");
    Fn_i32_i32 contar = (Fn_i32_i32)resolver("contar");
    if (!soma || !fatorial || !contar) return 3;
    printf("soma(2,3)=%d\n", soma(2, 3));
    printf("soma(-7,10)=%d\n", soma(-7, 10));
    printf("fatorial(10)=%lld\n", (long long)fatorial(10));
    printf("contar(100)=%d\n", contar(100));
    return 0;
}

static int suite_heap(void) {
    Fn_i32_i32 heap_soma = (Fn_i32_i32)resolver("heap_soma");
    Fn_i32_i32 heap_mapa = (Fn_i32_i32)resolver("heap_mapa");
    if (!heap_soma || !heap_mapa) return 3;
    printf("heap_soma(10)=%d\n", heap_soma(10));
    printf("heap_soma(1000)=%d\n", heap_soma(1000));
    printf("heap_mapa(7)=%d\n", heap_mapa(7));
    return 0;
}

static int suite_texto(void) {
    Fn_cstr_i32 ola_texto = (Fn_cstr_i32)resolver("ola_texto");
    Fn_i32_i32 tamanho_texto = (Fn_i32_i32)resolver("tamanho_texto");
    Fn_void_cstr liberar = (Fn_void_cstr)resolver("forja_liberar");
    Fn_ptr info = (Fn_ptr)resolver("forja_dll_info");
    if (!ola_texto || !tamanho_texto || !liberar || !info) return 3;
    const char *t = ola_texto(7);
    printf("ola_texto(7)=%s\n", t ? t : "(nulo)");
    liberar(t);
    printf("tamanho_texto(7)=%d\n", tamanho_texto(7));
    printf("forja_dll_info=%s\n", info() ? "nao-nulo" : "nulo");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "uso: host <suite> <dylib>\n");
        return 2;
    }
    g_lib = dlopen(argv[2], RTLD_NOW);
    if (!g_lib) {
        fprintf(stderr, "dlopen(%s) falhou: %s\n", argv[2], dlerror());
        return 3;
    }
    int rc = 4;
    if (strcmp(argv[1], "aritmetica") == 0) rc = suite_aritmetica();
    else if (strcmp(argv[1], "heap") == 0) rc = suite_heap();
    else if (strcmp(argv[1], "texto") == 0) rc = suite_texto();
    fflush(stdout);
    return rc;
}
