#requires -Version 5.1
<#
.SYNOPSIS
  Local WireGuard configuration manager for Windows.
.DESCRIPTION
  Creates and manages server/client configuration files locally.
  It does NOT apply changes to a running Linux server or Keenetic router.
  Requires wg.exe (WireGuard for Windows) in PATH or -WgPath.

  Everything is written to the directory the script is started from:

      ./<server>/server.conf   server config (with a peer block per client)
      ./<server>/<name>.conf   client config
      ./<server>/<name>.png    client QR code

  No .json or server.base.conf side files are used: the server profile
  settings (endpoint, DNS, client AllowedIPs) are stored as "# wg-manager:"
  comment lines inside server.conf. Client files live next to server.conf,
  together with a .png QR code generated for each client.
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
    [string]$DNS = '',
    [string]$ClientAllowedIPs = '0.0.0.0/0',
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
  .\wg-manager.ps1 server init wg-home -Endpoint vpn.example.com:51820
      [-Address 10.10.0.1/24] [-ListenPort 51820] [-DNS 10.10.0.1]
      [-ClientAllowedIPs "0.0.0.0/0"]

  -DNS defaults to the server address, clients get a .png QR next to their config.

Client:
  .\wg-manager.ps1 client add home ivan
  .\wg-manager.ps1 client list home
  .\wg-manager.ps1 client show home ivan
  .\wg-manager.ps1 client export home ivan
  .\wg-manager.ps1 client remove home ivan

A .png QR code is written next to every client config.

Optional:
  -Root "D:\WireGuard"   Storage directory (default: current directory)
  -WgPath "C:\Program Files\WireGuard\wg.exe"

Run without arguments for an interactive menu.

Layout (relative to the current directory, one folder per server):
  wg-home/server.conf
  wg-home/ivan.conf
  wg-home/ivan.png

Notes:
  - server init creates ./wg-home/server.conf.
  - Client files live in the same folder as server.conf.
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
    # client files live next to server.conf
    param([string]$ServerName)
    return (Get-ServerDir $ServerName)
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

function Get-ClientNames {
    param([string]$ServerName)
    $dir = Get-ClientsDir $ServerName
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.conf' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'server.conf' } |
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

    $qrPath = Join-Path (Get-ServerDir $ServerName) "$ClientName.png"
    Write-ClientQrCode -Text ($clientConfig -join "`r`n") -Path $qrPath

    Write-Host "[+] Client created: $ClientName" -ForegroundColor Green
    Write-Host "[+] Address: $ip"
    Write-Host "[+] Config: $(Join-Path $ServerName "$ClientName.conf")"
    Write-Host "[+] QR code: $(Join-Path $ServerName "$ClientName.png")"
}

# QR codes are produced as PNG files only, never printed to the terminal.
function Write-ClientQrCode {
    param([string]$Text, [string]$Path)
    try {
        Write-QrPng -Text $Text -Path $Path -BoxSize 8
    }
    catch {
        Write-Warning ("QR code not generated: " + $_.Exception.Message)
    }
}

# --- minimal QR encoder: byte mode, ECC level M, versions 1..15 ---
# Self-contained: no external tools. Uses flat script-scoped arrays because
# PowerShell unwraps multi-dimensional arrays when passed as parameters.

