param([string]$Config = "$PSScriptRoot/examples/default.json", [int]$Port = 8081)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/runtime-environment.ps1"
if (-not [System.IO.Path]::IsPathRooted($Config)) { $Config = Join-Path $PSScriptRoot $Config }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/bin/server.jl" $Config $Port
exit $LASTEXITCODE
