#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$ListDir = Join-Path $ScriptDir 'domain-lists'

# --- input ---
$routers = @(
    @{ Label = '192.168.47.1';                    Ip = '192.168.47.1' },
    @{ Label = '192.168.48.1';                    Ip = '192.168.48.1' },
    @{ Label = '192.168.49.1';                    Ip = '192.168.49.1' },
    @{ Label = '192.168.50.1';                    Ip = '192.168.50.1' },
    @{ Label = '192.168.51.1';                    Ip = '192.168.51.1' }
)
Write-Host 'Select Keenetic router:'
for ($i = 0; $i -lt $routers.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $routers[$i].Label) }
Write-Host '  0) enter IP manually'
$choice = Read-Host 'Number'
if ($choice -match '^[1-9]\d*$' -and [int]$choice -le $routers.Count) { $ip = $routers[[int]$choice - 1].Ip }
elseif ($choice -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $choice }
else { $ip = Read-Host 'Keenetic router IP (e.g. 192.168.1.1)' }
Write-Host "Router: $ip"
$login = Read-Host 'Login (Enter = admin)'
if (-not $login) { $login = 'admin' }
$sec = Read-Host 'Password' -AsSecureString
$pass = [System.Net.NetworkCredential]::new('', $sec).Password
$iface = Read-Host 'VPN interface to route all lists through, e.g. Wireguard2 (Enter = do not assign routes)'

$base = "http://$ip"
$sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession

function Get-Hdr($err, $name) {
    $h = $err.Exception.Response.Headers
    if ($h -is [System.Net.WebHeaderCollection]) { return $h[$name] }
    return ($h.GetValues($name) | Select-Object -First 1)
}
function Get-Hash($algo, [string]$s) {
    $a = [System.Security.Cryptography.HashAlgorithm]::Create($algo)
    -join ($a.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') })
}

# --- auth (challenge-response) ---
$needAuth = $false
try {
    Invoke-WebRequest "$base/auth" -WebSession $sess -UseBasicParsing | Out-Null
} catch {
    $needAuth = $true
    $realm = Get-Hdr $_ 'X-NDM-Realm'
    $challenge = Get-Hdr $_ 'X-NDM-Challenge'
    if (-not $realm -or -not $challenge) { throw "Router $ip returned no auth params: $($_.Exception.Message)" }
}
if ($needAuth) {
    $md5 = Get-Hash 'MD5' "${login}:${realm}:${pass}"
    $sha = Get-Hash 'SHA256' ($challenge + $md5)
    $body = @{ login = $login; password = $sha } | ConvertTo-Json -Compress
    try {
        Invoke-WebRequest "$base/auth" -Method Post -Body $body -ContentType 'application/json' -WebSession $sess -UseBasicParsing | Out-Null
    } catch { throw 'Authentication failed: wrong login or password.' }
}

# Sends commands in one request (context is kept between them). Returns number of failed commands.
function Send-Rci([string[]]$cmds) {
    $arr = @($cmds | ForEach-Object { @{ parse = $_ } })
    $json = ConvertTo-Json -InputObject $arr -Compress
    $res = @(Invoke-RestMethod "$base/rci/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
        -ContentType 'application/json; charset=utf-8' -WebSession $sess)
    $bad = 0
    for ($i = 0; $i -lt $res.Count; $i++) {
        foreach ($s in @($res[$i].parse.status)) {
            if ($s.status -eq 'error') {
                $bad++
                if ($bad -le 3) { Write-Warning ("'{0}' -> {1}" -f $cmds[$i], $s.message) }
            }
        }
    }
    if ($bad -gt 3) { Write-Warning "...and $($bad - 3) more errors" }
    return $bad
}

# --- existing object-group fqdn: description -> name ---
$byDesc = @{}
$used = @{}
$rc = Invoke-RestMethod "$base/rci/show/running-config" -WebSession $sess
if (-not $rc.message) { Write-Warning 'Could not read running-config, existing groups will not be reused.' }
$cur = $null
foreach ($line in $rc.message) {
    if ($line -match '^\s*object-group fqdn (\S+)') { $cur = $Matches[1]; $used[$cur] = $true }
    elseif ($cur -and $line -match '^\s*description (.+)$') { $byDesc[$Matches[1].Trim()] = $cur }
    elseif ($line -match '^\s*!\s*$') { $cur = $null }
}
function New-GroupName {
    $n = 0
    while ($used.ContainsKey("domain-list$n")) { $n++ }
    $used["domain-list$n"] = $true
    return "domain-list$n"
}

# --- lists ---
$files = Get-ChildItem -Path $ListDir -Filter *.txt -File
if (-not $files) { throw "No .txt files in $ListDir" }

$ipv4Re = '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$'
$ipv6Re = '^[0-9a-f]*:[0-9a-f:\.]*(/\d{1,3})?$'
$domRe  = '^[a-z0-9]([a-z0-9\-\.]*[a-z0-9])?$'

foreach ($f in $files) {
    # telegram_ipv4.txt -> description "telegram"
    $desc = $f.BaseName -replace '_ipv[46]$', ''
    $items = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 |
        ForEach-Object { ($_ -replace '#.*$', '').Trim().ToLower() } |
        Where-Object { $_ } |
        ForEach-Object { ($_ -split '\s+')[-1] } |
        ForEach-Object { $_ -replace '^\*\.', '' -replace '\.$', '' } |
        Where-Object { $_ -match $ipv4Re -or $_ -match $ipv6Re -or $_ -match $domRe } |
        Select-Object -Unique)

    if (-not $items) { Write-Host "[$desc] empty, skipped"; continue }

    if ($byDesc.ContainsKey($desc)) { $name = $byDesc[$desc]; $state = 'update' }
    else { $name = New-GroupName; $state = 'new'; $byDesc[$desc] = $name }

    Write-Host ("[{0}] {1} ({2}), entries: {3}" -f $f.BaseName, $name, $state, $items.Count)

    $errors = 0
    for ($i = 0; $i -lt $items.Count; $i += 80) {
        $chunk = $items[$i..([Math]::Min($i + 79, $items.Count - 1))]
        $cmds = @("object-group fqdn $name")
        if ($i -eq 0) { $cmds += "description $desc" }
        $cmds += $chunk | ForEach-Object { "include $_" }
        $cmds += 'exit'
        $errors += Send-Rci $cmds
    }
    if ($iface) { $errors += Send-Rci @('dns-proxy', "route object-group $name $iface auto", 'exit') }

    if ($errors -gt 0) { throw "[$desc] failed, aborting. Configuration NOT saved." }
}

[void](Send-Rci @('system configuration save'))
Write-Host 'Done, configuration saved.'
