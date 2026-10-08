param([switch]$Offline)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    throw 'This setup requires Windows x64.'
}
$savedEnvironment = @{}
foreach ($key in @('JULIA_DEPOT_PATH', 'JULIA_LOAD_PATH', 'JULIA_PKG_OFFLINE', 'JULIA_PKG_SERVER', 'JULIA_PKG_PRECOMPILE_AUTO')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
Push-Location -LiteralPath $PSScriptRoot
try {
    if (-not $Offline) { & "$PSScriptRoot/bin/install-julia.ps1" }
    . "$PSScriptRoot/runtime-environment.ps1"
    $env:JULIA_PKG_OFFLINE = $(if ($Offline) { 'true' } else { 'false' })
    $env:JULIA_PKG_PRECOMPILE_AUTO = '0'
    $mode = $(if ($Offline) { 'offline' } else { 'online' })
    & $bundledJulia --startup-file=no --project=. bin/setup.jl $mode
    if ($LASTEXITCODE -ne 0) { throw 'Dependency setup failed. Correct the error above and run setup again.' }
    # The app and solver intentionally pin different dependency versions.
    # Check the application in a separate process, just like normal startup.
    & $bundledJulia --startup-file=no --project=. -e 'using JobShopSimProposedMethod'
    if ($LASTEXITCODE -ne 0) { throw 'Application dependency check failed.' }
    if (-not $Offline) { & "$PSScriptRoot/bin/install-history-tools.ps1" }
    & $bundledJulia --startup-file=no --project=. bin/build-history-bridge.jl $mode
    if ($LASTEXITCODE -ne 0) { throw 'Optimization history bridge build failed.' }
    Write-Host 'Setup complete. Run .\start.ps1 or double-click start.cmd.'
} finally {
    Pop-Location
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process')
    }
}
