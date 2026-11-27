# One-command bootstrap for Windows: download the release package, then install.
#
#   powershell -ExecutionPolicy Bypass -Command "irm <this-script-url> | iex"
#
# or, without piping:
#
#   iwr <zip-url> -OutFile wbcu.zip
#   Expand-Archive wbcu.zip -DestinationPath wbcu -Force
#   powershell -ExecutionPolicy Bypass -File wbcu\install.ps1 -Source wbcu
#
# This script does NOT claim the engine is verified. It downloads, unpacks,
# installs, and runs the engine's own selftest/doctor. GUI acceptance still has
# to be run by a human on an interactive desktop (see the printed next steps).

param(
    [string]$Url = 'https://github.com/1791986214/macos-background-computer-use/releases/download/v0.6.6-rc1/wbcu-windows-win-x64-0.6.6.zip',
    [string]$Dest = (Join-Path $env:TEMP 'wbcu-setup'),
    [string]$SkillDir,
    [switch]$AddToPath,
    [switch]$NoSkill
)

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '=== WorkBuddy Third Hand / Windows bootstrap ===' -ForegroundColor Cyan
Write-Host "package : $Url"
Write-Host "temp dir: $Dest"
Write-Host ''

if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$zip = Join-Path $Dest 'wbcu.zip'

Write-Host '[1/4] downloading ...' -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
} catch {
    Write-Host "download failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '若网络受限，请手动下载该 zip 后运行 install.ps1 -Source <解压目录>' -ForegroundColor Yellow
    exit 1
}

$size = [Math]::Round((Get-Item $zip).Length / 1MB, 2)
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Write-Host "      $size MB  sha256=$hash"

Write-Host '[2/4] extracting ...' -ForegroundColor Cyan
Expand-Archive -Path $zip -DestinationPath $Dest -Force
if (-not (Test-Path (Join-Path $Dest 'wbcu.exe'))) {
    Write-Host 'archive does not contain wbcu.exe' -ForegroundColor Red
    exit 1
}

Write-Host '[3/4] installing ...' -ForegroundColor Cyan
$installArgs = @(
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $Dest 'install.ps1'),
    '-Source', $Dest
)
if ($SkillDir) { $installArgs += '-SkillDir'; $installArgs += $SkillDir }
if ($AddToPath) { $installArgs += '-AddToPath' }
if ($NoSkill) { $installArgs += '-NoSkill' }
& powershell @installArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host 'install.ps1 reported a failure' -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host '[4/4] next steps' -ForegroundColor Cyan
$exe = Join-Path (Join-Path $env:LOCALAPPDATA 'Programs\wbcu') 'wbcu.exe'
Write-Host ''
Write-Host '  1) 看有哪些应用在跑：'
Write-Host "     `"$exe`" apps"
Write-Host '  2) 后台起计算器并建会话：'
Write-Host "     `"$exe`" launch --app calc --json"
Write-Host "     `"$exe`" attach --app calc --json"
Write-Host '  3) 语义点击 + 读值验证（把 <sid> 换成上一步返回的 id）：'
Write-Host "     `"$exe`" click --id <sid> --name 7 --json"
Write-Host '  4) 收尾：'
Write-Host "     `"$exe`" session end --id <sid>"
Write-Host ''
Write-Host '  GUI 验收（可选，需要交互式桌面；全绿才会把能力从 not_tested 升级为 supported）：' -ForegroundColor Yellow
Write-Host "     `"$Dest\testapps\wbcu-guitests.exe`" --wbcu `"$exe`" --json gui-report.json"
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
