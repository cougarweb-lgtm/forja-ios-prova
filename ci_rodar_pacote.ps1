# ci_rodar_pacote.ps1 - roda um PACOTE DE PROVA (binarios de teste + sidecars + SHA256SUMS.txt) no simulador iOS do CI.
# Versao: 1.0.0 (23/11/2026)
# Uso: powershell -File ci_rodar_pacote.ps1 -Dir <pasta com o pacote> [-Mensagem "texto"] [-TimeoutSeg 900]
# O que faz (e SO isto; autorizado pelo usuario para o repo cougarweb-lgtm/forja-ios-prova):
#   1. substitui o conteudo de ios_prova\pacote\ pelo de -Dir (o pacote precisa ter SHA256SUMS.txt valido);
#   2. commit (e-mail noreply) + push so de pacote/ ao repo publico de prova;
#   3. espera o workflow pacote-ios terminar e baixa o artifact resultado-pacote em ios_prova\resultado_diag\;
#   4. imprime resumo.txt (OK/FALHA por caso).
# NAO publica fonte nem compilador: so binarios de teste, esperados e o workflow.
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [string]$Mensagem = "Pacote de diagnostico",
    [int]$TimeoutSeg = 900
)
$ErrorActionPreference = "Stop"
$gh = "C:\Program Files\GitHub CLI\gh.exe"
$repo = "cougarweb-lgtm/forja-ios-prova"
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$pacote = Join-Path $base "pacote"
$saida = Join-Path $base "resultado_diag"
if (-not (Test-Path (Join-Path $Dir "SHA256SUMS.txt"))) { throw "sem SHA256SUMS.txt em $Dir" }
Push-Location $base
try {
    if (Test-Path $pacote) { Remove-Item -Recurse -Force $pacote }
    New-Item -ItemType Directory -Force $pacote | Out-Null
    Copy-Item -Path (Join-Path $Dir "*") -Destination $pacote -Recurse -Force
    git add -A pacote | Out-Null
    git commit -q -m $Mensagem
    git push -q origin main
    $t0 = Get-Date
    Start-Sleep 20
    $id = & $gh run list --repo $repo --workflow pacote-ios --limit 1 --json databaseId --jq ".[0].databaseId"
    Write-Host "run=$id"
    while ($true) {
        $st = & $gh run view $id --repo $repo --json status,conclusion | ConvertFrom-Json
        if ($st.status -eq "completed") { break }
        if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSeg) { throw "timeout esperando o run $id" }
        Start-Sleep 20
    }
    if (Test-Path $saida) { Remove-Item -Recurse -Force $saida }
    & $gh run download $id --repo $repo --name resultado-pacote --dir $saida | Out-Null
    Get-Content (Join-Path $saida "resumo.txt")
}
finally { Pop-Location }
