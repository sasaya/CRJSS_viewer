$ErrorActionPreference = 'Stop'
$applicationRoot = $PSScriptRoot
$bundledJulia = Join-Path $applicationRoot 'runtime/julia/bin/julia.exe'
if (-not (Test-Path -LiteralPath $bundledJulia)) { throw 'Juliaが見つかりません。先にsetup.cmdまたはsetup.ps1を実行してください。' }
$env:JULIA_DEPOT_PATH = Join-Path $applicationRoot 'runtime/depot'
$env:JULIA_LOAD_PATH = '@;@stdlib'
$env:JULIA_PKG_OFFLINE = 'true'
# Keep compressed bundled registries enabled. Offline mode prevents package updates;
# setup uses update_registry=false and requires no connection to this URL.
$env:JULIA_PKG_SERVER = 'https://pkg.julialang.org'
