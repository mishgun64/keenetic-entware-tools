#requires -Version 5.1
<#
.SYNOPSIS
  Local WireGuard configuration manager for Windows.
.DESCRIPTION
  Creates and manages server/client configuration files locally.
  It does NOT apply changes to a running Linux server or Keenetic router.
  Requires wg.exe (WireGuard for Windows) in PATH or -WgPath.

  Everything is written to the directory the script is started from:

      ./<server>/server.conf          server config (with a peer block per client)
      ./<server>/clients/<name>.conf  client config

  No .json or server.base.conf side files are used: the server profile
  settings (endpoint, DNS, client AllowedIPs) are stored as "# wg-manager:"
  comment lines inside server.conf, and a client is considered enabled while
  its [Peer] block is present in server.conf.
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('server','client','help','menu')]
    [string]$Action = 'menu',

    [Parameter(Position=1)]
    [string]$Operation,

    [Parameter(Position=2)]
    [string]$Server,

    [Parameter(Position=3)]
    [string]$Name,

    [string]$Endpoint,
    [string]$Address = '10.10.0.1/24',
    [int]$ListenPort = 51820,
    [string]$DNS = '1.1.1.1',
    [string]$ClientAllowedIPs = '0.0.0.0/0, ::/0',
    [string]$Root,
    [string]$WgPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# configurations are written next to the script by default (./<server>)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
$Root = [System.IO.Path]::GetFullPath($Root)

function Show-Help {
    @'
WireGuard Manager (local configuration files)

Server:
  .\wg-manager.ps1 server init home -Endpoint vpn.example.com:51820
      [-Address 10.10.0.1/24] [-ListenPort 51820] [-DNS 1.1.1.1]
      [-ClientAllowedIPs "0.0.0.0/0, ::/0"]

Client:
  .\wg-manager.ps1 client add home ivan
  .\wg-manager.ps1 client list home
  .\wg-manager.ps1 client show home ivan
  .\wg-manager.ps1 client export home ivan
  .\wg-manager.ps1 client qr home ivan
  .\wg-manager.ps1 client disable home ivan
  .\wg-manager.ps1 client enable home ivan
  .\wg-manager.ps1 client remove home ivan

Optional:
  -Root "D:\WireGuard"   Storage directory (default: current directory)
  -WgPath "C:\Program Files\WireGuard\wg.exe"

Run without arguments for an interactive menu.

Layout (relative to the current directory):
  home/server.conf
  home/clients/ivan.conf

Notes:
  - server init creates ./home/server.conf.
  - Client operations update only the local server.conf and client .conf.
  - Upload/apply server.conf on the actual VPN server separately.
'@ | Write-Host
}

function Get-WgExecutable {
    if ($WgPath) {
        if (-not (Test-Path -LiteralPath $WgPath -PathType Leaf)) {
            throw "wg.exe not found: $WgPath"
        }
        return (Resolve-Path -LiteralPath $WgPath).Path
    }

    $cmd = Get-Command 'wg.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$env:ProgramFiles\WireGuard\wg.exe",
        "$env:ProgramFiles\WireGuard\Data\..\wg.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'wg.exe not found. Install WireGuard for Windows or pass -WgPath.'
}

function Invoke-WgText {
    param([string[]]$WgArgs, [string]$InputText)
    $exe = Get-WgExecutable
    if ($null -ne $InputText) {
        $result = $InputText | & $exe @WgArgs
    } else {
        $result = & $exe @WgArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "wg.exe failed: $($WgArgs -join ' ')" }
    return (($result | Out-String).Trim())
}

function Assert-Name {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[a-zA-Z0-9_-]{1,40}$') {
        throw "Invalid name '$Value'. Use 1-40 letters, digits, underscore or hyphen."
    }
}

function Get-ServerDir {
    param([string]$ServerName)
    Assert-Name $ServerName
    return (Join-Path $Root $ServerName)
}

function Get-ServerConfPath {
    param([string]$ServerName)
    return (Join-Path (Get-ServerDir $ServerName) 'server.conf')
}

function Get-ClientsDir {
    param([string]$ServerName)
    return (Join-Path (Get-ServerDir $ServerName) 'clients')
}

