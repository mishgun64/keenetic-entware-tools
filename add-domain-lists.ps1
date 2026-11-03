#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# lists are downloaded from this folder of the GitHub repo
$ListsApi = 'https://api.github.com/repos/mishgun64/keenetic-entware-tools/contents/domain-lists?ref=main'

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
function Invoke-Rci([string[]]$cmds) {
    $arr = @($cmds | ForEach-Object { @{ parse = $_ } })
    $json = ConvertTo-Json -InputObject $arr -Compress
    return @(Invoke-RestMethod "$base/rci/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
        -ContentType 'application/json; charset=utf-8' -WebSession $sess)
}
function Send-Rci([string[]]$cmds) {
    $res = Invoke-Rci $cmds
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

# --- DoH (dns-proxy https upstream) ---
# "dnsm" is the answer format ({json | dnsm}), not a free name: keep it as-is.
$dohFormat = 'dnsm'

# split the "dns-proxy" block: upstream lines (DNS servers) vs everything else
# (rebind-protect / route / filter ...) that must survive a rebuild
$dnsProxyLines = @()
$hasDnsProxy = $false
$inDnsProxy = $false
foreach ($line in $rc.message) {
    if ($line -match '^\S') {
        $inDnsProxy = ($line -match '^dns-proxy\s*$')
        if ($inDnsProxy) { $hasDnsProxy = $true }
        continue
    }
    if ($inDnsProxy) { $dnsProxyLines += $line.Trim() }
}
$existingUpstreams = @($dnsProxyLines | Where-Object { $_ -match '^(?:[a-z0-9-]+\s+)?upstream\s+' })
$keepLines         = @($dnsProxyLines | Where-Object { $_ -notmatch '^(?:[a-z0-9-]+\s+)?upstream\s+' })

# reads the dns-proxy block again and returns its upstream lines
function Get-LiveUpstreams {
    $cfg = Invoke-RestMethod "$base/rci/show/running-config" -WebSession $sess
    $live = @()
    $in = $false
    foreach ($line in $cfg.message) {
        if ($line -match '^\S') { $in = ($line -match '^dns-proxy\s*$'); continue }
        if (-not $in) { continue }
        $t = $line.Trim()
        if ($t -match '^(?:[a-z0-9-]+\s+)?upstream\s+') { $live += $t }
    }
    return $live
}

# Removal spelling differs between KeeneticOS builds, so several are tried.
# Both the "enter block then no ..." and the one-line "dns-proxy no ..." forms are used.
# Success is judged by re-reading the config, because RCI statuses do not line up with
# the sent commands (entering a context yields no status of its own).
function Remove-Upstreams([string[]]$targets) {
    $bare = @()
    foreach ($u in $targets) {
        $bare += "no $u"
        if ($u -match '^(?:https\s+)?upstream\s+(https?://\S+)') {
            $url = $Matches[1]
            $bare += "no https upstream $url $dohFormat"
            $bare += "no https upstream $url"
            $bare += "no upstream $url"
        }
    }
    $bare = @($bare | Select-Object -Unique)
    $variants = @()
    foreach ($b in $bare) {
        $variants += [pscustomobject]@{ Cmds = @('dns-proxy', $b, 'exit'); Text = $b }
        $variants += [pscustomobject]@{ Cmds = @("dns-proxy $b");         Text = "dns-proxy $b" }
    }
    foreach ($v in $variants) {
        $null = Invoke-Rci $v.Cmds
        $left = @(Get-LiveUpstreams)
        if ($left.Count -eq 0) {
            Write-Host ("    ok: {0}" -f $v.Text)
            return $true
        }
    }
    return $false
}

# Last resort: drop the whole section and rebuild it without any upstream lines.
function Reset-DnsProxyBlock {
    Write-Host '    fallback: rebuilding dns-proxy without upstreams'
    $null = Invoke-Rci @('no dns-proxy')
    if ($keepLines.Count -gt 0) {
        $cmds = @('dns-proxy') + $keepLines + @('exit')
        $null = Invoke-Rci $cmds
    }
    return (@(Get-LiveUpstreams).Count -eq 0)
}

$dohServers = @(
    @{ Label = 'quad9';      Url = 'https://dns.quad9.net/dns-query'      },
    @{ Label = 'google';     Url = 'https://dns.google/dns-query'         },
    @{ Label = 'cloudflare'; Url = 'https://cloudflare-dns.com/dns-query' }
)

$dohSelected = @()
Write-Host ''
Write-Host 'DoH (DNS-over-HTTPS) servers to add:'
for ($i = 0; $i -lt $dohServers.Count; $i++) {
    Write-Host ("  {0}) {1}   {2}" -f ($i + 1), $dohServers[$i].Label, $dohServers[$i].Url)
}
Write-Host '  4) all (1, 2, 3)'
Write-Host '  5) skip (Enter)'
Write-Host 'NOTE: all existing DoH upstreams will be removed first.'
$dohChoice = (Read-Host 'Selection').Trim().ToLower()
if ($dohChoice -in @('', '5', 'skip', 'none')) {
    $dohSelected = @()
}
elseif ($dohChoice -in @('4', 'all')) {
    $dohSelected = @(0, 1, 2)
}
else {
    $dohSelected = @(
        ($dohChoice -split '[,\s;]+') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^[1-3]$' } |
        ForEach-Object { [int]$_ - 1 } |
        Sort-Object
    )
}
if ($dohSelected.Count -gt 0) {
    Write-Host ''
    Write-Host 'Configuring DoH upstreams...'

    # 1) remove every DoH/DNS upstream that is already configured
    if ($existingUpstreams.Count -eq 0) {
        Write-Host '  (nothing to clear)'
    }
    else {
        foreach ($up in $existingUpstreams) { Write-Host ("  - {0}" -f $up) }
        if (-not (Remove-Upstreams $existingUpstreams)) {
            if (-not (Reset-DnsProxyBlock)) {
                throw 'Could not clear existing DNS servers. Configuration NOT saved.'
            }
        }
    }

    # 2) add the selected servers
    $cmds = @('dns-proxy')
    foreach ($idx in $dohSelected) {
        $srv = $dohServers[$idx]
        Write-Host ("  + [{0}] {1}" -f $srv.Label, $srv.Url)
        $cmds += "https upstream $($srv.Url) $dohFormat"
    }
    $cmds += 'exit'
    $null = Invoke-Rci $cmds
    $live = @(Get-LiveUpstreams | ForEach-Object { $_.ToLower() })
    foreach ($idx in $dohSelected) {
        $srv = $dohServers[$idx]
        if (-not ($live | Where-Object { $_ -like "*$($srv.Url.ToLower())*" })) {
            throw "Adding DoH [$($srv.Label)] failed, aborting. Configuration NOT saved."
        }
    }
    Write-Host ("  DNS servers now: {0}" -f (($live -join '; ') -replace '\s+', ' '))
}

# --- lists ---
Write-Host 'Downloading lists from GitHub...'
$api = Invoke-RestMethod $ListsApi -Headers @{ 'User-Agent' = 'add-domain-lists' }
# PS 5.1 may return the JSON array wrapped in extra array levels, so flatten it fully
function Expand-Items($x) {
    foreach ($i in $x) {
        if ($i -is [System.Array]) { Expand-Items $i } else { $i }
    }
}
$listing = @(Expand-Items $api | Where-Object { $_.type -eq 'file' -and $_.name -like '*.txt' })
if (-not $listing) { throw "No .txt files found at $ListsApi" }

$ipv4Re = '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$'
$ipv6Re = '^[0-9a-f]*:[0-9a-f:\.]*(/\d{1,3})?$'
$domRe  = '^[a-z0-9]([a-z0-9\-\.]*[a-z0-9])?$'

foreach ($entry in $listing) {
    $baseName = [IO.Path]::GetFileNameWithoutExtension($entry.name)
    # telegram_ipv4.txt -> description "telegram"
    $desc = $baseName -replace '_ipv[46]$', ''
    $resp = Invoke-WebRequest ([string]$entry.download_url) -UseBasicParsing
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
    $items = @(($text -split '\r?\n') |
        ForEach-Object { ($_ -replace '#.*$', '').Trim().ToLower() } |
        Where-Object { $_ } |
        ForEach-Object { ($_ -split '\s+')[-1] } |
        ForEach-Object { $_ -replace '^\*\.', '' -replace '\.$', '' } |
        Where-Object { $_ -match $ipv4Re -or $_ -match $ipv6Re -or $_ -match $domRe } |
        Select-Object -Unique)

    if (-not $items) { Write-Host "[$desc] empty, skipped"; continue }

    if ($byDesc.ContainsKey($desc)) { $name = $byDesc[$desc]; $state = 'update' }
    else { $name = New-GroupName; $state = 'new'; $byDesc[$desc] = $name }

    Write-Host ("[{0}] {1} ({2}), entries: {3}" -f $baseName, $name, $state, $items.Count)

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
