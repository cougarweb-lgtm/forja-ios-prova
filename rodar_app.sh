#!/bin/bash
# rodar_app.sh - prova dos APPS iOS da Forja (fatia I6) no simulador: instala o .app, abre, confere a linha no stdout, processo vivo apos 3 s e screenshot.
# Uso: bash rodar_app.sh <dir_pacote> <dir_resultado>   (padrao: app_pacote resultado_app)
# Pacote (dir_pacote): SHA256SUMS.txt, casos.txt, os <Nome>.app.tar, <CASO>.esperado.contem (a linha que o app tem de imprimir no stdout), canarios_esperados.txt (opcional).
#   casos.txt: uma linha por caso `CASO ARQUIVO.app.tar BUNDLE_ID`.
#   Canarios: um CASO por linha (app que NAO imprime a linha); verde so se TODOS os canarios falharem e nenhum outro caso falhar.
# Itens por caso (resumo.txt: `ITEM <caso> <item> OK|FALHA`): install, launch, stdout (linha esperada), vivo (apos 3 s), screenshot (arquivo nao vazio). Caso OK = todos os itens OK.
# Selo: tenta instalar o bundle como veio (so a assinatura ad-hoc do Mach-O); se o install recusar, roda `codesign --force --sign - --deep` no .app e instala de novo (registra selo=codesign).
# Saidas em <dir_resultado>: sha256.txt, resumo.txt, casos.tsv, resultado.json, <CASO>.stdout/.stderr/.launch.txt, <CASO>.png (screenshot), bootstatus.txt.
# Verificacao local sem Mac: bash selftest_app.sh (xcrun e codesign falsos).
#
# Changelog
#   1.0 - I6: primeira versao.

PAC="${1:-app_pacote}"
OUT="${2:-resultado_app}"
ESPERA_VIVO=3
TOTAL=0
FALHAS=0

checar_sha() {
  ( cd "$PAC" && shasum -a 256 -c SHA256SUMS.txt ) > "$OUT/sha256.txt" 2>&1
  local RC=$?
  echo "sha256 check: $RC" >> "$OUT/sha256.txt"
  cat "$OUT/sha256.txt"
  return $RC
}

# Registra um item do caso: $1=caso $2=item $3=1/0
item() {
  if [ "$3" = 1 ]; then echo "ITEM $1 $2 OK" >> "$OUT/resumo.txt"; else echo "ITEM $1 $2 FALHA" >> "$OUT/resumo.txt"; MOTIVO="$MOTIVO $2"; fi
}

# Instala o bundle; se recusar, sela com codesign ad-hoc e tenta de novo. Define SELO (nenhum|codesign). Retorna 0 se instalou.
instalar() {
  SELO=nenhum
  if xcrun simctl install "$UDID" "$1" > "$OUT/$2.install.txt" 2>&1; then return 0; fi
  SELO=codesign
  codesign --force --sign - --deep "$1" >> "$OUT/$2.install.txt" 2>&1
  xcrun simctl install "$UDID" "$1" >> "$OUT/$2.install.txt" 2>&1
}

# Processo vivo: o launchctl do simulador lista o app com PID numerico, ou o PID do launch existe no host.
esta_vivo() {
  local LINHA
  LINHA=$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep "UIKitApplication:$1" | head -1)
  case "$LINHA" in
    [0-9]*) return 0 ;;
  esac
  [ -n "$2" ] && ps -p "$2" > /dev/null 2>&1
}