function Get-ClientConfPath {
    param([string]$ServerName, [string]$ClientName)
    Assert-Name $ClientName
    return (Join-Path (Get-ClientsDir $ServerName) "$ClientName.conf")
}

function Backup-File {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $Path -Destination "$Path.$stamp.bak" -Force
    }
}

# --- config parsing / writing ---------------------------------------------

function Parse-ServerConf {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $iface = @{}
    $meta = @{ Endpoint = ''; DNS = ''; ClientAllowedIPs = '' }
    $peers = New-Object System.Collections.ArrayList
    $section = ''
    $peer = $null

    foreach ($raw in @(Get-Content -LiteralPath $Path)) {
        $line = $raw.TrimEnd()

        if ($line -match '^#\s*wg-manager:\s*([A-Za-z-]+)\s*=\s*(.*)$') {
            $key = $Matches[1].ToLowerInvariant()
            $val = $Matches[2].Trim()
            switch ($key) {
                'endpoint'            { $meta['Endpoint'] = $val }
                'dns'                 { $meta['DNS'] = $val }
                'client-allowedips'   { $meta['ClientAllowedIPs'] = $val }
            }
            continue
        }
        if ($line -match '^#\s*BEGIN WG-MANAGER\s+(.+?)\s*$') {
            $peer = @{ Name = $Matches[1]; PublicKey = ''; PresharedKey = ''; AllowedIPs = '' }
            $section = 'peer'
            continue
        }
        if ($line -match '^#\s*END WG-MANAGER\s+') {
            if ($peer) { [void]$peers.Add($peer); $peer = $null }
            $section = ''
            continue
        }
        if ($line -match '^\[(.+?)\]$') { $section = $Matches[1].ToLowerInvariant(); continue }
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        $kv = $line -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $k = $kv[0].Trim().ToLowerInvariant()
        $v = $kv[1].Trim()

        if ($section -eq 'interface') {
            $iface[$k] = $v
        }
        elseif ($section -eq 'peer' -and $peer) {
            switch ($k) {
                'publickey'    { $peer.PublicKey = $v }
                'presharedkey' { $peer.PresharedKey = $v }
                'allowedips'   { $peer.AllowedIPs = $v }
            }
        }
    }
    if ($peer) { [void]$peers.Add($peer) }

    return [pscustomobject]@{
        Path             = $Path
        Name             = (Split-Path -Leaf (Split-Path -Parent $Path))
        PrivateKey       = $(if ($iface.ContainsKey('privatekey')) { $iface['privatekey'] } else { '' })
        Address          = $(if ($iface.ContainsKey('address')) { $iface['address'] } else { '' })
        ListenPort       = $(if ($iface.ContainsKey('listenport')) { $iface['listenport'] } else { '' })
        Endpoint         = $meta['Endpoint']
        DNS              = $meta['DNS']
        ClientAllowedIPs = $meta['ClientAllowedIPs']
        Peers            = @($peers)
    }
}

function Write-ServerConf {
    param($Conf)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# wg-manager server profile')
    if ($Conf.Endpoint)         { [void]$sb.AppendLine("# wg-manager: endpoint = $($Conf.Endpoint)") }
    if ($Conf.DNS)              { [void]$sb.AppendLine("# wg-manager: dns = $($Conf.DNS)") }
    if ($Conf.ClientAllowedIPs) { [void]$sb.AppendLine("# wg-manager: client-allowedips = $($Conf.ClientAllowedIPs)") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[Interface]')
    [void]$sb.AppendLine("PrivateKey = $($Conf.PrivateKey)")
    [void]$sb.AppendLine("Address = $($Conf.Address)")
    [void]$sb.AppendLine("ListenPort = $($Conf.ListenPort)")

    foreach ($p in $Conf.Peers) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("# BEGIN WG-MANAGER $($p.Name)")
        [void]$sb.AppendLine('[Peer]')
        [void]$sb.AppendLine("PublicKey = $($p.PublicKey)")
        if ($p.PresharedKey) { [void]$sb.AppendLine("PresharedKey = $($p.PresharedKey)") }
        [void]$sb.AppendLine("AllowedIPs = $($p.AllowedIPs)")
        [void]$sb.AppendLine("# END WG-MANAGER $($p.Name)")
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Conf.Path) -Force | Out-Null
    Backup-File $Conf.Path
    Set-Content -LiteralPath $Conf.Path -Value $sb.ToString() -Encoding ASCII
}

