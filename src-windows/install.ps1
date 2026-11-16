# Install the Windows engine and the shared WorkBuddy skill.
#
# Design rules:
#   * Never assume the macOS path (~/.workbuddy) exists on Windows. Probe a list
#     of candidates, and if none matches, say so and accept -SkillDir.
#   * Installing the skill is the default (engine without skill is useless),
#     but -NoSkill lets you opt out.
#   * Nothing is written outside %LOCALAPPDATA% and the skill directory.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Source .\dist\win-x64
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Source .\dist\win-x64 -AddToPath

param(
    [string]$Source,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\wbcu'),
    [string]$SkillDir,
    [switch]$NoSkill,
    [switch]$AddToPath,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'

if (-not $Source) {
    $Source = $PSScriptRoot
    if (-not (Test-Path (Join-Path $Source 'wbcu.exe'))) {
        $Source = Join-Path $PSScriptRoot 'dist\win-x64'
    }
}
$Source = (Resolve-Path $Source).Path
if (-not (Test-Path (Join-Path $Source 'wbcu.exe'))) {
    throw "wbcu.exe not found in $Source"
}

Write-Host "=== Install binaries ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item (Join-Path $Source '*') $InstallDir -Recurse -Force

$exe = Join-Path $InstallDir 'wbcu.exe'
Write-Host "installed: $exe"

if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable('Path', "$userPath;$InstallDir", 'User')
        Write-Host "PATH updated (new terminals only): $InstallDir"
    } else {
        Write-Host "PATH already contains: $InstallDir"
    }
}

if (-not $NoSkill) {
    Write-Host ""
    Write-Host "=== Install WorkBuddy skill ===" -ForegroundColor Cyan

    $candidates = @(
        (Join-Path $env:USERPROFILE '.workbuddy\skills\workbuddy-third-hand'),
        (Join-Path $env:APPDATA 'workbuddy\skills\workbuddy-third-hand'),
        (Join-Path $env:LOCALAPPDATA 'workbuddy\skills\workbuddy-third-hand'),
        (Join-Path $env:USERPROFILE 'Documents\WorkBuddy\skills\workbuddy-third-hand')
    )

    if (-not $SkillDir) {
        foreach ($c in $candidates) {
            if (Test-Path $c) { $SkillDir = $c; break }
        }
    }
    if (-not $SkillDir) {
        foreach ($c in $candidates) {
            $parent = Split-Path -Parent $c
            if (Test-Path $parent) { $SkillDir = $c; break }
        }
    }
    if (-not $SkillDir) {
        $parent = Split-Path -Parent $candidates[0]
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $SkillDir = $candidates[0]
        Write-Host "no existing skill directory found, created: $SkillDir" -ForegroundColor Yellow
    }

    $skillSrc = Join-Path $Source 'skill\SKILL.md'
    if (Test-Path $skillSrc) {
        New-Item -ItemType Directory -Force -Path $SkillDir | Out-Null
        Copy-Item $skillSrc (Join-Path $SkillDir 'SKILL.md') -Force
        Write-Host "skill installed: $(Join-Path $SkillDir 'SKILL.md')"
    } else {
        Write-Host "skill\SKILL.md not found next to the binaries; skill not installed" -ForegroundColor Yellow
    }
}

if (-not $SkipSmoke) {
    Write-Host ""
    Write-Host "=== Smoke test ===" -ForegroundColor Cyan
    & $exe version
    & $exe selftest --json
    if ($LASTEXITCODE -ne 0) {
        Write-Host "selftest reported failures. Run 'wbcu doctor' for details." -ForegroundColor Yellow
    }
    & $exe doctor
    Write-Host ""
    Write-Host "Note: GUI acceptance is NOT part of install. Run testapps\wbcu-guitests.exe on a real desktop." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Try: $exe apps" -ForegroundColor Green