# data codewords, EC codewords per block, block layout (count, data codewords)
$script:QrSpec = @{
    1  = @{ Data = 16;  Ec = 10; Blocks = @(@{ Count = 1; Words = 16 }) }
    2  = @{ Data = 28;  Ec = 16; Blocks = @(@{ Count = 1; Words = 28 }) }
    3  = @{ Data = 44;  Ec = 26; Blocks = @(@{ Count = 1; Words = 44 }) }
    4  = @{ Data = 64;  Ec = 18; Blocks = @(@{ Count = 2; Words = 32 }) }
    5  = @{ Data = 86;  Ec = 24; Blocks = @(@{ Count = 2; Words = 43 }) }
    6  = @{ Data = 108; Ec = 16; Blocks = @(@{ Count = 4; Words = 27 }) }
    7  = @{ Data = 124; Ec = 18; Blocks = @(@{ Count = 4; Words = 31 }) }
    8  = @{ Data = 154; Ec = 22; Blocks = @(@{ Count = 2; Words = 38 }, @{ Count = 2; Words = 39 }) }
    9  = @{ Data = 182; Ec = 22; Blocks = @(@{ Count = 3; Words = 36 }, @{ Count = 2; Words = 37 }) }
    10 = @{ Data = 216; Ec = 26; Blocks = @(@{ Count = 4; Words = 43 }, @{ Count = 1; Words = 44 }) }
    11 = @{ Data = 254; Ec = 30; Blocks = @(@{ Count = 1; Words = 50 }, @{ Count = 4; Words = 51 }) }
    12 = @{ Data = 290; Ec = 22; Blocks = @(@{ Count = 6; Words = 36 }, @{ Count = 2; Words = 37 }) }
    13 = @{ Data = 334; Ec = 22; Blocks = @(@{ Count = 8; Words = 37 }, @{ Count = 1; Words = 38 }) }
    14 = @{ Data = 365; Ec = 24; Blocks = @(@{ Count = 4; Words = 40 }, @{ Count = 5; Words = 41 }) }
    15 = @{ Data = 415; Ec = 24; Blocks = @(@{ Count = 5; Words = 41 }, @{ Count = 5; Words = 42 }) }
}

$script:QrAlign = @{
    1  = @();             2  = @(6, 18);          3  = @(6, 22)
    4  = @(6, 26);        5  = @(6, 30);          6  = @(6, 34)
    7  = @(6, 22, 38);    8  = @(6, 24, 42);      9  = @(6, 26, 46)
    10 = @(6, 28, 50);    11 = @(6, 30, 54);      12 = @(6, 32, 58)
    13 = @(6, 34, 62);    14 = @(6, 26, 46, 66);  15 = @(6, 26, 48, 70)
}

# GF(256), primitive polynomial 0x11D
$script:GfExp = New-Object int[] 512
$script:GfLog = New-Object int[] 256
$gfValue = 1
for ($i = 0; $i -lt 255; $i++) {
    $script:GfExp[$i] = $gfValue
    $script:GfLog[$gfValue] = $i
    $gfValue = $gfValue * 2
    if ($gfValue -ge 256) { $gfValue = $gfValue -bxor 0x11D }
}
for ($i = 255; $i -lt 512; $i++) { $script:GfExp[$i] = $script:GfExp[$i - 255] }

function Get-GfMul([int]$a, [int]$b) {
    if ($a -eq 0 -or $b -eq 0) { return 0 }
    return $script:GfExp[$script:GfLog[$a] + $script:GfLog[$b]]
}

function Get-RsDivisor([int]$degree) {
    $result = New-Object 'int[]' -ArgumentList $degree
    $result[$degree - 1] = 1
    $root = 1
    for ($i = 0; $i -lt $degree; $i++) {
        for ($j = 0; $j -lt $degree; $j++) {
            $result[$j] = Get-GfMul $result[$j] $root
            if (($j + 1) -lt $degree) { $result[$j] = $result[$j] -bxor $result[$j + 1] }
        }
        $root = Get-GfMul $root 0x02
    }
    return $result
}

function Get-RsRemainder([int[]]$data, [int]$degree) {
    $divisor = Get-RsDivisor $degree
    $result = New-Object 'int[]' -ArgumentList $degree
    foreach ($byte in $data) {
        $factor = $byte -bxor $result[0]
        for ($i = 0; $i -lt ($degree - 1); $i++) { $result[$i] = $result[$i + 1] }
        $result[$degree - 1] = 0
        for ($i = 0; $i -lt $degree; $i++) {
            $result[$i] = $result[$i] -bxor (Get-GfMul $divisor[$i] $factor)
        }
    }
    return $result
}

