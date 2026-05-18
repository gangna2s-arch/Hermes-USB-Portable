# fix-and-run.ps1 — Download fresh windows.ps1 and launch it
$url = "https://raw.githubusercontent.com/gangna2s-arch/Hermes-USB-Portable/main/bin/windows.ps1"
$dest = Join-Path $PSScriptRoot "windows.ps1"
Write-Host "Downloading fresh windows.ps1..." 
Invoke-WebRequest -Uri $url -OutFile $dest
Write-Host "Launching..."
& $dest
