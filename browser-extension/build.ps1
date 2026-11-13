param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'))

$ErrorActionPreference = 'Stop'
# PS 5.1 reads UTF-8 as ANSI by default, which corrupts the Chinese name in
# manifest.json and breaks ConvertFrom-Json. Keep this script ASCII-only.
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') | ConvertFrom-Json
$files = @('manifest.json', 'media.mjs', 'worker.js', 'popup.html', 'popup.css', 'popup.js')
$files += $manifest.icons.PSObject.Properties.Value
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$archive = Join-Path $OutputDirectory "SegmentDesk-Chrome-Extension-$($manifest.version).zip"
$paths = $files | ForEach-Object { Join-Path $PSScriptRoot $_ }
Compress-Archive -LiteralPath $paths -DestinationPath $archive -Force
Get-Item -LiteralPath $archive