function Read-Server {
    param([string]$ServerName)
    $conf = Parse-ServerConf (Get-ServerConfPath $ServerName)
    if (-not $conf) {
        throw "Server '$ServerName' not found in $Root. Run: server init $ServerName"
    }
    return $conf
}

function Read-ClientKey {
    param([string]$ClientConfPath)
    $key = ''
    $section = ''
    foreach ($raw in @(Get-Content -LiteralPath $ClientConfPath)) {
        $line = $raw.Trim()
        if ($line -match '^\[(.+?)\]$') { $section = $Matches[1].ToLowerInvariant(); continue }
        if ($section -eq 'interface' -and $line -match '^PrivateKey\s*=\s*(.+)$') {
            $key = $Matches[1].Trim()
            break
        }
    }
    if (-not $key) { throw "No PrivateKey in $ClientConfPath" }
    return $key
}

function Read-ClientAddress {
    param([string]$ClientConfPath)
    $section = ''
    foreach ($raw in @(Get-Content -LiteralPath $ClientConfPath)) {
        $line = $raw.Trim()
        if ($line -match '^\[(.+?)\]$') { $section = $Matches[1].ToLowerInvariant(); continue }
        if ($section -eq 'interface' -and $line -match '^Address\s*=\s*(.+)$') {
            return ($Matches[1].Trim() -split ',')[0].Trim()
        }
    }
    throw "No Address in $ClientConfPath"
}

function Read-ClientPresharedKey {
    param([string]$ClientConfPath)
    $section = ''
    foreach ($raw in @(Get-Content -LiteralPath $ClientConfPath)) {
        $line = $raw.Trim()
        if ($line -match '^\[(.+?)\]$') { $section = $Matches[1].ToLowerInvariant(); continue }
        if ($section -eq 'peer' -and $line -match '^PresharedKey\s*=\s*(.+)$') {
            return $Matches[1].Trim()
        }
    }
    return ''
}

function Get-ClientNames {
    param([string]$ServerName)
    $dir = Get-ClientsDir $ServerName
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.conf' -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
}

function Find-Peer {
    param($Conf, [string]$ClientName)
    foreach ($p in $Conf.Peers) {
        if ($p.Name -eq $ClientName) { return $p }
    }
    return $null
}

# --- address allocation ----------------------------------------------------

