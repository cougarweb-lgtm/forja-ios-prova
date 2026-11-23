#!/bin/bash
# rodar_dll.sh - prova dos dylibs iOS da Forja (fatia I5): compila o host.c, e para cada caso do pacote carrega o .dylib por dlopen no simulador e confere.
# Uso: bash rodar_dll.sh <dir_pacote> <dir_resultado>   (padrao: dll_pacote resultado_dll)
# Pacote (dir_pacote): SHA256SUMS.txt, casos.txt, os .dylib, <NOME>.esperado.stdout, canarios_esperados.txt (opcional).
#   casos.txt: uma linha por caso `NOME SUITE ARQUIVO.dylib CARGA` (CARGA = abs: dlopen por caminho absoluto; rpath: dlopen("@rpath/ARQUIVO"), o host leva -rpath do pacote).
#   Esperado do caso: <NOME>.esperado.stdout (bytes) e, se existir, <NOME>.esperado.exit (padrao 0).
#   Canarios: um NOME por linha; verde so se TODOS os canarios falharem e nenhum outro caso falhar.
# Saidas em <dir_resultado>: sha256.txt, resumo.txt, casos.tsv, resultado.json, <NOME>.stdout/.stderr, diag_<arquivo>.txt (otool/codesign/dyld_info, so informativo).
# Verificacao local sem Mac: bash selftest_dll.sh (xcrun falso que compila o host com o cc local).
#
# Changelog
#   1.0 - I5: primeira versao (host.c + dlopen/dlsym; dev e release; carga por caminho absoluto e por @rpath).

PAC="${1:-dll_pacote}"
OUT="${2:-resultado_dll}"
TMO=60
FLAG="$OUT/.timeout_disparado"
TOTAL=0
FALHAS=0
MOTIVO=""

agora_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))' | tr -d '\r'; }

checar_sha() {
  ( cd "$PAC" && shasum -a 256 -c SHA256SUMS.txt ) > "$OUT/sha256.txt" 2>&1
  local RC=$?
  echo "sha256 check: $RC" >> "$OUT/sha256.txt"
  cat "$OUT/sha256.txt"
  return $RC
}

add_motivo() {
  if [ -z "$MOTIVO" ]; then MOTIVO="$1"; else MOTIVO="$MOTIVO; $1"; fi
}

vigiar() {
  sleep "$2"
  if kill -0 "$1" 2>/dev/null; then : > "$FLAG"; kill "$1" 2>/dev/null; fi
}

# Registra o caso: $1=NOME $2=ok(1/0) $3=exit $4=ms $5=motivo (vazio se OK).
registrar() {
  if [ "$2" = 1 ]; then
    echo "OK $1 exit=$3 ms=$4" >> "$OUT/resumo.txt"
  else
    FALHAS=$((FALHAS+1))
    echo "FALHA $1 exit=$3 ms=$4 $5" >> "$OUT/resumo.txt"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$1" "$2" "$3" "$4" "$5" >> "$OUT/casos.tsv"
  TOTAL=$((TOTAL+1))
}

# Roda um caso: $1=NOME $2=SUITE $3=ARQUIVO $4=CARGA
rodar_caso() {
  local NOME="$1" SUITE="$2" ARQ="$3" CARGA="$4" ALVO ESP_OUT ESP_EXIT ESP_COD PID VIG RC T0 T1 MS
  MOTIVO=""
  ESP_OUT="$PAC/$NOME.esperado.stdout"
  ESP_EXIT="$PAC/$NOME.esperado.exit"
  [ -f "$PAC/$ARQ" ] || { registrar "$NOME" 0 - 0 "dylib_ausente ($ARQ)"; return 0; }
  [ -f "$ESP_OUT" ] || { registrar "$NOME" 0 - 0 "sem_esperado_stdout"; return 0; }
  ESP_COD=0
  [ -f "$ESP_EXIT" ] && ESP_COD=$(tr -d '\r\n ' < "$ESP_EXIT")
  if [ "$CARGA" = rpath ]; then ALVO="@rpath/$ARQ"; else ALVO="$PAC/$ARQ"; fi
  rm -f "$FLAG"
  T0=$(agora_ms)
  xcrun simctl spawn "$UDID" "$HOST" "$SUITE" "$ALVO" < /dev/null > "$OUT/$NOME.stdout" 2> "$OUT/$NOME.stderr" &
  PID=$!
  vigiar "$PID" "$TMO" >/dev/null 2>&1 &
  VIG=$!
  wait "$PID"
  RC=$?
  kill "$VIG" 2>/dev/null
  wait "$VIG" 2>/dev/null
  T1=$(agora_ms)
  MS=$((T1-T0))
  if [ -f "$FLAG" ]; then registrar "$NOME" 0 "$RC" "$MS" "TIMEOUT (${TMO}s)"; return 0; fi
  [ "$RC" = "$ESP_COD" ] || add_motivo "exit_difere (esperado $ESP_COD)"
  cmp -s "$OUT/$NOME.stdout" "$ESP_OUT" || add_motivo "stdout_difere"
  if [ -z "$MOTIVO" ]; then registrar "$NOME" 1 "$RC" "$MS" ""; else registrar "$NOME" 0 "$RC" "$MS" "$MOTIVO"; fi
  return 0
}

