# Updates the self-contained HTML from the checked-in Lism and theme sources.
# No npm, Node, Python, CDN or build server is needed by the application.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pagePath = Join-Path $projectRoot 'web/index.html'
$page = [IO.File]::ReadAllText($pagePath)
$lism = [IO.File]::ReadAllText((Join-Path $projectRoot 'web/vendor/lism-css/dist/css/main.css'))
$license = [IO.File]::ReadAllText((Join-Path $projectRoot 'web/vendor/lism-css/LICENSE'))
$theme = [IO.File]::ReadAllText((Join-Path $projectRoot 'web/lism-theme.css'))
function Set-EmbeddedStyle([string]$content,[string]$marker,[string]$style) {
    $opening = '<!-- ' + $marker + '_START -->'
    $closing = '<!-- ' + $marker + '_END -->'
    $start = $content.IndexOf($opening)
    $finish = $content.IndexOf($closing)
    if ($start -lt 0 -or $finish -lt $start) { throw "Embedded style marker missing: $marker" }
    $finish += $closing.Length
    $content.Substring(0,$start) + $opening + "`n" + $style + "`n" + $closing + $content.Substring($finish)
}
$page = Set-EmbeddedStyle $page 'LISM_CSS' ('<style id="lism-css" data-version="1.0.1">' + "`n/* Lism CSS 1.0.1`n" + $license + "`n*/`n" + $lism + "`n</style>")
$page = Set-EmbeddedStyle $page 'APP_THEME' ('<style id="app-theme">' + "`n" + $theme + "`n</style>")
[IO.File]::WriteAllText($pagePath,$page,[Text.UTF8Encoding]::new($false))