function Convert-IPv4ToUInt32 {
    param([string]$Ip)
    $bytes = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    if ($bytes.Length -ne 4) { throw 'Only IPv4 subnets are supported for automatic address allocation.' }
    [array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-UInt32ToIPv4 {
    param([uint32]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    [array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Convert-IPv4ToUInt64 {
    param([string]$Ip)
    return [uint64](Convert-IPv4ToUInt32 $Ip)
}

function Get-ServerSubnet {
    param($Conf)
    $first = ($Conf.Address -split ',')[0].Trim()
    $parts = $first.Split('/')
    if ($parts.Count -ne 2) { throw "Server Address must be in CIDR form, got '$($Conf.Address)'." }
    $prefix = [int]$parts[1]
    if ($prefix -lt 16 -or $prefix -gt 30) { throw 'Automatic allocation supports IPv4 prefixes /16 through /30.' }

    # PS 5.1 reads 0xFFFFFFFF as Int32 -1 and -shl on UInt64 misbehaves, so
    # the mask is built from powers of two instead of a bit shift
    $hostBits = 32 - $prefix
    $mask = [uint32]([uint64]4294967296 - [uint64][math]::Pow(2, $hostBits))
    $network = [uint32]((Convert-IPv4ToUInt32 $parts[0]) -band $mask)
    $broadcast = [uint32]($network -bor ([uint32]([uint64]4294967295 - [uint64]$mask)))
    return [pscustomobject]@{ Network = $network; Broadcast = $broadcast }
}

function Get-NextClientIP {
    param($Conf)
    $net = Get-ServerSubnet $Conf

    $used = @{}
    $used[(Convert-IPv4ToUInt32 (($Conf.Address -split ',')[0].Trim() -split '/')[0])] = $true
    foreach ($p in $Conf.Peers) {
        foreach ($cidr in ($p.AllowedIPs -split ',')) {
            $addr = ($cidr.Trim() -split '/')[0]
            if ($addr -match '^\d{1,3}(\.\d{1,3}){3}$') { $used[(Convert-IPv4ToUInt32 $addr)] = $true }
        }
    }

    for ([uint64]$i = ([uint64]$net.Network + 1); $i -lt [uint64]$net.Broadcast; $i++) {
        $candidate = [uint32]$i
        if (-not $used.ContainsKey($candidate)) {
            return (Convert-UInt32ToIPv4 $candidate)
        }
    }
    throw "No free addresses in server subnet."
}

# --- operations ------------------------------------------------------------

function Initialize-Server {
    param([string]$ServerName)
    Assert-Name $ServerName
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { throw 'Specify -Endpoint, for example vpn.example.com:51820' }
    if ($ListenPort -lt 1 -or $ListenPort -gt 65535) { throw 'ListenPort must be between 1 and 65535.' }

    $dir = Get-ServerDir $ServerName
    if (Test-Path -LiteralPath $dir) { throw "Directory already exists: $dir" }

    $addressParts = $Address.Split('/')
    if ($addressParts.Count -ne 2) { throw 'Address must be in CIDR format, e.g. 10.10.0.1/24.' }
    $null = [System.Net.IPAddress]::Parse($addressParts[0])
    if ($addressParts[1] -notmatch '^\d+$') { throw 'Invalid address prefix.' }

    $null = Get-WgExecutable

    $privateKey = Invoke-WgText -WgArgs @('genkey') -InputText $null
    $publicKey = Invoke-WgText -WgArgs @('pubkey') -InputText $privateKey

    $conf = [pscustomobject]@{
        Path             = Get-ServerConfPath $ServerName
        Name             = $ServerName
        PrivateKey       = $privateKey
        Address          = $Address
        ListenPort       = $ListenPort
        Endpoint         = $Endpoint
        DNS              = $DNS
        ClientAllowedIPs = $ClientAllowedIPs
        Peers            = @()
    }
    Write-ServerConf $conf
    New-Item -ItemType Directory -Path (Get-ClientsDir $ServerName) -Force | Out-Null

    $rel = Join-Path $ServerName 'server.conf'
    Write-Host "[+] Server profile created: $rel" -ForegroundColor Green
    Write-Host "[+] Server public key: $publicKey"
    Write-Host '[!] Keep server.conf private: it contains the server private key.'
}

function Add-Client {
    param([string]$ServerName, [string]$ClientName)
    Assert-Name $ClientName
    $conf = Read-Server $ServerName
    if (Find-Peer $conf $ClientName) { throw "Client '$ClientName' already exists." }

    $clientPath = Get-ClientConfPath $ServerName $ClientName
    if (Test-Path -LiteralPath $clientPath) { throw "Client file already exists: $clientPath" }

    $privateKey = Invoke-WgText -WgArgs @('genkey') -InputText $null
    $publicKey = Invoke-WgText -WgArgs @('pubkey') -InputText $privateKey
    $psk = Invoke-WgText -WgArgs @('genpsk') -InputText $null
    $ip = Get-NextClientIP $conf
    $serverPublicKey = Invoke-WgText -WgArgs @('pubkey') -InputText $conf.PrivateKey

    $clientConfig = @(
        '[Interface]'
        "PrivateKey = $privateKey"
        "Address = $ip/32"
    ) + $(if ($conf.DNS) { @("DNS = $($conf.DNS)") } else { @() }) + @(
        ''
        '[Peer]'
        "PublicKey = $serverPublicKey"
        "PresharedKey = $psk"
        "Endpoint = $($conf.Endpoint)"
        "AllowedIPs = $($conf.ClientAllowedIPs)"
        'PersistentKeepalive = 25'
    )

    New-Item -ItemType Directory -Path (Get-ClientsDir $ServerName) -Force | Out-Null
    Set-Content -LiteralPath $clientPath -Value ($clientConfig -join "`r`n") -Encoding ASCII

    $conf.Peers = @($conf.Peers) + @([pscustomobject]@{
        Name = $ClientName; PublicKey = $publicKey; PresharedKey = $psk; AllowedIPs = "$ip/32"
    })
    Write-ServerConf $conf

    Write-Host "[+] Client created: $ClientName" -ForegroundColor Green
    Write-Host "[+] Address: $ip"
    Write-Host "[+] Config: $(Join-Path $ServerName "clients\$ClientName.conf")"
}

function Set-ClientEnabled {
    param([string]$ServerName, [string]$ClientName, [bool]$Enabled)

    $conf = Read-Server $ServerName
    $clientPath = Get-ClientConfPath $ServerName $ClientName
    if (-not (Test-Path -LiteralPath $clientPath)) { throw "Client '$ClientName' not found on server '$ServerName'." }

    $peer = Find-Peer $conf $ClientName

    if ($Enabled) {
        if ($peer) { Write-Host "Client '$ClientName' is already enabled."; return }
        $privateKey = Read-ClientKey $clientPath
        $publicKey = Invoke-WgText -WgArgs @('pubkey') -InputText $privateKey
        $conf.Peers = @($conf.Peers) + @([pscustomobject]@{
            Name = $ClientName
            PublicKey = $publicKey
            PresharedKey = (Read-ClientPresharedKey $clientPath)
            AllowedIPs = (Read-ClientAddress $clientPath)
        })
        Write-ServerConf $conf
        Write-Host "[+] Client '$ClientName' enabled." -ForegroundColor Green
    }
    else {
        if (-not $peer) { Write-Host "Client '$ClientName' is already disabled."; return }
        $conf.Peers = @($conf.Peers | Where-Object { $_.Name -ne $ClientName })
        Write-ServerConf $conf
        Write-Host "[+] Client '$ClientName' disabled." -ForegroundColor Green
    }
}

# --- interactive menu ------------------------------------------------------

function Read-Choice {
    param([string]$Prompt)
    return (Read-Host $Prompt).Trim()
}

function Read-ChoiceDefault {
    param([string]$Prompt, [string]$Default)
    $value = Read-Choice "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Get-ServerNames {
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'server.conf') } |
        Sort-Object Name | ForEach-Object { $_.Name })
}

function Select-InteractiveServer {
    $names = @(Get-ServerNames)
    Write-Host ''
    Write-Host 'Servers:'
    if ($names.Count -eq 0) {
        Write-Host '  (no servers yet, create one first)'
        return $null
    }
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $names[$i])
    }
    Write-Host '  b) back'
    while ($true) {
        $answer = Read-Choice 'Number or name'
        if ($answer -match '^(b|back|q|quit)$') { return $null }
        if ($answer -match '^\d+$') {
            $idx = [int]$answer - 1
            if ($idx -ge 0 -and $idx -lt $names.Count) { return $names[$idx] }
        }
        if ($names -contains $answer) { return $answer }
        Write-Host 'Invalid choice.'
    }
}

