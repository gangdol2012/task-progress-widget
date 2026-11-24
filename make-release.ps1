# Builds TaskProgressWidget.exe and packs the release ZIP into dist\.
# Needs Python 3 with PyInstaller (python -m pip install --user pyinstaller).
#   powershell -NoProfile -ExecutionPolicy Bypass -File make-release.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = (Get-Content (Join-Path $root "task-progress-bar\.claude-plugin\plugin.json") -Raw | ConvertFrom-Json).version
$build = Join-Path $root "build"
$dist = Join-Path $root "dist"
$stage = Join-Path $build "task-progress-widget"
Remove-Item $build, $dist -Recurse -Force -ErrorAction SilentlyContinue

# Claude refuses a mod that fails its validator, silently, so check first.
# Uses `claude` on PATH, or the copy the Claude desktop app ships.
$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $claude = Get-ChildItem "$env:LOCALAPPDATA\Claude-Data\claude_*\claude-code\*\*\claude.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $claude) { throw "Claude Code not found; can't validate the mod" }
Write-Host "Validating the mod..."
& $claude plugin validate (Join-Path $root "task-progress-bar") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "The mod failed 'claude plugin validate'; fix it before releasing" }

# The widget's About line shows its own VERSION; it must match the mod's.
$widgetSource = Get-Content (Join-Path $root "task-progress-bar\widget\progress_widget.py") -Raw
$widgetVersion = [regex]::Match($widgetSource, '(?m)^VERSION = "([^"]+)"').Groups[1].Value
if ($widgetVersion -ne $version) {
    throw "progress_widget.py has VERSION = `"$widgetVersion`" but plugin.json says $version; make them match"
}

Write-Host "Building TaskProgressWidget.exe (v$version)..."
python -m PyInstaller --noconfirm --clean --onefile --windowed --name TaskProgressWidget `
    --distpath (Join-Path $build "exe") --workpath (Join-Path $build "work") --specpath $build `
    (Join-Path $root "task-progress-bar\widget\progress_widget.py") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }

New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($f in @("install.bat", "install.ps1", "uninstall.bat", "uninstall.ps1", "README.md", "LICENSE")) {
    Copy-Item (Join-Path $root $f) $stage
}
Copy-Item (Join-Path $root "task-progress-bar") $stage -Recurse
Get-ChildItem $stage -Recurse -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
Copy-Item (Join-Path $build "exe\TaskProgressWidget.exe") (Join-Path $stage "task-progress-bar\widget\")

New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "task-progress-widget-v$version.zip"
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Done: $zip"