# Diagnostico informativo de cada dylib (nao reprova): cabecalho, load commands, assinatura e exports vistos pela Apple.
diagnosticar() {
  local D ARQ
  for D in "$PAC"/*.dylib; do
    [ -f "$D" ] || continue
    ARQ=$(basename "$D")
    {
      echo "== otool -hv"; otool -hv "$D" 2>&1
      echo "== otool -l (LC_ID_DYLIB, build)"; otool -l "$D" 2>&1 | grep -A6 -E "LC_ID_DYLIB|LC_BUILD_VERSION"
      echo "== codesign -vv"; codesign -vv "$D" 2>&1
      echo "== dyld_info -exports"; dyld_info -exports "$D" 2>&1
    } > "$OUT/diag_$ARQ.txt" 2>&1
  done
}

VEREDITO='
import json, os, sys
casos_f, canar_f, json_f = sys.argv[1], sys.argv[2], sys.argv[3]
casos = []
for ln in open(casos_f, encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) == 6:
        casos.append({"nome": p[0], "ok": p[2] == "1", "exit": p[3], "ms": int(p[4]) if p[4].isdigit() else 0, "motivo": p[5]})
canar = set()
if os.path.exists(canar_f):
    canar = set(x.strip() for x in open(canar_f, encoding="utf-8") if x.strip())
inesp = sorted(c["nome"] for c in casos if not c["ok"] and c["nome"] not in canar)
sem_falha = sorted(n for n in canar if not any(c["nome"] == n and not c["ok"] for c in casos))
ok = len(casos) > 0 and not inesp and not sem_falha
doc = {"veredito": "OK" if ok else "REPROVADO", "casos": casos, "canarios": sorted(canar), "falhas_inesperadas": inesp, "canarios_sem_falha": sem_falha}
with open(json_f, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=True, indent=1)
if ok:
    print("VEREDITO OK casos=%d canarios=%d" % (len(casos), len(canar)))
else:
    print("VEREDITO REPROVADO casos=%d falhas_inesperadas=%s canarios_sem_falha=%s" % (len(casos), inesp, sem_falha))
sys.exit(0 if ok else 1)
'

main() {
  mkdir -p "$OUT" || return 1
  : > "$OUT/resumo.txt"
  : > "$OUT/casos.tsv"
  PAC=$(cd "$PAC" && pwd) || { echo "pacote inexistente: $PAC" | tee -a "$OUT/resumo.txt"; return 1; }
  OUT=$(cd "$OUT" && pwd)
  FLAG="$OUT/.timeout_disparado"
  checar_sha || { echo "SHA INVALIDO: nenhum caso rodado" | tee -a "$OUT/resumo.txt"; return 1; }

  UDID=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["devices"]
a = sorted((rt, x["udid"]) for rt, ds in d.items() if "iOS" in rt for x in ds if "iPhone" in x["name"])
print(a[-1][1] if a else "")
' | tr -d '\r')
  if [ -z "$UDID" ]; then echo "SEM IPHONE" | tee -a "$OUT/resumo.txt"; return 1; fi
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > "$OUT/bootstatus.txt" 2>&1

  HOST="$OUT/_host"
  if ! xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=15.0 -Wl,-rpath,"$PAC" -o "$HOST" host.c > "$OUT/host_build.txt" 2>&1; then
    echo "HOST NAO COMPILOU" | tee -a "$OUT/resumo.txt"; cat "$OUT/host_build.txt"; return 1
  fi
  diagnosticar

  local NOME SUITE ARQ CARGA
  while read -r NOME SUITE ARQ CARGA; do
    case "$NOME" in ''|\#*) continue ;; esac
    rodar_caso "$NOME" "$SUITE" "$ARQ" "$CARGA"
  done < "$PAC/casos.txt"
  echo "total=$TOTAL falhas=$FALHAS" >> "$OUT/resumo.txt"
  xcrun simctl shutdown "$UDID"

  python3 -I -c "$VEREDITO" "$OUT/casos.tsv" "$PAC/canarios_esperados.txt" "$OUT/resultado.json" >> "$OUT/resumo.txt"
  local RC=$?
  cat "$OUT/resumo.txt"
  return $RC
}

main
exit $?