function Select-InteractiveClient {
    param([string]$ServerName)
    $names = @(Get-ClientNames $ServerName)
    Write-Host ''
    Write-Host "Clients of '$ServerName':"
    if ($names.Count -eq 0) {
        Write-Host '  (none yet)'
        return $null
    }
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $names[$i])
    }
    Write-Host '  b) back'
    while ($true) {
        $answer = Read-Choice 'Number or name'
        if ($answer -match '^(b|back|q|quit)$') { return $null }
        if ($answer -match '^\d+$') {
            $idx = [int]$answer - 1
            if ($idx -ge 0 -and $idx -lt $names.Count) { return $names[$idx] }
        }
        if ($names -contains $answer) { return $answer }
        Write-Host 'Invalid choice.'
    }
}

function Invoke-MenuInitServer {
    $serverName = Read-Choice 'Server name'
    if ([string]::IsNullOrWhiteSpace($serverName)) { return }
    $endpointValue = Read-Choice 'Endpoint (host:port), e.g. vpn.example.com:51820'
    if ([string]::IsNullOrWhiteSpace($endpointValue)) { Write-Host 'Endpoint is required.'; return }

    $portValue = Read-ChoiceDefault 'Listen port' "$ListenPort"
    if ($portValue -notmatch '^\d+$') { Write-Host 'Invalid port.'; return }

    $Endpoint = $endpointValue
    $Address = Read-ChoiceDefault 'Server address (CIDR)' $Address
    $ListenPort = [int]$portValue
    $DNS = Read-ChoiceDefault 'DNS for clients' $DNS
    $ClientAllowedIPs = Read-ChoiceDefault 'Client AllowedIPs' $ClientAllowedIPs

    Initialize-Server $serverName
}

