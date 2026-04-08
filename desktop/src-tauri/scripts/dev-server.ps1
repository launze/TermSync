$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src'))
$prefix = 'http://127.0.0.1:1430/'

Add-Type -AssemblyName System.Web

function Test-ExistingDevServer {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:1430/' -TimeoutSec 2
        if ($response.StatusCode -ne 200) {
            return $false
        }
        return $response.Content -like '*TTY1 Terminal*'
    } catch {
        return $false
    }
}

function Get-ContentType([string]$path) {
    switch ([System.IO.Path]::GetExtension($path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.png'  { 'image/png' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.ico'  { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch [System.Net.HttpListenerException] {
    if (Test-ExistingDevServer) {
        Write-Output "[TTY1-DEV] reusing existing server at $prefix"
        exit 0
    }
    throw
}

Write-Output "[TTY1-DEV] serving $root at $prefix"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $requestPath = [System.Web.HttpUtility]::UrlDecode($context.Request.Url.AbsolutePath)
            if ([string]::IsNullOrWhiteSpace($requestPath) -or $requestPath -eq '/') {
                $requestPath = '/index.html'
            }

            $relativePath = $requestPath.TrimStart('/') -replace '/', '\'
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $relativePath))

            if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $context.Response.StatusCode = 403
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('Forbidden')
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
                continue
            }

            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $context.Response.StatusCode = 404
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not Found: $requestPath")
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
                continue
            }

            $data = [System.IO.File]::ReadAllBytes($fullPath)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = Get-ContentType $fullPath
            $context.Response.ContentLength64 = $data.Length
            $context.Response.OutputStream.Write($data, 0, $data.Length)
            $context.Response.Close()
        } catch {
            try {
                $context.Response.StatusCode = 500
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($_.Exception.ToString())
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            } catch {}
        }
    }
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}
