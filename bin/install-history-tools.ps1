$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $projectRoot 'runtime'
$toolsRoot = Join-Path $runtimeRoot 'history-tools'
$compiler = Join-Path $toolsRoot 'mingw64/bin/g++.exe'
if (Test-Path -LiteralPath $compiler) { return }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$release = '14.2.0posix-19.1.7-12.0.0-msvcrt-r3'
$archiveName = 'winlibs-x86_64-posix-seh-gcc-14.2.0-mingw-w64msvcrt-12.0.0-r3.zip'
$url = "https://github.com/brechtsanders/winlibs_mingw/releases/download/$release/$archiveName"
$expectedHash = 'ff475e985a98c5f3785129baf7460db14fee27708bce35f2833db5009507f1b9'
New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
$downloadPath = Join-Path $toolsRoot $archiveName
Write-Host 'Downloading the pinned compiler for the optimization history bridge...'
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $downloadPath
if ((Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'Compiler archive SHA-256 verification failed.'
}
Write-Host 'Extracting the history bridge compiler...'
# Windows tar handles ZIP archives and avoids slow PowerShell ZIP extraction.
$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if ($tar) {
    & $tar.Source -xf $downloadPath -C $toolsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Compiler archive extraction failed.' }
} else {
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $toolsRoot -Force
}
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Compiler archive has an unexpected layout.' }
