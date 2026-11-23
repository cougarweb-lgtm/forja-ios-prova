#!/bin/bash
# rodar_pacote.sh - roda cada binario *_dev e *_release de um pacote no simulador iOS e confere o resultado.
# Uso: bash rodar_pacote.sh <dir_pacote> <dir_resultado>   (padrao: pacote resultado)
# Sidecars do binario <NOME> (ex.: ola_dev); se faltar, usa o <BASE> (ex.: ola):
#   .esperado.stdout (bytes, obrigatorio)  .esperado.exit (obrigatorio)  .esperado.stderr_contem (substring fixa, opcional)
#   .args (1 argumento por linha)  .env (KEY=VALUE por linha)  .stdin (bytes)  .timeout (segundos, padrao 20)
# Canarios: canarios_esperados.txt no pacote (um <BASE> por linha). Verde so se todos os binarios desses
#   canarios falharem e nao houver nenhuma outra falha. Sem o arquivo, nenhuma falha e aceita.
# Saidas em <dir_resultado>: sha256.txt, resumo.txt (OK/FALHA por caso), casos.tsv, resultado.json,
#   <NOME>.stdout e <NOME>.stderr por caso.
# Verificacao: bash selftest_runner.sh (usa xcrun falso; roda em bash no Windows e no macOS).
#
# Changelog
#   2.1 - cdexec.c: cada binario roda num cwd novo (mkdtemp) quando o clang do simulador esta disponivel.
#   2.0 - sha invalido reprova antes de qualquer caso; sidecars .stderr_contem/.args/.env/.stdin/.timeout;
#         TIMEOUT nomeado (watchdog em bash, sem timeout(1)); ms por caso; canarios; resultado.json.
#         Pacote antigo (stdout e exit) segue valendo sem mudancas.
#   1.0 - versao anterior: so stdout e exit; resultado do sha so gravado.

PAC="${1:-pacote}"
OUT="${2:-resultado}"
TMO_PADRAO=20
FLAG="$OUT/.timeout_disparado"
TOTAL=0
FALHAS=0
MOTIVO=""
ARGS=()
ENVS=()
CDEXEC=()

# Relogio em ms (python3, porque o date do macOS nao tem %N).
agora_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))' | tr -d '\r'; }

# Procura o sidecar: $1=NOME do binario, $2=sufixo (ex.: esperado.exit), $3=BASE. Imprime o caminho ou nada.
achar() {
  if [ -f "$PAC/$1.$2" ]; then echo "$PAC/$1.$2"
  elif [ -f "$PAC/$3.$2" ]; then echo "$PAC/$3.$2"
  fi
}

# Confere o SHA256SUMS do pacote antes de rodar qualquer caso.
checar_sha() {
  ( cd "$PAC" && shasum -a 256 -c SHA256SUMS.txt ) > "$OUT/sha256.txt" 2>&1
  local RC=$?
  echo "sha256 check: $RC" >> "$OUT/sha256.txt"
  cat "$OUT/sha256.txt"
  return $RC
}

# Acrescenta um motivo de falha ao MOTIVO do caso.
add_motivo() {
  if [ -z "$MOTIVO" ]; then MOTIVO="$1"; else MOTIVO="$MOTIVO; $1"; fi
}

# Le $1 (1 argumento por linha) para ARGS.
ler_args() {
  ARGS=()
  [ -n "$1" ] || return 0
  local L
  while IFS= read -r L || [ -n "$L" ]; do
    L="${L%$'\r'}"
    ARGS+=("$L")
  done < "$1"
}

# Le $1 (KEY=VALUE por linha) para ENVS como SIMCTL_CHILD_KEY=VALUE.
ler_env() {
  ENVS=()
  [ -n "$1" ] || return 0
  local L
  while IFS= read -r L || [ -n "$L" ]; do
    L="${L%$'\r'}"
    if [ -n "$L" ]; then ENVS+=("SIMCTL_CHILD_$L"); fi
  done < "$1"
}

# Vigia: mata o processo $1 se ainda estiver vivo depois de $2 segundos, e marca FLAG.
vigiar() {
  sleep "$2"
  if kill -0 "$1" 2>/dev/null; then : > "$FLAG"; kill "$1" 2>/dev/null; fi
}

# Registra o caso: $1=NOME $2=BASE $3=ok(1/0) $4=exit $5=ms $6=motivo (vazio se OK).
registrar() {
  if [ "$3" = 1 ]; then
    echo "OK $1 exit=$4 ms=$5" >> "$OUT/resumo.txt"
  else
    FALHAS=$((FALHAS+1))
    echo "FALHA $1 exit=$4 ms=$5 $6" >> "$OUT/resumo.txt"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$OUT/casos.tsv"
  TOTAL=$((TOTAL+1))
}