function Get-QrPenalty($modules, $reserved, [int]$size) {
    $score = 0
    # rule 1: runs of five or more same-coloured modules
    for ($i = 0; $i -lt $size; $i++) {
        $runRow = 1; $runCol = 1
        for ($j = 1; $j -lt $size; $j++) {
            if ($modules[$i * $size + $j] -eq $modules[$i * $size + $j - 1]) { $runRow++ }
            else { if ($runRow -ge 5) { $score += $runRow - 2 }; $runRow = 1 }
            if ($modules[$j * $size + $i] -eq $modules[($j - 1) * $size + $i]) { $runCol++ }
            else { if ($runCol -ge 5) { $score += $runCol - 2 }; $runCol = 1 }
        }
        if ($runRow -ge 5) { $score += $runRow - 2 }
        if ($runCol -ge 5) { $score += $runCol - 2 }
    }
    # rule 2: 2x2 blocks of one colour
    for ($i = 0; $i -lt ($size - 1); $i++) {
        for ($j = 0; $j -lt ($size - 1); $j++) {
            $c = $modules[$i * $size + $j]
            if ($c -eq $modules[$i * $size + $j + 1] -and
                $c -eq $modules[($i + 1) * $size + $j] -and
                $c -eq $modules[($i + 1) * $size + $j + 1]) { $score += 3 }
        }
    }
    # rule 3: finder-like 1:1:3:1:1 patterns
    $patA = @($true, $false, $true, $true, $true, $false, $true, $false, $false, $false, $false)
    $patB = @($false, $false, $false, $false, $true, $false, $true, $true, $true, $false, $true)
    for ($i = 0; $i -lt $size; $i++) {
        for ($j = 0; $j -le ($size - 11); $j++) {
            $okA = $true; $okB = $true; $okC = $true; $okD = $true
            for ($k = 0; $k -lt 11; $k++) {
                if ($modules[$i * $size + $j + $k] -ne $patA[$k]) { $okA = $false }
                if ($modules[$i * $size + $j + $k] -ne $patB[$k]) { $okB = $false }
                if ($modules[($j + $k) * $size + $i] -ne $patA[$k]) { $okC = $false }
                if ($modules[($j + $k) * $size + $i] -ne $patB[$k]) { $okD = $false }
            }
            if ($okA) { $score += 40 }
            if ($okB) { $score += 40 }
            if ($okC) { $score += 40 }
            if ($okD) { $score += 40 }
        }
    }
    # rule 4: balance of dark modules
    $dark = 0
    for ($i = 0; $i -lt ($size * $size); $i++) { if ($modules[$i]) { $dark++ } }
    $percent = ($dark * 100) / ($size * $size)
    $score += [int]([math]::Floor([math]::Abs($percent - 50) / 5)) * 10
    return $score
}

function Get-QrFormatBits([int]$mask) {
    $data = $mask -band 0x07            # ECC level M is 00
    $rem = $data
    for ($i = 0; $i -lt 10; $i++) {
        $rem = $rem -shl 1
        if (($rem -band 0x400) -ne 0) { $rem = $rem -bxor 0x537 }
    }
    return ((($data -shl 10) -bor $rem) -bxor 0x5412)
}

function Get-QrVersionBits([int]$version) {
    $rem = $version
    for ($i = 0; $i -lt 12; $i++) {
        $rem = $rem -shl 1
        if (($rem -band 0x1000) -ne 0) { $rem = $rem -bxor 0x1F25 }
    }
    return (($version -shl 12) -bor $rem)
}

function Get-QrMaskBit([int]$mask, [int]$row, [int]$col) {
    switch ($mask) {
        0 { return ((($row + $col) % 2) -eq 0) }
        1 { return (($row % 2) -eq 0) }
        2 { return (($col % 3) -eq 0) }
        3 { return ((($row + $col) % 3) -eq 0) }
        4 { return ((([math]::Floor($row / 2) + [math]::Floor($col / 3)) % 2) -eq 0) }
        5 { return (((($row * $col) % 2) + (($row * $col) % 3)) -eq 0) }
        6 { return ((((($row * $col) % 2) + (($row * $col) % 3)) % 2) -eq 0) }
        7 { return ((((($row + $col) % 2) + (($row * $col) % 3)) % 2) -eq 0) }
    }
    return $false
}

