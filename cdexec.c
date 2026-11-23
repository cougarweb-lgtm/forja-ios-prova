/* cdexec.c - roda um binario num diretorio de trabalho NOVO e vazio (um por execucao).
   Uso: cdexec <binario> [args...]
   Cria um diretorio com mkdtemp em $TMPDIR (ou /tmp), faz chdir nele e troca o processo por <binario> (execv).
   Motivo: o simctl spawn reaproveita o mesmo cwd entre execucoes, e fixtures que criam arquivo relativo
   (ex.: pasta_handle) passavam no dev e falhavam no release com already_exists.
   Versao 1.0.0 (23/11/2026) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char molde[1024];
    const char *base = getenv("TMPDIR");
    if (argc < 2) {
        fprintf(stderr, "uso: cdexec <binario> [args...]\n");
        return 125;
    }
    if (base == NULL || base[0] == '\0') base = "/tmp";
    snprintf(molde, sizeof molde, "%s/forja_cwd_XXXXXX", base);
    if (mkdtemp(molde) == NULL) {
        perror("cdexec: mkdtemp");
        return 125;
    }
    if (chdir(molde) != 0) {
        perror("cdexec: chdir");
        return 125;
    }
    execv(argv[1], argv + 1);
    perror("cdexec: execv");
    return 126;
}
