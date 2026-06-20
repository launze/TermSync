param(
    [string]$HostName = "8.153.163.104",
    [int]$Port = 22,
    [string]$User = "root",
    [string]$Version = "0.1.8",
    [string]$ArtifactsDir = ""
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$key = Join-Path $root ".ssh\root_ed25519"
$releaseDir = Join-Path $root ".tmp\release-$Version"
$remote = "$User@$HostName"

function Invoke-Checked {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = $root)
    Write-Host ">>> $FilePath $($Arguments -join ' ')" -ForegroundColor Cyan
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath"
    }
}

function Copy-Checked {
    param([string]$Source, [string]$Target)
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing artifact: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}

function Find-Artifact {
    param([string]$Pattern, [string]$Root)
    $match = Get-ChildItem -Path $Root -Recurse -File -Filter $Pattern |
        Where-Object { $_.Length -gt 0 } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $match) {
        throw "Missing artifact matching $Pattern under $Root"
    }
    return $match.FullName
}

function Add-DownloadAsset {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Source,
        [string]$Name
    )
    $target = Join-Path $releaseDir $Name
    Copy-Checked $Source $target
    $List.Add($target)
}

New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$downloadAssets = [System.Collections.Generic.List[string]]::new()

if ($ArtifactsDir) {
    $artifactRoot = (Resolve-Path $ArtifactsDir).Path
    Write-Host "Preparing release from GitHub Actions artifacts: $artifactRoot" -ForegroundColor Green

    $serverX64 = Find-Artifact "termsync-server-linux-x64-v*" $artifactRoot
    $serverArm64 = Find-Artifact "termsync-server-linux-arm64-v*" $artifactRoot
    Copy-Checked $serverX64 (Join-Path $releaseDir "termsync-server")
    Copy-Checked $serverX64 (Join-Path $releaseDir "termsync-server-v$Version")
    Copy-Checked $serverArm64 (Join-Path $releaseDir "termsync-server-linux-arm64-v$Version")

    $android = Find-Artifact "termsync-android-release-v*.apk" $artifactRoot
    Add-DownloadAsset $downloadAssets $android "termsync-android-release-v$Version.apk"
    Add-DownloadAsset $downloadAssets $android "TermSync-Android-latest.apk"

    $windowsMsi = Find-Artifact "termsync-desktop-windows-x64-v*.msi" $artifactRoot
    $windowsSetup = Find-Artifact "termsync-desktop-windows-x64-v*-setup.exe" $artifactRoot
    Add-DownloadAsset $downloadAssets $windowsMsi "termsync-desktop-windows-x64-v$Version.msi"
    Add-DownloadAsset $downloadAssets $windowsMsi "TermSync-Desktop-Windows-latest.msi"
    Add-DownloadAsset $downloadAssets $windowsSetup "termsync-desktop-windows-x64-v$Version-setup.exe"
    Add-DownloadAsset $downloadAssets $windowsSetup "TermSync-Desktop-Windows-Setup-latest.exe"

    $macX64 = Find-Artifact "termsync-desktop-macos-x64-v*.dmg" $artifactRoot
    $macArm64 = Find-Artifact "termsync-desktop-macos-arm64-v*.dmg" $artifactRoot
    Add-DownloadAsset $downloadAssets $macX64 "termsync-desktop-macos-x64-v$Version.dmg"
    Add-DownloadAsset $downloadAssets $macX64 "TermSync-Desktop-macOS-x64-latest.dmg"
    Add-DownloadAsset $downloadAssets $macX64 "TermSync-Desktop-macOS-Intel-latest.dmg"
    Add-DownloadAsset $downloadAssets $macArm64 "termsync-desktop-macos-arm64-v$Version.dmg"
    Add-DownloadAsset $downloadAssets $macArm64 "TermSync-Desktop-macOS-arm64-latest.dmg"
    Add-DownloadAsset $downloadAssets $macArm64 "TermSync-Desktop-macOS-AppleSilicon-latest.dmg"

    $linuxX64AppImage = Find-Artifact "termsync-desktop-linux-x64-v*.AppImage" $artifactRoot
    $linuxX64Deb = Find-Artifact "termsync-desktop-linux-x64-v*.deb" $artifactRoot
    $linuxArm64AppImage = Find-Artifact "termsync-desktop-linux-arm64-v*.AppImage" $artifactRoot
    $linuxArm64Deb = Find-Artifact "termsync-desktop-linux-arm64-v*.deb" $artifactRoot
    Add-DownloadAsset $downloadAssets $linuxX64AppImage "termsync-desktop-linux-x64-v$Version.AppImage"
    Add-DownloadAsset $downloadAssets $linuxX64AppImage "TermSync-Desktop-Linux-latest.AppImage"
    Add-DownloadAsset $downloadAssets $linuxX64Deb "termsync-desktop-linux-x64-v$Version.deb"
    Add-DownloadAsset $downloadAssets $linuxX64Deb "TermSync-Desktop-Linux-latest.deb"
    Add-DownloadAsset $downloadAssets $linuxArm64AppImage "termsync-desktop-linux-arm64-v$Version.AppImage"
    Add-DownloadAsset $downloadAssets $linuxArm64AppImage "TermSync-Desktop-Linux-arm64-latest.AppImage"
    Add-DownloadAsset $downloadAssets $linuxArm64Deb "termsync-desktop-linux-arm64-v$Version.deb"
    Add-DownloadAsset $downloadAssets $linuxArm64Deb "TermSync-Desktop-Linux-arm64-latest.deb"
} else {
    Write-Host "Building server linux amd64..." -ForegroundColor Green
    $env:GOOS = "linux"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"
    Invoke-Checked "go" @("build", "-o", (Join-Path $releaseDir "termsync-server"), ".") (Join-Path $root "server")
    Copy-Checked (Join-Path $releaseDir "termsync-server") (Join-Path $releaseDir "termsync-server-v$Version")
    Remove-Item Env:\GOOS -ErrorAction SilentlyContinue
    Remove-Item Env:\GOARCH -ErrorAction SilentlyContinue
    Remove-Item Env:\CGO_ENABLED -ErrorAction SilentlyContinue

    Write-Host "Building Android release APK..." -ForegroundColor Green
    $env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot"
    $env:Path = "$env:JAVA_HOME\bin;$env:Path"
    Invoke-Checked (Join-Path $root "mobile-android\gradlew.bat") @("assembleRelease") (Join-Path $root "mobile-android")
    $apk = Get-ChildItem -Path (Join-Path $root "mobile-android\app\build\outputs\apk\release") -Filter "*.apk" -File |
        Where-Object { $_.Name -notmatch "unsigned" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $apk) {
        throw "No signed release APK found"
    }
    Add-DownloadAsset $downloadAssets $apk.FullName "termsync-android-release-v$Version.apk"
    Add-DownloadAsset $downloadAssets $apk.FullName "TermSync-Android-latest.apk"

    Write-Host "Building Windows desktop installers..." -ForegroundColor Green
    Invoke-Checked "cargo" @("tauri", "build") (Join-Path $root "desktop\src-tauri")
    $msi = Get-ChildItem -Path (Join-Path $root "desktop\src-tauri\target\release\bundle\msi") -Filter "*.msi" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    $setup = Get-ChildItem -Path (Join-Path $root "desktop\src-tauri\target\release\bundle\nsis") -Filter "*.exe" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $msi -or -not $setup) {
        throw "Missing desktop installer artifacts"
    }
    Add-DownloadAsset $downloadAssets $msi.FullName "termsync-desktop-windows-x64-v$Version.msi"
    Add-DownloadAsset $downloadAssets $msi.FullName "TermSync-Desktop-Windows-latest.msi"
    Add-DownloadAsset $downloadAssets $setup.FullName "termsync-desktop-windows-x64-v$Version-setup.exe"
    Add-DownloadAsset $downloadAssets $setup.FullName "TermSync-Desktop-Windows-Setup-latest.exe"
}