function Invoke-MenuAddClient {
    $serverName = Select-InteractiveServer
    if (-not $serverName) { return }
    $clientName = Read-Choice 'New client name'
    if ([string]::IsNullOrWhiteSpace($clientName)) { return }
    Add-Client $serverName $clientName
}

function Invoke-MenuListItem([string]$ServerName) {
    $conf = Read-Server $ServerName
    $names = @(Get-ClientNames $ServerName)
    if ($names.Count -eq 0) { Write-Host 'No clients.'; return }
    $names | ForEach-Object {
        $path = Get-ClientConfPath $ServerName $_
        [pscustomobject]@{
            Name    = $_
            Address = (Read-ClientAddress $path)
            Status  = $(if (Find-Peer $conf $_) { 'Enabled' } else { 'Disabled' })
        }
    } | Format-Table -AutoSize
}

function Invoke-MenuClientAction {
    param([ValidateSet('show','export','qr','enable','disable','remove')][string]$Kind)

    $serverName = Select-InteractiveServer
    if (-not $serverName) { return }
    $clientName = Select-InteractiveClient $serverName
    if (-not $clientName) { return }

    $conf = Read-Server $serverName
    $path = Get-ClientConfPath $serverName $clientName
    if (-not (Test-Path -LiteralPath $path)) { throw "Client '$clientName' not found on server '$serverName'." }

    switch ($Kind) {
        'show' {
            Get-Content -LiteralPath $path -Raw | Write-Output
            Write-Host "`nStatus: $(if (Find-Peer $conf $clientName) { 'Enabled' } else { 'Disabled' })"
        }
        'export' { Write-Host (Resolve-Path -LiteralPath $path).Path }
        'qr' {
            $qr = Get-Command 'qrencode.exe' -ErrorAction SilentlyContinue
            if (-not $qr) { $qr = Get-Command 'qrencode' -ErrorAction SilentlyContinue }
            if (-not $qr) { throw 'qrencode not found. Install qrencode and add it to PATH.' }
            & $qr.Source '-t' 'ansiutf8' '-r' $path
            if ($LASTEXITCODE -ne 0) { throw 'qrencode failed.' }
        }
        'enable'  { Set-ClientEnabled $serverName $clientName $true }
        'disable' { Set-ClientEnabled $serverName $clientName $false }
        'remove'  {
            $confirm = Read-Host "Permanently remove client '$clientName' from '$serverName'? Type YES"
            if ($confirm -cne 'YES') { Write-Host 'Cancelled.'; return }
            Remove-Item -LiteralPath $path -Force
            if (Find-Peer $conf $clientName) {
                $conf.Peers = @($conf.Peers | Where-Object { $_.Name -ne $clientName })
                Write-ServerConf $conf
            }
            Write-Host "[+] Client '$clientName' removed." -ForegroundColor Green
        }
    }
}