function New-QrMatrix([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)

    $version = 0
    foreach ($candidate in 1..15) {
        $candidateSpec = $script:QrSpec[$candidate]
        $candidateBits = 8
        if ($candidate -ge 10) { $candidateBits = 16 }
        $capacityBytes = [math]::Floor(($candidateSpec.Data * 8 - 4 - $candidateBits) / 8)
        if ($bytes.Length -le $capacityBytes) { $version = $candidate; break }
    }
    if ($version -eq 0) { throw "QR payload too long: $($bytes.Length) bytes" }

    $spec = $script:QrSpec[$version]
    $countBits = 8
    if ($version -ge 10) { $countBits = 16 }

    # mode indicator (byte mode), character count, payload
    $bits = New-Object System.Collections.Generic.List[bool]
    for ($i = 3; $i -ge 0; $i--) { $bits.Add(((4 -shr $i) -band 1) -eq 1) }
    for ($i = ($countBits - 1); $i -ge 0; $i--) { $bits.Add((($bytes.Length -shr $i) -band 1) -eq 1) }
    foreach ($byte in $bytes) {
        for ($i = 7; $i -ge 0; $i--) { $bits.Add((($byte -shr $i) -band 1) -eq 1) }
    }

    $capacityBits = $spec.Data * 8
    $terminator = [math]::Min(4, $capacityBits - $bits.Count)
    for ($i = 0; $i -lt $terminator; $i++) { $bits.Add($false) }
    while (($bits.Count % 8) -ne 0) { $bits.Add($false) }

    $dataCodewords = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $bits.Count; $i += 8) {
        $value = 0
        for ($k = 0; $k -lt 8; $k++) { if ($bits[$i + $k]) { $value = $value -bor (1 -shl (7 - $k)) } }
        $dataCodewords.Add($value)
    }
    $padBytes = @(0xEC, 0x11)
    $padIndex = 0
    while ($dataCodewords.Count -lt $spec.Data) {
        $dataCodewords.Add($padBytes[$padIndex % 2])
        $padIndex++
    }

    # split into blocks, compute the error correction codewords
    $blocks = New-Object System.Collections.Generic.List[object]
    $offset = 0
    foreach ($group in $spec.Blocks) {
        $blockCount = $group.Count
        $blockWords = $group.Words
        for ($b = 0; $b -lt $blockCount; $b++) {
            $chunk = New-Object 'int[]' -ArgumentList $blockWords
            for ($k = 0; $k -lt $blockWords; $k++) { $chunk[$k] = $dataCodewords[$offset + $k] }
            $offset += $blockWords
            $blocks.Add([pscustomobject]@{ Data = $chunk; Ec = (Get-RsRemainder $chunk $spec.Ec) })
        }
    }

    # interleave data and EC codewords
    $final = New-Object System.Collections.Generic.List[int]
    $maxData = 0
    foreach ($block in $blocks) { if ($block.Data.Length -gt $maxData) { $maxData = $block.Data.Length } }
    for ($i = 0; $i -lt $maxData; $i++) {
        foreach ($block in $blocks) { if ($i -lt $block.Data.Length) { $final.Add($block.Data[$i]) } }
    }
    for ($i = 0; $i -lt $spec.Ec; $i++) {
        foreach ($block in $blocks) { $final.Add($block.Ec[$i]) }
    }

    $size = 17 + 4 * $version
    $modules = New-Object 'bool[]' -ArgumentList ($size * $size)
    $reserved = New-Object 'bool[]' -ArgumentList ($size * $size)
    $isFunction = New-Object 'bool[]' -ArgumentList ($size * $size)

    # finder patterns with separators
    foreach ($corner in @(@(0, 0), @(0, ($size - 7)), @(($size - 7), 0))) {
        for ($r = -1; $r -le 7; $r++) {
            for ($c = -1; $c -le 7; $c++) {
                $rr = $corner[0] + $r
                $cc = $corner[1] + $c
                if ($rr -lt 0 -or $cc -lt 0 -or $rr -ge $size -or $cc -ge $size) { continue }
                $dark = (($r -ge 0 -and $r -le 6 -and ($c -eq 0 -or $c -eq 6)) -or
                         ($c -ge 0 -and $c -le 6 -and ($r -eq 0 -or $r -eq 6)) -or
                         ($r -ge 2 -and $r -le 4 -and $c -ge 2 -and $c -le 4))
                $modules[$rr * $size + $cc] = $dark
                $isFunction[$rr * $size + $cc] = $true
            }
        }
    }

    # timing patterns
    for ($i = 8; $i -lt ($size - 8); $i++) {
        $dark = (($i % 2) -eq 0)
        $modules[6 * $size + $i] = $dark
        $isFunction[6 * $size + $i] = $true
        $modules[$i * $size + 6] = $dark
        $isFunction[$i * $size + 6] = $true
    }

    # alignment patterns
    $alignPositions = $script:QrAlign[$version]
    foreach ($ar in $alignPositions) {
        foreach ($ac in $alignPositions) {
            $onFinder = (($ar -eq 6 -and $ac -eq 6) -or
                         ($ar -eq 6 -and $ac -eq ($size - 7)) -or
                         ($ar -eq ($size - 7) -and $ac -eq 6))
            if ($onFinder) { continue }
            for ($dr = -2; $dr -le 2; $dr++) {
                for ($dc = -2; $dc -le 2; $dc++) {
                    $dark = ([math]::Max([math]::Abs($dr), [math]::Abs($dc)) -ne 1)
                    $modules[($ar + $dr) * $size + ($ac + $dc)] = $dark
                    $isFunction[($ar + $dr) * $size + ($ac + $dc)] = $true
                }
            }
        }
    }

    # reserve the format information area (filled in later, per mask)
    for ($i = 0; $i -le 8; $i++) {
        if ($i -ne 6) {
            $isFunction[8 * $size + $i] = $true
            $isFunction[$i * $size + 8] = $true
        }
    }
    for ($i = 0; $i -lt 8; $i++) {
        $isFunction[8 * $size + ($size - 1 - $i)] = $true
        $isFunction[($size - 1 - $i) * $size + 8] = $true
    }

    # version information
    if ($version -ge 7) {
        $vbits = Get-QrVersionBits $version
        for ($i = 0; $i -lt 18; $i++) {
            $bit = ((($vbits -shr $i) -band 1) -eq 1)
            $row = [math]::Floor($i / 3)
            $col = ($i % 3) + ($size - 11)
            $modules[$row * $size + $col] = $bit
            $isFunction[$row * $size + $col] = $true
            $modules[$col * $size + $row] = $bit
            $isFunction[$col * $size + $row] = $true
        }
    }

    # place data bits in the zigzag order
    $dataBits = New-Object System.Collections.Generic.List[bool]
    foreach ($cw in $final) {
        for ($i = 7; $i -ge 0; $i--) { $dataBits.Add((($cw -shr $i) -band 1) -eq 1) }
    }

    $bitIndex = 0
    $upward = $true
    for ($col = ($size - 1); $col -gt 0; $col -= 2) {
        if ($col -eq 6) { $col-- }
        for ($i = 0; $i -lt $size; $i++) {
            $row = $i
            if ($upward) { $row = $size - 1 - $i }
            foreach ($c in @($col, ($col - 1))) {
                if ($isFunction[$row * $size + $c]) { continue }
                $value = $false
                if ($bitIndex -lt $dataBits.Count) { $value = $dataBits[$bitIndex] }
                $modules[$row * $size + $c] = $value
                $bitIndex++
            }
        }
        $upward = -not $upward
    }

    # evaluate all eight masks, keep the best-scoring one
    $bestMask = 0
    $bestScore = [int]::MaxValue
    $bestModules = $null
    for ($mask = 0; $mask -lt 8; $mask++) {
        $candidate = New-Object 'bool[]' -ArgumentList ($size * $size)
        for ($r = 0; $r -lt $size; $r++) {
            for ($c = 0; $c -lt $size; $c++) {
                $index = $r * $size + $c
                $value = $modules[$index]
                if (-not $isFunction[$index] -and (Get-QrMaskBit $mask $r $c)) { $value = -not $value }
                $candidate[$index] = $value
            }
        }
        $score = Get-QrPenalty $candidate $reserved $size
        if ($score -lt $bestScore) {
            $bestScore = $score
            $bestMask = $mask
            $bestModules = $candidate
        }
    }

    # write the format information for the chosen mask
    $fmt = Get-QrFormatBits $bestMask
    $fmtBits = @()
    for ($i = 0; $i -lt 15; $i++) { $fmtBits += ((($fmt -shr $i) -band 1) -eq 1) }

    # vertical copy: bits 0..5 -> col 8 rows 0..5, bits 6,7 -> rows 7,8, bits 8..14 -> rows size-15+i
    for ($i = 0; $i -lt 15; $i++) {
        if ($i -lt 6) { $row = $i }
        elseif ($i -lt 8) { $row = $i + 1 }
        else { $row = $size - 15 + $i }
        $bestModules[$row * $size + 8] = $fmtBits[$i]
    }
    # horizontal copy: bits 0..7 -> row 8 from the right edge, bit 8 -> col 7, bits 9..14 -> cols 5..0
    for ($i = 0; $i -lt 15; $i++) {
        if ($i -lt 8) { $col = $size - 1 - $i }
        elseif ($i -lt 9) { $col = 7 }
        else { $col = 15 - $i - 1 }
        $bestModules[8 * $size + $col] = $fmtBits[$i]
    }
    $bestModules[($size - 8) * $size + 8] = $true     # dark module

    return [pscustomobject]@{
        Size    = $size
        Version = $version
        Mask    = $bestMask
        Modules = $bestModules
    }
}

