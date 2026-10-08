$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/runtime-environment.ps1"
Push-Location -LiteralPath $PSScriptRoot
try {
    & $bundledJulia --startup-file=no --project=. bin/setup.jl
    if ($LASTEXITCODE -ne 0) { throw '同梱環境の準備に失敗しました' }
} finally { Pop-Location }
