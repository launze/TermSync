# TTY1 启动脚本

Write-Host "`n═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "║           TTY1 终端模拟器                 ║" -ForegroundColor Cyan
Write-Host "║        跨平台同步终端方案                  ║" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════`n" -ForegroundColor Cyan

function Show-Menu {
    Write-Host "请选择要启动的组件：" -ForegroundColor Yellow
    Write-Host "  [1] 服务器端 (Go)" -ForegroundColor Green
    Write-Host "  [2] 桌面端 (Rust/Tauri)" -ForegroundColor Green
    Write-Host "  [3] 生成证书" -ForegroundColor Green
    Write-Host "  [4] 运行测试" -ForegroundColor Green
    Write-Host "  [5] 清理构建" -ForegroundColor Green
    Write-Host "  [0] 退出`n" -ForegroundColor Green
}

function Start-Server {
    Write-Host "`n🚀 启动 TTY1 服务器..." -ForegroundColor Cyan
    Set-Location "$PSScriptRoot\server"
    
    # 检查证书是否存在
    if (-not (Test-Path "certs\server.crt")) {
        Write-Host "⚠️ 证书不存在，正在生成..." -ForegroundColor Yellow
        go run ./cmd/gencert
    }
    
    Write-Host "📡 WSS 端口: 8443" -ForegroundColor Green
    Write-Host "🌐 HTTP 端口: 8080 (重定向到HTTPS)`n" -ForegroundColor Green
    
    & .\termsync-server.exe
}

function Start-Desktop {
    Write-Host "`n💻 启动桌面端..." -ForegroundColor Cyan
    Set-Location "$PSScriptRoot\desktop\src-tauri"
    
    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        cargo tauri dev
    } else {
        Write-Host "❌ 未找到 Rust/Cargo，请先安装 Rust: https://rustup.rs/" -ForegroundColor Red
    }
}

function Update-Certs {
    Write-Host "`n🔑 生成自签名证书..." -ForegroundColor Cyan
    Set-Location "$PSScriptRoot\server"
    
    go run ./cmd/gencert
    
    # 复制证书到其他端
    if (Test-Path "certs\server.crt") {
        Copy-Item "certs\server.crt" "..\desktop\assets\server.crt" -Force
        Copy-Item "certs\server.crt" "..\mobile-android\app\src\main\res\raw\server_cert.crt" -Force
        Write-Host "`n✅ 证书已复制到桌面端和移动端" -ForegroundColor Green
    }
}

function Invoke-Tests {
    Write-Host "`n🧪 运行服务器测试..." -ForegroundColor Cyan
    Set-Location "$PSScriptRoot\server"
    
    go test ./... -v -cover
}

function Clear-BuildArtifacts {
    Write-Host "`n🧹 清理构建文件..." -ForegroundColor Cyan
    
    # 服务器
    Remove-Item "$PSScriptRoot\server\termsync-server.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item "$PSScriptRoot\server\data" -Recurse -Force -ErrorAction SilentlyContinue
    
    # 桌面端
    Remove-Item "$PSScriptRoot\desktop\src-tauri\target" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$PSScriptRoot\desktop\src-tauri\dist" -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host "✅ 清理完成" -ForegroundColor Green
}

# 主循环
while ($true) {
    Show-Menu
    $choice = Read-Host "请输入选项 [0-5]"
    
    switch ($choice) {
        "1" { Start-Server }
        "2" { Start-Desktop }
        "3" { Update-Certs }
        "4" { Invoke-Tests }
        "5" { Clear-BuildArtifacts }
        "0" { 
            Write-Host "`n👋 再见！`n" -ForegroundColor Cyan
            exit 
        }
        default { 
            Write-Host "`n❌ 无效选项，请重试`n" -ForegroundColor Red 
        }
    }
    
    Write-Host "`n按任意键继续..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Clear-Host
}