function Write-QrPng([string]$Text, [string]$Path, [int]$BoxSize = 8) {
    Add-Type -AssemblyName System.Drawing
    $qr = New-QrMatrix $Text
    $quiet = 4
    $pixels = ($qr.Size + 2 * $quiet) * $BoxSize

    $bmp = New-Object System.Drawing.Bitmap $pixels, $pixels
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 0, 0))
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        for ($r = 0; $r -lt $qr.Size; $r++) {
            for ($c = 0; $c -lt $qr.Size; $c++) {
                if ($qr.Modules[$r * $qr.Size + $c]) {
                    $graphics.FillRectangle($brush,
                        (($c + $quiet) * $BoxSize), (($r + $quiet) * $BoxSize), $BoxSize, $BoxSize)
                }
            }
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $brush.Dispose()
        $graphics.Dispose()
        $bmp.Dispose()
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
    $serverName = Read-ChoiceDefault 'Server name' 'wg-home'
    $endpointValue = Read-Choice 'Endpoint (host:port), e.g. vpn.example.com:51820'
    if ([string]::IsNullOrWhiteSpace($endpointValue)) { Write-Host 'Endpoint is required.'; return }

    $portValue = Read-ChoiceDefault 'Listen port' "$ListenPort"
    if ($portValue -notmatch '^\d+$') { Write-Host 'Invalid port.'; return }

    $Endpoint = $endpointValue
    $Address = Read-ChoiceDefault 'Server address (CIDR)' $Address
    $ListenPort = [int]$portValue
    # by default the clients use the server itself as their DNS server
    $serverAddress = ($Address -split '/')[0].Trim()
    $DNS = Read-ChoiceDefault 'DNS for clients' $serverAddress
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
    param([ValidateSet('show','export','remove')][string]$Kind)

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
        'remove'  {
            $confirm = Read-Host "Permanently remove client '$clientName' from '$serverName'? Type YES"
            if ($confirm -cne 'YES') { Write-Host 'Cancelled.'; return }
            Remove-Item -LiteralPath $path -Force
            $qrPath = Join-Path (Get-ServerDir $serverName) "$clientName.png"
            if (Test-Path -LiteralPath $qrPath) { Remove-Item -LiteralPath $qrPath -Force }
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
        Write-Host '  6) remove client'
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
                '6' { Invoke-MenuClientAction 'remove' }
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