# Roda um binario e confere exit, stdout (bytes) e stderr (substring) contra os sidecars.
rodar_caso() {
  local NOME BASE ESP_OUT ESP_EXIT SUB ARQ_ARGS ARQ_ENV ARQ_STDIN ARQ_TMO STDIN_SRC TMO TXT
  local ESP_COD PID VIG RC T0 T1 MS
  NOME=$(basename "$1")
  BASE="${NOME%_dev}"; BASE="${BASE%_release}"
  chmod +x "$1"
  MOTIVO=""
  ESP_OUT=$(achar "$NOME" esperado.stdout "$BASE")
  ESP_EXIT=$(achar "$NOME" esperado.exit "$BASE")
  [ -n "$ESP_OUT" ] || add_motivo "sem_esperado_stdout"
  [ -n "$ESP_EXIT" ] || add_motivo "sem_esperado_exit"
  if [ -n "$MOTIVO" ]; then registrar "$NOME" "$BASE" 0 - 0 "$MOTIVO"; return 0; fi
  SUB=$(achar "$NOME" esperado.stderr_contem "$BASE")
  ARQ_ARGS=$(achar "$NOME" args "$BASE")
  ARQ_ENV=$(achar "$NOME" env "$BASE")
  ARQ_STDIN=$(achar "$NOME" stdin "$BASE")
  ARQ_TMO=$(achar "$NOME" timeout "$BASE")
  ler_args "$ARQ_ARGS"
  ler_env "$ARQ_ENV"
  STDIN_SRC=/dev/null
  if [ -n "$ARQ_STDIN" ]; then STDIN_SRC="$ARQ_STDIN"; fi
  TMO=$TMO_PADRAO
  if [ -n "$ARQ_TMO" ]; then TMO=$(tr -d '\r\n ' < "$ARQ_TMO"); fi
  case "$TMO" in
    ''|*[!0-9]*) registrar "$NOME" "$BASE" 0 - 0 "timeout_invalido ($TMO)"; return 0 ;;
  esac

  rm -f "$FLAG"
  T0=$(agora_ms)
  env "${ENVS[@]}" xcrun simctl spawn "$UDID" "${CDEXEC[@]}" "$PAC/$NOME" "${ARGS[@]}" < "$STDIN_SRC" > "$OUT/$NOME.stdout" 2> "$OUT/$NOME.stderr" &
  PID=$!
  vigiar "$PID" "$TMO" >/dev/null 2>&1 &
  VIG=$!
  wait "$PID"
  RC=$?
  kill "$VIG" 2>/dev/null
  wait "$VIG" 2>/dev/null
  T1=$(agora_ms)
  MS=$((T1-T0))

  if [ -f "$FLAG" ]; then registrar "$NOME" "$BASE" 0 "$RC" "$MS" "TIMEOUT (${TMO}s)"; return 0; fi

  ESP_COD=$(tr -d '\r\n ' < "$ESP_EXIT")
  [ "$RC" = "$ESP_COD" ] || add_motivo "exit_difere (esperado $ESP_COD)"
  cmp -s "$OUT/$NOME.stdout" "$ESP_OUT" || add_motivo "stdout_difere"
  if [ -n "$SUB" ]; then
    TXT=$(head -n 1 "$SUB" | tr -d '\r')
    if [ -z "$TXT" ]; then add_motivo "stderr_contem_vazio"
    elif ! grep -F -q -e "$TXT" "$OUT/$NOME.stderr"; then add_motivo "stderr_sem_substring"
    fi
  fi
  if [ -z "$MOTIVO" ]; then registrar "$NOME" "$BASE" 1 "$RC" "$MS" ""
  else registrar "$NOME" "$BASE" 0 "$RC" "$MS" "$MOTIVO"
  fi
  return 0
}

# Compila o cdexec.c (cwd novo por execucao) para o simulador; sem clang (ex.: selftest), roda direto.
preparar_cdexec() {
  CDEXEC=()
  [ -f cdexec.c ] || { echo "cdexec: ausente (cwd compartilhado)" >> "$OUT/resumo.txt"; return 0; }
  if xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=15.0 -o "$PAC/../_cdexec" cdexec.c >> "$OUT/cdexec_build.txt" 2>&1; then
    CDEXEC=("$(cd "$PAC/.." && pwd)/_cdexec")
    echo "cdexec: ativo (cwd novo por binario)" >> "$OUT/resumo.txt"
  else
    echo "cdexec: nao compilou (cwd compartilhado)" >> "$OUT/resumo.txt"
  fi
}

# Veredito: falhas fora dos canarios reprovam; canario que nao falha (todos os binarios) reprova.
VEREDITO='
import json, os, sys
casos_f, canar_f, json_f = sys.argv[1], sys.argv[2], sys.argv[3]
casos = []
for ln in open(casos_f, encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) == 6:
        casos.append({"nome": p[0], "base": p[1], "ok": p[2] == "1", "exit": p[3], "ms": int(p[4]) if p[4].isdigit() else 0, "motivo": p[5]})
canar = set()
if os.path.exists(canar_f):
    canar = set(x.strip() for x in open(canar_f, encoding="utf-8") if x.strip())
def canario_falhou(b):
    grupo = [c for c in casos if c["base"] == b]
    return len(grupo) > 0 and all(not c["ok"] for c in grupo)
inesp = sorted(c["nome"] for c in casos if not c["ok"] and c["base"] not in canar)
sem_falha = sorted(b for b in canar if not canario_falhou(b))
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

  if ! checar_sha; then
    echo "SHA INVALIDO: nenhum caso rodado" | tee -a "$OUT/resumo.txt"
    return 1
  fi

  UDID=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["devices"]
a = sorted((rt, x["udid"]) for rt, ds in d.items() if "iOS" in rt for x in ds if "iPhone" in x["name"])
print(a[-1][1] if a else "")
' | tr -d '\r')
  if [ -z "$UDID" ]; then echo "SEM IPHONE" | tee -a "$OUT/resumo.txt"; return 1; fi
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > "$OUT/bootstatus.txt" 2>&1

  preparar_cdexec
  local BIN
  for BIN in "$PAC"/*_dev "$PAC"/*_release; do
    [ -f "$BIN" ] || continue
    rodar_caso "$BIN"
  done
  echo "total=$TOTAL falhas=$FALHAS" >> "$OUT/resumo.txt"
  xcrun simctl shutdown "$UDID"

  python3 -I -c "$VEREDITO" "$OUT/casos.tsv" "$PAC/canarios_esperados.txt" "$OUT/resultado.json" >> "$OUT/resumo.txt"
  local RC=$?
  cat "$OUT/resumo.txt"
  return $RC
}

main
exit $?
