#!/bin/bash
# Roda cada binario de pacote/ no simulador iOS e compara stdout e exit code com os .esperado.*.
# Convencao: pacote/<nome>_<dev|release> usa pacote/<nome>.esperado.stdout e <nome>.esperado.exit.
set +e
PAC="${1:-pacote}"
OUT="${2:-resultado}"
mkdir -p "$OUT"

( cd "$PAC" && shasum -a 256 -c SHA256SUMS.txt ) > "$OUT/sha256.txt" 2>&1
echo "sha256 check: $?" >> "$OUT/sha256.txt"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
a = sorted((rt, x["udid"]) for rt, ds in d.items() if "iOS" in rt for x in ds if "iPhone" in x["name"])
print(a[-1][1] if a else "")
')
[ -z "$UDID" ] && { echo "SEM IPHONE" | tee "$OUT/resumo.txt"; exit 1; }
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > "$OUT/bootstatus.txt" 2>&1

FALHAS=0
TOTAL=0
: > "$OUT/resumo.txt"
for BIN in "$PAC"/*_dev "$PAC"/*_release; do
  [ -f "$BIN" ] || continue
  NOME=$(basename "$BIN")
  BASE="${NOME%_dev}"; BASE="${BASE%_release}"
  chmod +x "$BIN"
  xcrun simctl spawn "$UDID" "$PWD/$BIN" > "$OUT/$NOME.stdout" 2> "$OUT/$NOME.stderr"
  CODIGO=$?
  ESP_COD=$(tr -d '\r\n ' < "$PAC/$BASE.esperado.exit")
  TOTAL=$((TOTAL+1))
  OK=1
  [ "$CODIGO" = "$ESP_COD" ] || OK=0
  cmp -s <(tr -d '\r' < "$OUT/$NOME.stdout") <(tr -d '\r' < "$PAC/$BASE.esperado.stdout") || OK=0
  if [ $OK = 1 ]; then echo "OK    $NOME exit=$CODIGO" >> "$OUT/resumo.txt"
  else echo "FALHA $NOME exit=$CODIGO (esperado $ESP_COD)" >> "$OUT/resumo.txt"; FALHAS=$((FALHAS+1)); fi
done
echo "total=$TOTAL falhas=$FALHAS" >> "$OUT/resumo.txt"
cat "$OUT/resumo.txt"
xcrun simctl shutdown "$UDID"
[ $FALHAS = 0 ]