Write-Host "Uploading artifacts..." -ForegroundColor Green
Invoke-Checked "ssh" @("-i", $key, "-o", "StrictHostKeyChecking=accept-new", "-p", "$Port", $remote, "mkdir -p /opt/termsync/downloads /opt/termsync/server-artifacts /opt/termsync/deploy-backups")
Invoke-Checked "scp" @("-i", $key, "-P", "$Port", (Join-Path $releaseDir "termsync-server-v$Version"), "${remote}:/opt/termsync/server-artifacts/termsync-server-v$Version")
if (Test-Path -LiteralPath (Join-Path $releaseDir "termsync-server-linux-arm64-v$Version")) {
    Invoke-Checked "scp" @("-i", $key, "-P", "$Port", (Join-Path $releaseDir "termsync-server-linux-arm64-v$Version"), "${remote}:/opt/termsync/server-artifacts/termsync-server-linux-arm64-v$Version")
}
Invoke-Checked "scp" (@("-i", $key, "-P", "$Port") + $downloadAssets.ToArray() + @("${remote}:/opt/termsync/downloads/"))

$remoteScriptPath = Join-Path $releaseDir "deploy-remote-$Version.sh"
$remoteScript = @"
set -e
cd /opt/termsync
ts=`$(date +%Y%m%d%H%M%S)
if [ -x termsync-server ]; then
  cp -f termsync-server "deploy-backups/termsync-server.`$ts"