# Roda um caso: $1=CASO $2=ARQUIVO.tar $3=BUNDLE_ID
rodar_caso() {
  local CASO="$1" TAR="$2" BID="$3" DIR APP PID ESPERADO
  MOTIVO=""
  DIR="$OUT/_app_$CASO"
  rm -rf "$DIR"; mkdir -p "$DIR"
  ESPERADO=$(cat "$PAC/$CASO.esperado.contem" 2>/dev/null)
  if [ ! -f "$PAC/$TAR" ] || ! tar -xf "$PAC/$TAR" -C "$DIR"; then
    echo "FALHA $CASO tar_ausente_ou_ruim ($TAR)" >> "$OUT/resumo.txt"; FALHAS=$((FALHAS+1)); TOTAL=$((TOTAL+1))
    printf '%s\t%s\t0\t-\t0\ttar_ausente_ou_ruim\n' "$CASO" "$CASO" >> "$OUT/casos.tsv"; return 0
  fi
  APP=$(ls -d "$DIR"/*.app | head -1)
  if instalar "$APP" "$CASO"; then item "$CASO" install 1; else item "$CASO" install 0; fi
  : > "$OUT/$CASO.stdout"; : > "$OUT/$CASO.stderr"
  xcrun simctl launch --stdout="$OUT/$CASO.stdout" --stderr="$OUT/$CASO.stderr" "$UDID" "$BID" > "$OUT/$CASO.launch.txt" 2>&1
  PID=$(sed -n 's/^[^:]*: *\([0-9][0-9]*\).*/\1/p' "$OUT/$CASO.launch.txt" | head -1)
  if [ -n "$PID" ]; then item "$CASO" launch 1; else item "$CASO" launch 0; fi
  sleep "$ESPERA_VIVO"
  if [ -n "$ESPERADO" ] && grep -qF "$ESPERADO" "$OUT/$CASO.stdout"; then item "$CASO" stdout 1; else item "$CASO" stdout 0; fi
  if esta_vivo "$BID" "$PID"; then item "$CASO" vivo 1; else item "$CASO" vivo 0; fi
  xcrun simctl io "$UDID" screenshot "$OUT/$CASO.png" > "$OUT/$CASO.shot.txt" 2>&1
  if [ -s "$OUT/$CASO.png" ]; then item "$CASO" screenshot 1; else item "$CASO" screenshot 0; fi
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  xcrun simctl uninstall "$UDID" "$BID" > /dev/null 2>&1
  TOTAL=$((TOTAL+1))
  if [ -z "$MOTIVO" ]; then
    echo "OK $CASO selo=$SELO pid=$PID" >> "$OUT/resumo.txt"
    printf '%s\t%s\t1\t0\t0\t\n' "$CASO" "$CASO" >> "$OUT/casos.tsv"
  else
    FALHAS=$((FALHAS+1))
    echo "FALHA $CASO selo=$SELO pid=$PID itens:$MOTIVO" >> "$OUT/resumo.txt"
    printf '%s\t%s\t0\t0\t0\titens:%s\n' "$CASO" "$CASO" "$MOTIVO" >> "$OUT/casos.tsv"
  fi
}

VEREDITO='
import json, os, sys
casos_f, canar_f, json_f = sys.argv[1], sys.argv[2], sys.argv[3]
casos = []
for ln in open(casos_f, encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) == 6:
        casos.append({"nome": p[0], "ok": p[2] == "1", "motivo": p[5]})
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

# Escolhe o iPhone mais novo e boota; tenta ate 3 vezes (o boot do runner as vezes falha por "Data Migration Failed": erase e de novo).
subir_simulador() {
  local TENT
  UDID=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["devices"]
a = sorted((rt, x["udid"]) for rt, ds in d.items() if "iOS" in rt for x in ds if "iPhone" in x["name"])
print(a[-1][1] if a else "")
' | tr -d '\r')
  [ -n "$UDID" ] || return 1
  for TENT in 1 2 3; do
    xcrun simctl boot "$UDID" >> "$OUT/bootstatus.txt" 2>&1
    if xcrun simctl bootstatus "$UDID" -b >> "$OUT/bootstatus.txt" 2>&1; then return 0; fi
    xcrun simctl shutdown "$UDID" >> "$OUT/bootstatus.txt" 2>&1
    xcrun simctl erase "$UDID" >> "$OUT/bootstatus.txt" 2>&1
  done
  return 1
}

main() {
  mkdir -p "$OUT" || return 1
  : > "$OUT/resumo.txt"
  : > "$OUT/casos.tsv"
  : > "$OUT/bootstatus.txt"
  PAC=$(cd "$PAC" && pwd) || { echo "pacote inexistente: $PAC" | tee -a "$OUT/resumo.txt"; return 1; }
  OUT=$(cd "$OUT" && pwd)
  checar_sha || { echo "SHA INVALIDO: nenhum caso rodado" | tee -a "$OUT/resumo.txt"; return 1; }
  subir_simulador || { echo "SIMULADOR NAO SUBIU" | tee -a "$OUT/resumo.txt"; return 1; }

  local CASO TAR BID
  while read -r CASO TAR BID; do
    case "$CASO" in ''|\#*) continue ;; esac
    rodar_caso "$CASO" "$TAR" "$BID"
  done < "$PAC/casos.txt"
  echo "total=$TOTAL falhas=$FALHAS" >> "$OUT/resumo.txt"
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1

  python3 -I -c "$VEREDITO" "$OUT/casos.tsv" "$PAC/canarios_esperados.txt" "$OUT/resultado.json" >> "$OUT/resumo.txt"
  local RC=$?
  cat "$OUT/resumo.txt"
  return $RC
}

main
exit $?
