#!/bin/bash
# selftest_runner.sh - prova local do rodar_pacote.sh com o xcrun FALSO de selftest/xcrun.
# Roda em bash (Git Bash, Cygwin ou macOS). Nao toca no simulador de verdade.
# Uso: bash selftest_runner.sh   -> imprime cada cenario e "selftest_runner: OK" so se todos se comportarem.
# Cenarios: verde; canarios exatos; canario que passa por engano; falha fora da lista; sha adulterado
#           (nenhum caso roda); timeout nomeado TIMEOUT com continuidade; falha plantada (runner falso).
#
# Changelog
#   1.0 - primeira versao: 6 cenarios reais + 1 falha plantada, contra rodar_pacote.sh 2.0.

DIR=$(cd "$(dirname "$0")" && pwd)
RUNNER="$DIR/rodar_pacote.sh"
T=$(mktemp -d) || { echo "selftest_runner: sem mktemp"; exit 1; }
LOG="$T/xcrun.log"
RC=0
ERROS=0
export FAKE_XCRUN_LOG="$LOG"
export PATH="$DIR/selftest:$T/bin:$PATH"
mkdir -p "$T/bin" "$T/p" "$T/res"
: > "$LOG"

# Windows (Git Bash/Cygwin): o python3 pode ser o alias da Store, que nao roda. Usa o python real como apoio.
if ! python3 -I -c 'pass' >/dev/null 2>&1; then
  PY_REAL=$(command -v python)
  {
    echo '#!/bin/bash'
    echo "PY=\"$PY_REAL\""
    cat <<'FIM'
# python3 de apoio: converte argumentos de caminho /x/... para Windows, porque o python real nao le caminho Cygwin.
ARGS=()
for A in "$@"; do
  case "$A" in
    /*) ARGS+=("$(cygpath -w "$A")") ;;
    *) ARGS+=("$A") ;;
  esac
done
exec "$PY" "${ARGS[@]}"
FIM
  } > "$T/bin/python3"
  chmod +x "$T/bin/python3"
fi

# Cria um binario de brinquedo $2 (dev e release) com corpo shell $3.
binario() {
  printf '#!/bin/bash\n%s\n' "$3" > "$1/$2_dev"
  cp "$1/$2_dev" "$1/$2_release"
  chmod +x "$1/$2_dev" "$1/$2_release"
}

# Base com todos os brinquedos: 5 verdes, 3 canarios (erro proposital) e 1 que estoura o timeout.
base_toy() {
  local D="$1"
  mkdir -p "$D"
  binario "$D" passa 'echo ola'
  printf 'ola\n' > "$D/passa.esperado.stdout"; echo 0 > "$D/passa.esperado.exit"
  binario "$D" passa_b 'printf sem_newline; echo aviso >&2'
  printf 'sem_newline' > "$D/passa_b.esperado.stdout"; echo 0 > "$D/passa_b.esperado.exit"; echo aviso > "$D/passa_b.esperado.stderr_contem"
  binario "$D" entrada 'read L; echo "recebi:$L"'
  printf 'recebi:abc\n' > "$D/entrada.esperado.stdout"; echo 0 > "$D/entrada.esperado.exit"; printf 'abc\n' > "$D/entrada.stdin"
  binario "$D" argumentos 'echo "$1 $2"'
  printf 'um dois\n' > "$D/argumentos.esperado.stdout"; echo 0 > "$D/argumentos.esperado.exit"; printf 'um\ndois\n' > "$D/argumentos.args"
  binario "$D" ambiente 'echo "$FOO"'
  printf 'bar\n' > "$D/ambiente.esperado.stdout"; echo 0 > "$D/ambiente.esperado.exit"; echo 'FOO=bar' > "$D/ambiente.env"
  binario "$D" stdout_errado 'echo real'
  printf 'esperado\n' > "$D/stdout_errado.esperado.stdout"; echo 0 > "$D/stdout_errado.esperado.exit"
  binario "$D" exit_errado 'echo ok; exit 3'
  printf 'ok\n' > "$D/exit_errado.esperado.stdout"; echo 0 > "$D/exit_errado.esperado.exit"
  binario "$D" stderr_ausente 'echo ok; echo aviso >&2'
  printf 'ok\n' > "$D/stderr_ausente.esperado.stdout"; echo 0 > "$D/stderr_ausente.esperado.exit"; echo NAO_EXISTE_XYZ > "$D/stderr_ausente.esperado.stderr_contem"
  binario "$D" lento 'sleep 30'
  : > "$D/lento.esperado.stdout"; echo 0 > "$D/lento.esperado.exit"; echo 2 > "$D/lento.timeout"
}

# Gera SHA256SUMS.txt de todos os arquivos do pacote $1.
gerar_sha() {
  ( cd "$1" && shasum -a 256 $(ls | grep -v '^SHA256SUMS.txt$') > SHA256SUMS.txt )
}

# Copia a base para $T/p/$1 e devolve o caminho do pacote copiado.
copia_base() {
  local D="$T/p/$1"
  rm -rf "$D"
  cp -R "$T/base" "$D"
  echo "$D"
}

# Roda rodar_pacote.sh $1 (runner) sobre o pacote $2, resultado em $3. Define RC e limpa o log do xcrun.
rodar() {
  rm -rf "$3"
  : > "$LOG"
  bash "$1" "$2" "$3" > "$3.saida" 2>&1
  RC=$?
}

# Cenario: tudo verde, sem canarios -> exit 0.
cen_verde() {
  local D; D=$(copia_base verde)
  rm -f "$D"/stdout_errado* "$D"/exit_errado* "$D"/stderr_ausente* "$D"/lento*
  gerar_sha "$D"
  rodar "$1" "$D" "$T/res/verde"
  [ "$RC" = 0 ] && grep -q 'total=10 falhas=0' "$T/res/verde/resumo.txt"
}

# Cenario: canarios exatos (3 listados, 3 falham) e 5 verdes -> exit 0.
cen_canarios() {
  local D; D=$(copia_base canarios)
  rm -f "$D"/lento*
  printf 'stdout_errado\nexit_errado\nstderr_ausente\n' > "$D/canarios_esperados.txt"
  gerar_sha "$D"
  rodar "$1" "$D" "$T/res/canarios"
  [ "$RC" = 0 ] && grep -q 'total=16 falhas=6' "$T/res/canarios/resumo.txt" && grep -q 'VEREDITO OK' "$T/res/canarios/resumo.txt"
}

# Cenario: um canario listado passa de verdade (argumentos esta na lista) -> exit != 0.
cen_canario_passa() {
  local D; D=$(copia_base canario_passa)
  rm -f "$D"/lento*
  printf 'stdout_errado\nexit_errado\nstderr_ausente\nargumentos\n' > "$D/canarios_esperados.txt"
  gerar_sha "$D"
  rodar "$1" "$D" "$T/res/canario_passa"
  [ "$RC" != 0 ] && grep -q 'REPROVADO' "$T/res/canario_passa/resumo.txt" && grep -q 'canarios_sem_falha' "$T/res/canario_passa/resumo.txt"
}

# Cenario: falha fora da lista (stdout_errado nao esta listado) -> exit != 0.
cen_fora_lista() {
  local D; D=$(copia_base fora_lista)
  rm -f "$D"/lento*
  printf 'exit_errado\nstderr_ausente\n' > "$D/canarios_esperados.txt"
  gerar_sha "$D"
  rodar "$1" "$D" "$T/res/fora_lista"
  [ "$RC" != 0 ] && grep -q 'FALHA stdout_errado' "$T/res/fora_lista/resumo.txt" && grep -q 'REPROVADO' "$T/res/fora_lista/resumo.txt"
}

# Cenario: sha adulterado -> exit != 0 e nenhum xcrun chamado (nenhum caso rodado).
cen_sha() {
  local D; D=$(copia_base sha)
  rm -f "$D"/stdout_errado* "$D"/exit_errado* "$D"/stderr_ausente* "$D"/lento*
  gerar_sha "$D"
  echo 'echo adulterado' >> "$D/passa_dev"
  rodar "$1" "$D" "$T/res/sha"
  [ "$RC" != 0 ] && grep -q 'SHA INVALIDO' "$T/res/sha/resumo.txt" && [ ! -s "$LOG" ]
}

# Cenario: timeout -> FALHA lento com TIMEOUT, e o caso seguinte (passa) continua e fica OK.
cen_timeout() {
  local D; D=$(copia_base timeout)
  rm -f "$D"/stdout_errado* "$D"/exit_errado* "$D"/stderr_ausente*
  gerar_sha "$D"
  rodar "$1" "$D" "$T/res/timeout"
  [ "$RC" != 0 ] && grep -q 'FALHA lento_dev .*TIMEOUT' "$T/res/timeout/resumo.txt" && grep -q 'OK passa_dev' "$T/res/timeout/resumo.txt"
}

# Confere uma condicao: $1=descricao, depois o comando de teste.
checar() {
  local DESC="$1"
  shift
  if "$@"; then echo "  OK     $DESC"; else echo "  FALHA  $DESC"; ERROS=$((ERROS+1)); fi
}

base_toy "$T/base"
echo "selftest_runner: cenarios (runner: $RUNNER)"
checar "verde: tudo verde -> exit 0" cen_verde "$RUNNER"
checar "canarios exatos -> exit 0" cen_canarios "$RUNNER"
checar "canario que passa por engano -> exit != 0" cen_canario_passa "$RUNNER"
checar "falha fora da lista -> exit != 0" cen_fora_lista "$RUNNER"
checar "sha adulterado -> exit != 0 e nenhum caso rodado" cen_sha "$RUNNER"
checar "timeout nomeado TIMEOUT e continua -> exit != 0" cen_timeout "$RUNNER"

# Falha plantada: um runner que finge passar. O cenario de falha fora da lista TEM que reprova-lo.
cat > "$T/falso.sh" <<'FIM'
#!/bin/bash
# runner falso: finge que tudo passou, sem rodar nada.
mkdir -p "$2"; echo "VEREDITO OK" > "$2/resumo.txt"; exit 0
FIM
if cen_fora_lista "$T/falso.sh"; then
  echo "  FALHA  falha plantada NAO detectada (runner falso passou no cenario fora da lista)"
  ERROS=$((ERROS+1))
else
  echo "  OK     falha plantada detectada (runner falso reprovado no cenario fora da lista)"
fi

rm -rf "$T"
if [ "$ERROS" = 0 ]; then
  echo "selftest_runner: OK"
  exit 0
fi
echo "selftest_runner: FALHOU ($ERROS erro(s))"
exit 1
