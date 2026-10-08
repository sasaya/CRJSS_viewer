$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $projectRoot 'runtime'
$juliaDirectory = Join-Path $runtimeRoot 'julia'
$juliaExecutable = Join-Path $juliaDirectory 'bin/julia.exe'
$manifest = [IO.File]::ReadAllText((Join-Path $projectRoot 'Manifest.toml'))
$match = [regex]::Match($manifest, '(?m)^julia_version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"')
if (-not $match.Success) { throw 'Cannot read julia_version from Manifest.toml.' }
$version = $match.Groups[1].Value
if (Test-Path -LiteralPath $juliaExecutable) {
    $installedVersion = & $juliaExecutable --startup-file=no -e 'print(VERSION)'
    if ($LASTEXITCODE -ne 0 -or "$installedVersion" -ne $version) {
        throw "runtime/julia must contain Julia $version. Move the existing folder aside and retry."
    }
    Write-Host "Julia $version is already installed."
    return
}
if (Test-Path -LiteralPath $juliaDirectory) {
    throw 'runtime/julia exists but has no bin/julia.exe. Move the incomplete folder aside and retry.'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Write-Host "Looking up Julia $version in the official release catalog..."
$catalog = Invoke-RestMethod -Uri 'https://julialang-s3.julialang.org/bin/versions.json'
$release = $catalog.PSObject.Properties[$version]
if ($null -eq $release) { throw "Julia $version is missing from the official release catalog." }
$archive = @($release.Value.files | Where-Object { $_.triplet -eq 'x86_64-w64-mingw32' -and $_.url -match '\.zip$' })
if ($archive.Count -ne 1) { throw "No unique Windows x64 ZIP found for Julia $version." }
$archive = $archive[0]
$downloadUri = [Uri]$archive.url
if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -ne 'julialang-s3.julialang.org') {
    throw 'Unexpected Julia download URL in release catalog.'
}
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
$temporaryDirectory = Join-Path $runtimeRoot ('install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
try {
    $downloadPath = Join-Path $temporaryDirectory 'julia.zip'
    Write-Host "Downloading Julia $version..."
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUri -OutFile $downloadPath
    if ((Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash -ne $archive.sha256) {
        throw 'Julia archive SHA-256 verification failed.'
    }
    Write-Host 'Extracting Julia...'
    $extractDirectory = Join-Path $temporaryDirectory 'extracted'
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractDirectory
    $extractedJulia = Join-Path $extractDirectory "julia-$version"
    $executable = Join-Path $extractedJulia 'bin/julia.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'Julia archive has an unexpected directory layout.' }
    $actualVersion = & $executable --startup-file=no -e 'print(VERSION)'
    if ($LASTEXITCODE -ne 0 -or "$actualVersion" -ne $version) { throw 'Downloaded Julia failed its version check.' }
    $runtimePrefix = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
    foreach ($movePath in @($extractedJulia, $juliaDirectory)) {
        if (-not [IO.Path]::GetFullPath($movePath).StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to move a Julia folder outside runtime.'
        }
    }
    Move-Item -LiteralPath $extractedJulia -Destination $juliaDirectory
} finally {
    $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDirectory)
    $resolvedRuntime = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
    if (-not $resolvedTemporary.StartsWith($resolvedRuntime, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to clean a temporary folder outside runtime.'
    }
    Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
}
