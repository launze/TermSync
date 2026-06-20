param(
    [string]$HostName = "8.153.163.104",
    [int]$Port = 22,
    [string]$User = "root",
    [string]$Version = "0.1.5"
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

New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

Write-Host "Building server linux amd64..." -ForegroundColor Green
$env:GOOS = "linux"
$env:GOARCH = "amd64"
$env:CGO_ENABLED = "0"
Invoke-Checked "go" @("build", "-o", (Join-Path $releaseDir "termsync-server"), ".") (Join-Path $root "server")
Remove-Item Env:\GOOS -ErrorAction SilentlyContinue
Remove-Item Env:\GOARCH -ErrorAction SilentlyContinue
Remove-Item Env:\CGO_ENABLED -ErrorAction SilentlyContinue

Write-Host "Building Android release APK..." -ForegroundColor Green
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
Invoke-Checked (Join-Path $root "mobile-android\gradlew.bat") @("assembleRelease") (Join-Path $root "mobile-android")
$apkCandidates = Get-ChildItem -Path (Join-Path $root "mobile-android\app\build\outputs\apk\release") -Filter "*.apk" -File |
    Where-Object { $_.Name -notmatch "unsigned" } |
    Sort-Object LastWriteTime -Descending
if (-not $apkCandidates) {
    throw "No signed release APK found"
}
$androidVersioned = Join-Path $releaseDir "termsync-android-v$Version.apk"
$androidLatest = Join-Path $releaseDir "TermSync-Android-latest.apk"
Copy-Checked $apkCandidates[0].FullName $androidVersioned
Copy-Checked $apkCandidates[0].FullName $androidLatest

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
$desktopMsiVersioned = Join-Path $releaseDir "termsync-desktop-windows-x64-v$Version.msi"
$desktopMsiLatest = Join-Path $releaseDir "TermSync-Desktop-Windows-latest.msi"
$desktopSetupVersioned = Join-Path $releaseDir "termsync-desktop-windows-x64-v$Version-setup.exe"
$desktopSetupLatest = Join-Path $releaseDir "TermSync-Desktop-Windows-Setup-latest.exe"
Copy-Checked $msi.FullName $desktopMsiVersioned
Copy-Checked $msi.FullName $desktopMsiLatest
Copy-Checked $setup.FullName $desktopSetupVersioned
Copy-Checked $setup.FullName $desktopSetupLatest

Write-Host "Uploading artifacts..." -ForegroundColor Green
Invoke-Checked "ssh" @("-i", $key, "-o", "StrictHostKeyChecking=accept-new", "-p", "$Port", $remote, "mkdir -p /opt/termsync/downloads /opt/termsync/server-artifacts /opt/termsync/deploy-backups")
Invoke-Checked "scp" @("-i", $key, "-P", "$Port", (Join-Path $releaseDir "termsync-server"), "${remote}:/opt/termsync/server-artifacts/termsync-server-v$Version")
Invoke-Checked "scp" @("-i", $key, "-P", "$Port", $androidVersioned, $androidLatest, $desktopMsiVersioned, $desktopMsiLatest, $desktopSetupVersioned, $desktopSetupLatest, "${remote}:/opt/termsync/downloads/")

$remoteScript = @"
set -e
cd /opt/termsync
ts=`$(date +%Y%m%d%H%M%S)
cp -f termsync-server "deploy-backups/termsync-server.`$ts"
install -m 0755 "server-artifacts/termsync-server-v$Version" termsync-server
systemctl restart termsync.service
sleep 1
systemctl is-active --quiet termsync.service
ls -lh /opt/termsync/downloads/*$Version* /opt/termsync/downloads/*latest* | tail -n 20
"@
Invoke-Checked "ssh" @("-i", $key, "-o", "StrictHostKeyChecking=accept-new", "-p", "$Port", $remote, $remoteScript)

Write-Host "Deployment complete: $Version" -ForegroundColor Green
