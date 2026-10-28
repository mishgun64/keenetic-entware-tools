<#
.SYNOPSIS
  Копирует ./nfqws2 -> роутер:/opt/etc/nfqws2 через scp -O.
.EXAMPLE
  .\deploy-nfqws2.ps1 -Restart
  .\deploy-nfqws2.ps1 -RouterHost 192.168.1.1 -Port 22
#>
[CmdletBinding()]
param(
    [string]$RouterHost = '192.168.1.1',
    [int]$Port = 22,
    [string]$User = 'root',
    [string]$LocalDir = '.\nfqws2',
    [string]$RemoteDir = '/opt/etc/nfqws2',
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

foreach ($c in 'ssh', 'scp') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        throw "Не найден $c (нужен OpenSSH Client)"
    }
}
if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
    throw "Нет каталога $LocalDir"
}

$target = "$User@$RouterHost"

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe завершился с кодом $LASTEXITCODE" }
}

function Invoke-Remote([string]$Command) {
    Invoke-Native ssh @('-p', $Port, '-o', 'ConnectTimeout=10', $target, $Command)
}

Write-Host '==> Бэкап текущей конфигурации на роутере'
Invoke-Remote "[ -d '$RemoteDir' ] && cp -a '$RemoteDir' '$RemoteDir.bak' || mkdir -p '$RemoteDir'"

# -O: legacy scp-протокол (у dropbear на Keenetic нет sftp-server)
Write-Host "==> Копирование $LocalDir -> ${RouterHost}:$RemoteDir"
Push-Location -LiteralPath $LocalDir
try {
    $items = @(Get-ChildItem -Force | ForEach-Object Name)
    if ($items.Count -eq 0) { throw "Каталог $LocalDir пуст" }
    Invoke-Native scp (@('-O', '-r', '-P', $Port) + $items + @("${target}:$RemoteDir/"))
}
finally {
    Pop-Location
}

if ($Restart) {
    Write-Host '==> Перезапуск nfqws2'
    Invoke-Remote 'for s in /opt/etc/init.d/S*nfqws2*; do [ -x "$s" ] && "$s" restart; done'
}

Write-Host '==> Готово'