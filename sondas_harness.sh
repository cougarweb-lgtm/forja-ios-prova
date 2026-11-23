#!/bin/bash
# sondas_harness.sh - mede no simulador iOS premissas do `xcrun simctl spawn`. So mede: nunca reprova o job.
# Uso: bash sondas_harness.sh <dir_resultado>   -> grava <dir_resultado>/sondas.txt
# Sondas: 1 stdin (redirect e pipe)  2 cwd, TMPDIR e persistencia (no mesmo spawn e entre spawns)
#         3 env SIMCTL_CHILD_  4 saida por sinal (abort e SIGSEGV)  5 stderr limpo
# Verificacao: bash sondas_harness.sh <dir> no macOS com Xcode (nao roda no Windows).
#
# Changelog
#   1.0 - primeira versao: 5 sondas, clang do iphonesimulator, arm64, iOS 15.0 simulator.

OUT="${1:-resultado_sondas}"
TXT="$OUT/sondas.txt"
W=""
UDID=""

# Escolhe o iPhone mais novo disponivel (mesmo criterio do rodar_pacote.sh).
escolher_udid() {
  xcrun simctl list devices available -j | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["devices"]
a = sorted((rt, x["udid"]) for rt, ds in d.items() if "iOS" in rt for x in ds if "iPhone" in x["name"])
print(a[-1][1] if a else "")
' | tr -d '\r'
}

# Cabecalho de cada sonda.
secao() { echo "" >> "$TXT"; echo "## $1" >> "$TXT"; }

# Chamar logo apos o spawn: $1=rotulo. Grava o rc ($? do spawn) e o inicio de stdout/stderr de $W/o.txt e $W/e.txt.
mostrar() {
  local RC=$?
  {
    echo "$1"
    echo "rc=$RC"
    echo "stdout:"
    head -c 400 "$W/o.txt"
    echo ""
    echo "stderr:"
    head -c 400 "$W/e.txt"
    echo ""
  } >> "$TXT"
}

# Compila $1 (fonte .c) para $2 (binario); falha de compilacao vira linha no sondas.txt.
compilar() {
  if ! xcrun --sdk iphonesimulator clang -arch arm64 -target arm64-apple-ios15.0-simulator -O0 -o "$2" "$1" > "$2.log" 2>&1; then
    echo "COMPILE FALHOU $(basename "$1") (ver $(basename "$2").log)" >> "$TXT"
    return 1
  fi
  return 0
}

escrever_fontes() {
  cat > "$W/stdin.c" <<'FIM'
#include <stdio.h>
int main(void) {
    int c, n = 0;
    while ((c = getchar()) != EOF) n++;
    printf("stdin_bytes=%d\n", n);
    return 0;
}
FIM
  cat > "$W/cwd.c" <<'FIM'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char cwd[1024];
    char path[1200];
    const char *tmp = getenv("TMPDIR");
    const char *modo = argc > 1 ? argv[1] : "escreve";
    FILE *f;
    if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "(erro)");
    printf("cwd=%s\n", cwd);
    printf("TMPDIR=%s\n", tmp ? tmp : "(nulo)");
    snprintf(path, sizeof path, "%s/sonda_marca.txt", tmp ? tmp : "/tmp");
    if (modo[0] == 'e') {
        f = fopen(path, "w");
        if (f) { fputs("marca\n", f); fclose(f); }
        f = fopen(path, "r");
        printf("mesmo_spawn_persiste=%d\n", f != NULL);
        if (f) fclose(f);
    } else {
        f = fopen(path, "r");
        printf("outro_spawn_persiste=%d\n", f != NULL);
        if (f) fclose(f);
    }
    return 0;
}
FIM
  cat > "$W/env.c" <<'FIM'
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    const char *v = getenv("FOO");
    printf("FOO=%s\n", v ? v : "(ausente)");
    return 0;
}
FIM
  cat > "$W/sinal.c" <<'FIM'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    printf("antes_do_sinal\n");
    fflush(stdout);
    if (argc > 1 && argv[1][0] == 'a') abort();
    raise(SIGSEGV);
    return 0;
}
FIM
  cat > "$W/stderr.c" <<'FIM'
#include <stdio.h>
int main(void) {
    printf("so_stdout\n");
    fprintf(stderr, "so_stderr\n");
    return 0;
}
FIM
}

sonda_stdin() {
  secao "1 stdin"
  printf 'abc\n' > "$W/in.txt"
  xcrun simctl spawn "$UDID" "$W/stdin" < "$W/in.txt" > "$W/o.txt" 2> "$W/e.txt"
  mostrar "redirect (esperado stdin_bytes=4):"
  printf 'abc\n' | xcrun simctl spawn "$UDID" "$W/stdin" > "$W/o.txt" 2> "$W/e.txt"
  mostrar "pipe (esperado stdin_bytes=4):"
}

sonda_cwd() {
  secao "2 cwd e TMPDIR"
  xcrun simctl spawn "$UDID" "$W/cwd" escreve > "$W/o.txt" 2> "$W/e.txt"
  mostrar "spawn 1 (escreve e le no mesmo processo):"
  xcrun simctl spawn "$UDID" "$W/cwd" le > "$W/o.txt" 2> "$W/e.txt"
  mostrar "spawn 2 (outro processo le a marca):"
}

sonda_env() {
  secao "3 env SIMCTL_CHILD_"
  env SIMCTL_CHILD_FOO=bar xcrun simctl spawn "$UDID" "$W/env" > "$W/o.txt" 2> "$W/e.txt"
  mostrar "com SIMCTL_CHILD_FOO=bar (esperado FOO=bar):"
  xcrun simctl spawn "$UDID" "$W/env" > "$W/o.txt" 2> "$W/e.txt"
  mostrar "sem prefixo (controle, esperado FOO=(ausente)):"
}

sonda_sinal() {
  secao "4 saida por sinal"
  xcrun simctl spawn "$UDID" "$W/sinal" abort > "$W/o.txt" 2> "$W/e.txt"
  mostrar "abort():"
  xcrun simctl spawn "$UDID" "$W/sinal" segv > "$W/o.txt" 2> "$W/e.txt"
  mostrar "raise(SIGSEGV):"
}

sonda_stderr() {
  secao "5 stderr limpo"
  xcrun simctl spawn "$UDID" "$W/stderr" > "$W/o.txt" 2> "$W/e.txt"
  mostrar "stderr deve conter so so_stderr:"
}

main() {
  mkdir -p "$OUT" 2>/dev/null || return 0
  echo "sondas_harness 1.0 - medicoes (nao reprovam o job)" > "$TXT"
  W=$(mktemp -d) || { echo "sem mktemp" >> "$TXT"; return 0; }
  escrever_fontes
  local F
  for F in stdin cwd env sinal stderr; do
    compilar "$W/$F.c" "$W/$F" || true
  done
  UDID=$(escolher_udid)
  if [ -z "$UDID" ]; then echo "SEM IPHONE: sondas nao rodaram" >> "$TXT"; return 0; fi
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1
  sonda_stdin
  sonda_cwd
  sonda_env
  sonda_sinal
  sonda_stderr
  xcrun simctl shutdown "$UDID"
  rm -rf "$W"
  return 0
}

main
exit 0
