param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'))

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') | ConvertFrom-Json
$files = @('manifest.json', 'media.mjs', 'worker.js', 'popup.html', 'popup.js')
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$archive = Join-Path $OutputDirectory "SegmentDesk-Chrome-$($manifest.version).zip"
$paths = $files | ForEach-Object { Join-Path $PSScriptRoot $_ }
Compress-Archive -LiteralPath $paths -DestinationPath $archive -Force
Get-Item -LiteralPath $archive