function Invoke-InteractiveMenu {
    Write-Host ''
    Write-Host 'WireGuard Manager' -ForegroundColor Cyan
    Write-Host "Directory: $Root"

    while ($true) {
        Write-Host ''
        Write-Host 'What do you want to do?'
        Write-Host '  1) create server'
        Write-Host '  2) add client'
        Write-Host '  3) list clients'
        Write-Host '  4) show client config'
        Write-Host '  5) export client path'
        Write-Host '  6) show client QR'
        Write-Host '  7) enable client'
        Write-Host '  8) disable client'
        Write-Host '  9) remove client'
        Write-Host '  0) exit'

        $choice = Read-Choice 'Choice'
        if ($choice -match '^(0|q|quit|exit)$') {
            Write-Host 'Bye.'
            return
        }

        try {
            switch ($choice) {
                '1' { Invoke-MenuInitServer }
                '2' { Invoke-MenuAddClient }
                '3' {
                    $serverName = Select-InteractiveServer
                    if ($serverName) { Invoke-MenuListItem $serverName }
                }
                '4' { Invoke-MenuClientAction 'show' }
                '5' { Invoke-MenuClientAction 'export' }
                '6' { Invoke-MenuClientAction 'qr' }
                '7' { Invoke-MenuClientAction 'enable' }
                '8' { Invoke-MenuClientAction 'disable' }
                '9' { Invoke-MenuClientAction 'remove' }
                default { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
            }
        }
        catch {
            Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
        }

        $null = Read-Host 'Press Enter to continue'
    }
}

# --- dispatch --------------------------------------------------------------

if ($Action -eq 'menu') { Invoke-InteractiveMenu; exit 0 }
if ($Action -eq 'help' -or $Operation -eq 'help') { Show-Help; exit 0 }

switch ("$Action $Operation") {
    'server init' {
        if (-not $Server) { throw 'Specify server name.' }
        Initialize-Server $Server
    }
    'client add' {
        if (-not $Server -or -not $Name) { throw 'Usage: client add <server> <client>' }
        Add-Client $Server $Name
    }
    'client list' {
        if (-not $Server) { throw 'Specify server name.' }
        $conf = Read-Server $Server
        $names = @(Get-ClientNames $Server)
        if ($names.Count -eq 0) { Write-Host 'No clients.'; break }
        $names | ForEach-Object {
            $path = Get-ClientConfPath $Server $_
            [pscustomobject]@{
                Name    = $_
                Address = (Read-ClientAddress $path)
                Status  = $(if (Find-Peer $conf $_) { 'Enabled' } else { 'Disabled' })
            }
        } | Format-Table -AutoSize
    }
    'client show' {
        if (-not $Server -or -not $Name) { throw 'Usage: client show <server> <client>' }
        $conf = Read-Server $Server
        $path = Get-ClientConfPath $Server $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "Client '$Name' not found on server '$Server'." }
        Get-Content -LiteralPath $path -Raw | Write-Output
        Write-Host "`nStatus: $(if (Find-Peer $conf $Name) { 'Enabled' } else { 'Disabled' })"
    }
    'client export' {
        if (-not $Server -or -not $Name) { throw 'Usage: client export <server> <client>' }
        $path = Get-ClientConfPath $Server $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "Client config not found: $path" }
        Write-Host (Resolve-Path -LiteralPath $path).Path
    }
    'client qr' {
        if (-not $Server -or -not $Name) { throw 'Usage: client qr <server> <client>' }
        $path = Get-ClientConfPath $Server $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "Client config not found: $path" }
        $qr = Get-Command 'qrencode.exe' -ErrorAction SilentlyContinue
        if (-not $qr) { $qr = Get-Command 'qrencode' -ErrorAction SilentlyContinue }
        if (-not $qr) { throw 'qrencode not found. Install qrencode and add it to PATH.' }
        & $qr.Source '-t' 'ansiutf8' '-r' $path
        if ($LASTEXITCODE -ne 0) { throw 'qrencode failed.' }
    }
    'client disable' {
        if (-not $Server -or -not $Name) { throw 'Usage: client disable <server> <client>' }
        Set-ClientEnabled $Server $Name $false
    }
    'client enable' {
        if (-not $Server -or -not $Name) { throw 'Usage: client enable <server> <client>' }
        Set-ClientEnabled $Server $Name $true
    }
    'client remove' {
        if (-not $Server -or -not $Name) { throw 'Usage: client remove <server> <client>' }
        $conf = Read-Server $Server
        $path = Get-ClientConfPath $Server $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "Client '$Name' not found on server '$Server'." }
        $confirm = Read-Host "Permanently remove client '$Name' from '$Server'? Type YES"
        if ($confirm -cne 'YES') { Write-Host 'Cancelled.'; break }
        Remove-Item -LiteralPath $path -Force
        if (Find-Peer $conf $Name) {
            $conf.Peers = @($conf.Peers | Where-Object { $_.Name -ne $Name })
            Write-ServerConf $conf
        }
        Write-Host "[+] Client '$Name' removed." -ForegroundColor Green
    }
    default {
        Show-Help
        throw "Unknown command: $Action $Operation"
    }
}
