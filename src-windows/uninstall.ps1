# Remove the Windows engine and (optionally) the installed skill.
#
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeState
#
# State (%LOCALAPPDATA%\wbcu) holds sessions, per-app experience and perf logs.
# It is kept by default: it is not a cache, it is accumulated knowledge.

param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\wbcu'),
    [string]$SkillDir,
    [switch]$RemoveSkill,
    [switch]$PurgeState,
    [switch]$RemoveFromPath
)

$ErrorActionPreference = 'Stop'

Write-Host "=== Stop helper processes ===" -ForegroundColor Cyan
Get-Process -Name 'wbcu' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "stopping pid=$($_.Id)"
    try { $_.Kill() } catch { }
}

if ($RemoveFromPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -like "*$InstallDir*") {
        $newPath = ($userPath -split ';' | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Host "PATH entry removed"
    }
}

Write-Host "=== Remove binaries ===" -ForegroundColor Cyan
if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "removed: $InstallDir"
} else {
    Write-Host "not present: $InstallDir"
}

if ($RemoveSkill) {
    Write-Host "=== Remove skill ===" -ForegroundColor Cyan
    if (-not $SkillDir) {
        $candidates = @(
            (Join-Path $env:USERPROFILE '.workbuddy\skills\workbuddy-third-hand'),
            (Join-Path $env:APPDATA 'workbuddy\skills\workbuddy-third-hand'),
            (Join-Path $env:LOCALAPPDATA 'workbuddy\skills\workbuddy-third-hand')
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $SkillDir = $c; break }
        }
    }
    if ($SkillDir -and (Test-Path $SkillDir)) {
        Remove-Item $SkillDir -Recurse -Force
        Write-Host "removed: $SkillDir"
    } else {
        Write-Host "skill directory not found"
    }
}

if ($PurgeState) {
    Write-Host "=== Purge state ===" -ForegroundColor Cyan
    $state = Join-Path $env:LOCALAPPDATA 'wbcu'
    if (Test-Path $state) {
        Remove-Item $state -Recurse -Force
        Write-Host "removed: $state"
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
