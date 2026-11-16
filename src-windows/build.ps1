# Build the Windows engine (and optionally publish a distributable folder).
#
# Runs on Windows with .NET SDK 8+. It also works on macOS/Linux for
# cross-compilation (EnableWindowsTargeting=true), which is how the CI
# and the maintainer's Mac verify that this code actually compiles.
#
#   powershell -ExecutionPolicy Bypass -File src-windows\build.ps1
#   powershell -ExecutionPolicy Bypass -File src-windows\build.ps1 -SkipTests
#   powershell -ExecutionPolicy Bypass -File src-windows\build.ps1 -Runtime win-arm64

param(
    [string]$Configuration = 'Release',
    [string]$Runtime = 'win-x64',
    [switch]$SkipTests,
    [switch]$SelfContained
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $here

Write-Host "=== Toolchain ===" -ForegroundColor Cyan
dotnet --version
Write-Host ""

Write-Host "=== Restore + build ===" -ForegroundColor Cyan
dotnet build (Join-Path $here 'Wbcu.sln') -c $Configuration -nologo
if ($LASTEXITCODE -ne 0) { throw "build failed" }

if (-not $SkipTests) {
    Write-Host ""
    Write-Host "=== Unit tests (pure logic, no desktop needed) ===" -ForegroundColor Cyan
    dotnet test (Join-Path $here 'Wbcu.Tests\Wbcu.Tests.csproj') -c $Configuration --nologo
    if ($LASTEXITCODE -ne 0) { throw "unit tests failed" }
}

Write-Host ""
Write-Host "=== Publish ($Runtime) ===" -ForegroundColor Cyan
$out = Join-Path $repo "dist\$Runtime"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }

$publishArgs = @(
    (Join-Path $here 'Wbcu.Windows\Wbcu.Windows.csproj'),
    '-c', $Configuration,
    '-r', $Runtime,
    '-o', $out,
    '--nologo'
)
if ($SelfContained) { $publishArgs += '--self-contained'; $publishArgs += 'true' }
else { $publishArgs += '--self-contained'; $publishArgs += 'false' }

dotnet publish @publishArgs
if ($LASTEXITCODE -ne 0) { throw "publish failed" }

# Test apps are only useful for the GUI acceptance suite, ship them beside the engine.
dotnet publish (Join-Path $here 'Wbcu.TestApp.Win32\Wbcu.TestApp.Win32.csproj') -c $Configuration -r $Runtime -o (Join-Path $out 'testapps') --nologo
dotnet publish (Join-Path $here 'Wbcu.GuiTests\Wbcu.GuiTests.csproj') -c $Configuration -r $Runtime -o (Join-Path $out 'testapps') --nologo

# Ship the single shared skill file with the binaries.
$skillSrc = Join-Path $repo 'skills\workbuddy-third-hand\SKILL.md'
if (Test-Path $skillSrc) {
    New-Item -ItemType Directory -Force -Path (Join-Path $out 'skill') | Out-Null
    Copy-Item $skillSrc (Join-Path $out 'skill\SKILL.md') -Force
}

Copy-Item (Join-Path $here 'install.ps1') $out -Force
Copy-Item (Join-Path $here 'uninstall.ps1') $out -Force

$exe = Join-Path $out 'wbcu.exe'
Write-Host ""
if (Test-Path $exe) {
    $size = [Math]::Round((Get-Item $exe).Length / 1MB, 2)
    Write-Host "OK  $exe  ($size MB)" -ForegroundColor Green
    Write-Host "Next: install.ps1 -Source `"$out`""
} else {
    throw "wbcu.exe not produced"
}
