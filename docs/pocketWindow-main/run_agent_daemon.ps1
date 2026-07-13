# PocketWindow Agent Daemon - auto-restart on crash
$agentScript = "F:\projects\pocketWindow\control-agent\src\agent_simple.py"
$venvPython = "F:\projects\pocketWindow\control-agent\.venv\Scripts\python.exe"
$logFile = "$env:LOCALAPPDATA\PocketWindow\agent_daemon.log"
$server = "192.168.31.77"
$port = 58080

function Write-Log {
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Out-File -FilePath $logFile -Append -Encoding UTF8
}

Write-Log "Daemon started"
while ($true) {
    $proc = Get-Process -Name python -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*agent_simple*" }
    if (-not $proc) {
        Write-Log "Agent not running, starting..."
        $p = Start-Process -FilePath $venvPython -ArgumentList @($agentScript, "-s", $server, "-p", $port) -WindowStyle Hidden -PassThru
        Write-Log "Started PID $($p.Id)"
    } else {
        $p = $proc[0]
    }
    Start-Sleep -Seconds 30
    if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) {
        Write-Log "PID $($p.Id) died, will restart next cycle"
    }
}