fi
install -m 0755 "server-artifacts/termsync-server-v$Version" termsync-server
if [ -f /opt/download-portal/generate-download-portal.py ]; then
  python3 - <<'PY'
from pathlib import Path
path = Path("/opt/download-portal/generate-download-portal.py")
text = path.read_text(encoding="utf-8")
needle = '        ("Linux DEB", r"termsync-desktop-linux-x64-v(?P<version>\\d+(?:\\.\\d+)+)\\.deb$"),\n'
insert = needle + '        ("Linux arm64 AppImage", r"termsync-desktop-linux-arm64-v(?P<version>\\d+(?:\\.\\d+)+)\\.AppImage$"),\n        ("Linux arm64 DEB", r"termsync-desktop-linux-arm64-v(?P<version>\\d+(?:\\.\\d+)+)\\.deb$"),\n'
if "termsync-desktop-linux-arm64-v" not in text and needle in text:
    path.write_text(text.replace(needle, insert), encoding="utf-8")
PY
  python3 /opt/download-portal/generate-download-portal.py
fi
systemctl restart termsync.service
sleep 1
systemctl is-active --quiet termsync.service
if systemctl list-unit-files download-portal-8888.service >/dev/null 2>&1; then
  systemctl stop download-portal-8888.service || true
  old_pids=`$(ss -ltnp 'sport = :8888' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)
  for old_pid in `$old_pids; do
    old_comm=`$(ps -p "`$old_pid" -o comm= 2>/dev/null || true)
    if [ "`$old_comm" = "download-portal" ]; then
      kill "`$old_pid" || true
    fi
  done
  sleep 1
  systemctl reset-failed download-portal-8888.service || true
  systemctl start download-portal-8888.service
elif systemctl list-unit-files download-portal.service >/dev/null 2>&1; then
  systemctl restart download-portal.service
fi
ls -lh /opt/termsync/server-artifacts/termsync-server*v$Version* /opt/termsync/downloads/*$Version* /opt/termsync/downloads/*latest* | tail -n 80
"@
$remoteScript = $remoteScript -replace "`r`n", "`n"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($remoteScriptPath, $remoteScript, $utf8NoBom)
Invoke-Checked "scp" @("-i", $key, "-P", "$Port", $remoteScriptPath, "${remote}:/tmp/termsync-deploy-$Version.sh")
Invoke-Checked "ssh" @("-i", $key, "-o", "StrictHostKeyChecking=accept-new", "-p", "$Port", $remote, "bash /tmp/termsync-deploy-$Version.sh")

Write-Host "Deployment complete: $Version" -ForegroundColor Green
