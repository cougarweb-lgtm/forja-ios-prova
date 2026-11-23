#!/bin/bash
# I0 - sonda do simulador iOS no runner macOS.
# Prova: (1) simctl spawn devolve stdout, stderr e exit code; (2) guarda o gabarito do clang/ld64
# (otool -l, codesign -dvvv, o proprio binario) para o escritor Mach-O da Forja imitar.
set +e
OUT="${1:-saida}"
mkdir -p "$OUT"

{
  echo "== sw_vers"; sw_vers
  echo "== xcode"; xcodebuild -version
  echo "== sdks"; xcodebuild -showsdks
  echo "== runtimes"; xcrun simctl list runtimes
  echo "== devicetypes (iPhone)"; xcrun simctl list devicetypes | grep -i iphone | tail -5
} > "$OUT/ambiente.txt" 2>&1

# 1. binario de gabarito feito pelo clang do runner (arm64, plataforma iOS Simulator, minos 15.0)
xcrun --sdk iphonesimulator clang -arch arm64 -target arm64-apple-ios15.0-simulator hello.c -o "$OUT/hello_clang"
cp "$OUT/hello_clang" "$OUT/hello_clang_assinado_pelo_ld"
xcrun otool -l "$OUT/hello_clang" > "$OUT/hello_clang.otool_l.txt" 2>&1
xcrun otool -hv "$OUT/hello_clang" > "$OUT/hello_clang.otool_h.txt" 2>&1
xcrun codesign -dvvv "$OUT/hello_clang" > "$OUT/hello_clang.codesign.txt" 2>&1
xcrun codesign --verify --verbose=4 "$OUT/hello_clang" > "$OUT/hello_clang.verify.txt" 2>&1
xcrun dyldinfo -export -bind -rebase "$OUT/hello_clang" > "$OUT/hello_clang.dyldinfo.txt" 2>&1
xcrun objdump --macho --private-headers "$OUT/hello_clang" > "$OUT/hello_clang.objdump.txt" 2>&1

# 2. aparelho: um iPhone ja instalado no runner, runtime iOS mais novo
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
achados = []
for rt, devs in d.items():
    if "iOS" not in rt:
        continue
    for x in devs:
        if "iPhone" in x["name"]:
            achados.append((rt, x["name"], x["udid"]))
achados.sort()
print(achados[-1][2] if achados else "")
')
echo "UDID=$UDID" | tee "$OUT/udid.txt"
if [ -z "$UDID" ]; then
  echo "SEM IPHONE DISPONIVEL" | tee -a "$OUT/udid.txt"
  exit 0
fi
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > "$OUT/bootstatus.txt" 2>&1

# 3. spawn: stdout, stderr e exit code
xcrun simctl spawn "$UDID" "$PWD/$OUT/hello_clang" > "$OUT/spawn.stdout" 2> "$OUT/spawn.stderr"
echo "EXIT_DIRETO=$?" | tee "$OUT/spawn.exit"
xcrun simctl spawn "$UDID" /bin/sh -c "$PWD/$OUT/hello_clang; echo EXIT_VIA_SH=\$?" > "$OUT/spawn_sh.stdout" 2> "$OUT/spawn_sh.stderr"
echo "spawn via sh: $?" >> "$OUT/spawn.exit"

xcrun simctl shutdown "$UDID"
echo "FIM da sonda"
