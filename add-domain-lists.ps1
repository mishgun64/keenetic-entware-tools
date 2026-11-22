#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# shown at start so that a stale (cached) copy is easy to spot
$ScriptVersion = 'v6'
Write-Host ("add-domain-lists {0}" -f $ScriptVersion)

# lists are downloaded from this folder of the GitHub repo
$ListsApi = 'https://api.github.com/repos/mishgun64/keenetic-entware-tools/contents/domain-lists?ref=main'

# these lists are installed, but their route is created disabled (Keenetic: "route disable")
$disabledLists = @('google', 'microsoft', 'youtube')

# --- what to do ---
$reserveIfaceName = 'awg-reserve'

Write-Host ''
Write-Host 'What to do?'
Write-Host '  1) add/update lists and their routes (full install)'
Write-Host ("  2) switch existing list routes to the reserve interface ({0})" -f $reserveIfaceName)
$modeChoice = (Read-Host 'Number (Enter = 1)').Trim()
$mode = 'install'
if ($modeChoice -eq '2' -or $modeChoice -match '^(s|switch|reserve|резерв)') { $mode = 'switch' }

# --- input ---
$routers = @(
    @{ Label = '192.168.1.1';                     Ip = '192.168.1.1' },
    @{ Label = '192.168.47.1';                    Ip = '192.168.47.1' },
    @{ Label = '192.168.48.1';                    Ip = '192.168.48.1' },
    @{ Label = '192.168.49.1';                    Ip = '192.168.49.1' },
    @{ Label = '192.168.50.1';                    Ip = '192.168.50.1' },
    @{ Label = '192.168.51.1';                    Ip = '192.168.51.1' }
)
Write-Host 'Select Keenetic router:'
for ($i = 0; $i -lt $routers.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $routers[$i].Label) }
Write-Host ("  A) all routers (1-{0})" -f $routers.Count)
Write-Host '  0) enter IP manually'
$choice = (Read-Host 'Number').Trim()
if ($choice -match '^(a|all|все)$') { $targets = @($routers | ForEach-Object { $_.Ip }) }
elseif ($choice -match '^[1-9]\d*$' -and [int]$choice -le $routers.Count) { $targets = @($routers[[int]$choice - 1].Ip) }
elseif ($choice -match '^\d{1,3}(\.\d{1,3}){3}$') { $targets = @($choice) }
else {
    $manual = (Read-Host 'Keenetic router IP (e.g. 192.168.1.1)').Trim()
    if (-not $manual) { throw 'No router IP given.' }
    $targets = @($manual)
}
Write-Host ("Router(s): {0}" -f ($targets -join ', '))
$login = Read-Host 'Login (Enter = admin)'
if (-not $login) { $login = 'admin' }
$sec = Read-Host 'Password' -AsSecureString
$pass = [System.Net.NetworkCredential]::new('', $sec).Password

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Get-Utf8Json([string]$path) {
    $resp = Invoke-WebRequest "$base$path" -WebSession $sess -UseBasicParsing
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
    return ($text | ConvertFrom-Json)
}

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
function Connect-Session([string]$base, $sess, [string]$login, [string]$pass, [string]$ip) {
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
}

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

# --- routes in dns-proxy ---
# A disabled route is written as its own line plus a following "route disable" line,
# and "route disable" always applies to the last route of the block. The state is
# therefore read back from running-config instead of trusting RCI statuses.
function Get-GroupRoutes {
    $cfg = Invoke-RestMethod "$base/rci/show/running-config" -WebSession $sess
    $routes = New-Object System.Collections.ArrayList
    $in = $false
    $last = $null
    foreach ($line in $cfg.message) {
        if ($line -match '^\S') { $in = ($line -match '^dns-proxy\s*$'); $last = $null; continue }
        if (-not $in) { continue }
        $t = $line.Trim()
        if ($t -match '^route\s+object-group\s+(\S+)') {
            $last = [pscustomobject]@{ Group = $Matches[1]; Cmd = $t; Disabled = $false }
            [void]$routes.Add($last)
        }
        elseif ($t -eq 'route disable' -and $last) { $last.Disabled = $true; $last = $null }
        else { $last = $null }
    }
    return $routes
}

# Error messages of an RCI batch (empty when every command was accepted).
function Get-RciErrors($res) {
    $msgs = @()
    foreach ($r in @($res)) {
        foreach ($s in @($r.parse.status)) {
            if ($s.status -eq 'error') { $msgs += [string]$s.message }
        }
    }
    return @($msgs)
}

# Removes every route of one group. The accepted spelling differs between KeeneticOS
# builds, so several forms are tried and success is judged by re-reading the config.
function Remove-GroupRoutes([string]$Group) {
    $cur = @(Get-GroupRoutes | Where-Object { $_.Group -eq $Group })
    if ($cur.Count -eq 0) { return $true }

    $forms = @()
    foreach ($r in $cur) {
        $forms += "no $($r.Cmd)"
        $iface = $null
        if ($r.Cmd -match '^route\s+object-group\s+\S+\s+(\S+)') { $iface = $Matches[1] }
        if ($iface) {
            $forms += "no route object-group $Group $iface"
            $forms += "no route object-group $Group $iface auto"
        }
    }
    $forms += "no route object-group $Group"
    $forms = @($forms | Select-Object -Unique)

    $variants = @()
    foreach ($f in $forms) {
        $variants += ,@('dns-proxy', $f, 'exit')
        $variants += ,@("dns-proxy $f")
        $variants += ,@($f)
    }

    $msgs = @()
    foreach ($v in $variants) {
        $msgs += @(Get-RciErrors (Invoke-Rci $v))
        if (@(Get-GroupRoutes | Where-Object { $_.Group -eq $Group }).Count -eq 0) { return $true }
    }
    $msgs = @($msgs | Where-Object { $_ } | Select-Object -Unique)
    if ($msgs.Count -gt 0) {
        Write-Warning ("route {0}: router said: {1}" -f $Group, (($msgs | Select-Object -First 3) -join '; '))
    }
    return $false
}

# Makes the route of one group point to <Interface> and match the requested state.
# A matching route is left untouched. A differing route is removed and re-added at
# the end of the block, because only the last route can be addressed by "route disable".
function Set-GroupRoute([string]$Group, [string]$Interface, [bool]$Disable) {
    $want = "route object-group $Group $Interface auto"
    $cur = @(Get-GroupRoutes | Where-Object { $_.Group -eq $Group })
    if ($cur.Count -eq 1 -and $cur[0].Cmd -eq $want -and [bool]$cur[0].Disabled -eq $Disable) { return 0 }

    $errors = 0
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not (Remove-GroupRoutes $Group)) {
            Write-Warning ("route {0}: could not remove the old route" -f $Group)
            return ($errors + 1)
        }
        $cmds = @('dns-proxy', $want)
        if ($Disable) { $cmds += 'route disable' }
        $cmds += 'exit'
        $errors += Send-Rci $cmds

        $now = @(Get-GroupRoutes | Where-Object { $_.Group -eq $Group })
        if ($now.Count -eq 1 -and $now[0].Cmd -eq $want -and [bool]$now[0].Disabled -eq $Disable) { return $errors }
        if ($attempt -lt 2) {
            Write-Warning ("route {0}: {1} entr(ies) after update (disabled={2}), retrying" -f `
                $Group, $now.Count, (($now | ForEach-Object { $_.Disabled }) -join ','))
        }
    }
    Write-Warning ("route {0}: could not set state (disabled={1})" -f $Group, $Disable)
    return ($errors + 1)
}

# Rebuilds dns-proxy without the routes of the given groups. Fallback for builds where
# the CLI refuses to remove a dns-proxy route: the rest of the block (upstreams,
# rebind-protect, filter, other routes) is kept.
function Rebuild-DnsProxy([string[]]$DropGroups) {
    $cfg = Invoke-RestMethod "$base/rci/show/running-config" -WebSession $sess
    $keep = @()
    $in = $false
    $dropNext = $false
    foreach ($line in $cfg.message) {
        if ($line -match '^\S') { $in = ($line -match '^dns-proxy\s*$'); $dropNext = $false; continue }
        if (-not $in) { continue }
        $t = $line.Trim()
        if ($t -eq '!') { continue }
        if ($t -match '^route\s+object-group\s+(\S+)') {
            $g = $Matches[1]
            if ($DropGroups -contains $g) { $dropNext = $true; continue }
        }
        if ($dropNext -and $t -eq 'route disable') { $dropNext = $false; continue }
        $dropNext = $false
        $keep += $t
    }
    $null = Invoke-Rci @('no dns-proxy')
    if ($keep.Count -gt 0) { $null = Invoke-Rci (@('dns-proxy') + $keep + @('exit')) }
}

# Reads object-group fqdn blocks (description + includes) so that a group can be
# re-created without downloading the lists again.
function Get-GroupBlocks {
    $cfg = Invoke-RestMethod "$base/rci/show/running-config" -WebSession $sess
    $list = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($line in $cfg.message) {
        if ($line -match '^\S') {
            $cur = $null
            if ($line -match '^object-group\s+fqdn\s+(\S+)') {
                $cur = [pscustomobject]@{ Name = $Matches[1]; Description = $null; Includes = @(); Other = @() }
                [void]$list.Add($cur)
            }
            continue
        }
        if (-not $cur) { continue }
        $t = $line.Trim()
        if ($t -eq '!') { $cur = $null; continue }
        if ($t -match '^description\s+(.+)$') { $cur.Description = $Matches[1] }
        elseif ($t -match '^include\s+(\S+)$') { $cur.Includes += $Matches[1] }
        else { $cur.Other += $t }
    }
    return $list
}

# Re-creates groups from blocks read by Get-GroupBlocks. Returns the number of failed
# commands. Includes are sent in chunks (same limit as the install path).
function Restore-GroupBlocks($Blocks) {
    $errors = 0
    foreach ($g in @($Blocks)) {
        $includes = @($g.Includes)
        if ($includes.Count -eq 0) {
            $cmds = @("object-group fqdn $($g.Name)")
            if ($g.Description) { $cmds += "description $($g.Description)" }
            $cmds += 'exit'
            $errors += Send-Rci $cmds
            continue
        }
        for ($i = 0; $i -lt $includes.Count; $i += 80) {
            $slice = $includes[$i..([Math]::Min($i + 79, $includes.Count - 1))]
            $cmds = @("object-group fqdn $($g.Name)")
            if ($i -eq 0 -and $g.Description) { $cmds += "description $($g.Description)" }
            $cmds += @($slice | ForEach-Object { "include $_" })
            $cmds += 'exit'
            $errors += Send-Rci $cmds
        }
    }
    return $errors
}

function Get-DomainListGroups {
    $cfg = Invoke-RestMethod "$base/rci/show/running-config" -WebSession $sess
    $names = @()
    foreach ($line in $cfg.message) {
        if ($line -match '^\s*object-group\s+fqdn\s+(\S+)') {
            $n = $Matches[1]
            if ($n -match '^domain-list\d+$') { $names += $n }
        }
    }
    return @($names | Sort-Object -Unique)
}

function Install-ToRouter {
param([string]$ip, [string]$login, [string]$pass)

$base = "http://$ip"
$sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Connect-Session -base $base -sess $sess -login $login -pass $pass -ip $ip


# PS 5.1 decodes JSON as Latin-1 when the response has no charset, so UTF-8 is decoded manually







# --- interface selection ---
$ifaceChoices = @()
$ifaceDescr = @{}
$ifaceText = @{}
try {
    $ifaceInfo = Get-Utf8Json '/rci/show/interface'
    foreach ($p in $ifaceInfo.PSObject.Properties) {
        # skip nested subtrees (name/subname) and pure numbers (ports are not VPN interfaces)
        if (-not $p.Name -or $p.Name -like '*/*' -or $p.Name -match '^\d+$') { continue }
        $ifaceChoices += $p.Name
        $text = $p.Name
        if ($p.Value) {
            if ($p.Value.description) {
                $ifaceDescr[$p.Name] = [string]$p.Value.description
                $text += ' ' + $p.Value.description
            }
            # "awg" may sit in any field (description, comment, ...), so scan the whole object
            try { $text += ' ' + ($p.Value | ConvertTo-Json -Depth 3 -Compress) } catch { }
        }
        $ifaceText[$p.Name] = $text
    }
    $ifaceChoices = @($ifaceChoices | Sort-Object -Unique)
} catch {
    Write-Warning "Could not read the interface list: $($_.Exception.Message)"
}

# an interface with "awg" anywhere in its name/fields (AmneziaWG, e.g. Wireguard2 "public-awg")
# is used as the default
$defaultIface = @($ifaceChoices | Where-Object { $ifaceText[$_] -match 'awg' }) | Select-Object -First 1
$defaultLabel = ''
if ($defaultIface) {
    $defaultLabel = $defaultIface
    if ($ifaceDescr.ContainsKey($defaultIface)) { $defaultLabel += " ($($ifaceDescr[$defaultIface]))" }
}

if ($ifaceChoices.Count -gt 0) {
    Write-Host ''
    Write-Host 'Interfaces:'
    foreach ($n in $ifaceChoices) {
        $d = ''
        if ($ifaceDescr.ContainsKey($n)) { $d = "  ($($ifaceDescr[$n]))" }
        $m = ''
        if ($n -eq $defaultIface) { $m = '  <- default' }
        Write-Host ("  {0}{1}{2}" -f $n, $d, $m)
    }
}

if ($defaultIface) {
    Write-Host ''
    Write-Host "Default interface (name or description contains 'awg'): $defaultLabel"
    $iface = (Read-Host "VPN interface to route all lists through, e.g. $defaultLabel (Enter = $defaultLabel)").Trim()
    if (-not $iface) { $iface = $defaultIface }
}
else {
    $iface = (Read-Host 'VPN interface to route all lists through, e.g. Wireguard2 (Enter = do not assign routes)').Trim()
}
if ($iface) {
    if ($ifaceDescr.ContainsKey($iface)) { Write-Host "Interface for DNS routes: $iface ($($ifaceDescr[$iface]))" }
    else { Write-Host "Interface for DNS routes: $iface" }
}

# Sends commands in one request (context is kept between them). Returns number of failed commands.





# Removes every group created by this script (domain-listN) together with its route,
# so the install always starts from scratch: domains removed from a file disappear,
# and no stale groups/routes stay behind. Other object-groups are not touched.
function Reset-DomainLists {
    $groups = @(Get-DomainListGroups)
    # route lines of domain-list groups, even when the group itself is already gone
    $stale = @(Get-GroupRoutes | Where-Object { $_.Group -match '^domain-list\d+$' })
    if ($groups.Count -eq 0 -and $stale.Count -eq 0) {
        Write-Host 'No old domain-list groups on the router.'
        return
    }

    # 1) delete the groups; routes left behind are cleaned up below
    if ($groups.Count -gt 0) {
        Write-Host ("Removing {0} old group(s): {1}" -f $groups.Count, ($groups -join ', '))
        $null = Invoke-Rci @($groups | ForEach-Object { "no object-group fqdn $_" })

        # 2) groups still in use by a route: remove those routes, then retry
        $left = @(Get-DomainListGroups)
        if ($left.Count -gt 0) {
            Write-Host ("  {0} group(s) still in use, removing their routes..." -f $left.Count)
            $failed = $false
            foreach ($n in $left) {
                if (-not (Remove-GroupRoutes $n)) { $failed = $true; break }
            }
            if (-not $failed) {
                $null = Invoke-Rci @($left | ForEach-Object { "no object-group fqdn $_" })
            }
        }
    }

    # 3) routes the CLI refused to delete (or that outlived their group):
    #    rebuild dns-proxy without them
    $stale = @(Get-GroupRoutes | Where-Object { $_.Group -match '^domain-list\d+$' })
    if ($stale.Count -gt 0) {
        Write-Host ("  {0} stale route(s) left, rebuilding dns-proxy" -f $stale.Count)
        Rebuild-DnsProxy @($stale | ForEach-Object { $_.Group })
        $stale = @(Get-GroupRoutes | Where-Object { $_.Group -match '^domain-list\d+$' })
        if ($stale.Count -gt 0) {
            throw ("Could not remove route(s) of: {0}, aborting. Configuration NOT saved." -f `
                (($stale | ForEach-Object { $_.Group } | Sort-Object -Unique) -join ', '))
        }
    }

    # 4) retry the groups (the routes are gone now)
    $left = @(Get-DomainListGroups)
    if ($left.Count -gt 0) {
        Write-Host ("  retrying {0} group(s)" -f $left.Count)
        $null = Invoke-Rci @($left | ForEach-Object { "no object-group fqdn $_" })
        $left = @(Get-DomainListGroups)
    }
    if ($left.Count -gt 0) {
        throw ("Could not remove group(s): {0}, aborting. Configuration NOT saved." -f ($left -join ', '))
    }
    Write-Host '  ok'
}

# --- existing object-group fqdn: description -> name ---
Reset-DomainLists

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

# reads an interface block again and returns its lines (trimmed)
function Get-IfaceLines([string]$name) {
    $cfg = Invoke-RestMethod "$base/rci/show/running-config" -WebSession $sess
    $lines = @()
    $in = $false
    foreach ($line in $cfg.message) {
        if ($line -match '^\S') {
            $in = ($line -match ('^interface\s+' + [regex]::Escape($name) + '\s*$'))
            continue
        }
        if ($in) { $lines += $line.Trim() }
    }
    return $lines
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

# --- provider DNS ("ip no name-servers" on WAN interfaces) ---
# Targets: the interface created by "rename ISP" (falling back to its factory name)
# and the PPPoE interface. Non-existent interfaces are skipped with a warning.
$ifaceNames = @()
foreach ($line in $rc.message) {
    if ($line -match '^interface\s+(\S+)') { $ifaceNames += $Matches[1] }
}

$ispIface = $null
if ($ifaceNames -contains 'ISP') { $ispIface = 'ISP' }
else {
    $cur = $null
    foreach ($line in $rc.message) {
        if ($line -match '^interface\s+(\S+)') { $cur = $Matches[1]; continue }
        if ($cur -and $line -match '^\s+rename\s+ISP\s*$') { $ispIface = $cur; break }
        if ($line -match '^\S') { $cur = $null }
    }
}

$pppoeIface = $null
foreach ($n in $ifaceNames) {
    if ($n -match '^PPPoE\d*$') { $pppoeIface = $n; break }
}

$dnsTargets = @()
if ($ispIface)   { $dnsTargets += $ispIface }
if ($pppoeIface -and $dnsTargets -notcontains $pppoeIface) { $dnsTargets += $pppoeIface }

Write-Host ''
if (-not $ispIface) {
    Write-Warning 'Interface ISP (rename ISP) not found, skipping provider DNS disable on it.'
}
if (-not $pppoeIface) {
    Write-Warning 'Interface PPPoE0 not found, skipping provider DNS disable on it.'
}

if ($dnsTargets.Count -eq 0) {
    Write-Warning 'No WAN interface found, provider DNS left as is.'
}
elseif (@(Get-LiveUpstreams).Count -eq 0) {
    # without a working upstream disabling the provider DNS would leave the router
    # without a resolver, so this step is only done together with DoH
    Write-Warning ("No DoH upstream configured, keeping provider DNS on {0}." -f ($dnsTargets -join ', '))
}
else {
    foreach ($ifaceName in $dnsTargets) {
        $ifaceLines = @(Get-IfaceLines $ifaceName)
        if ($ifaceLines -contains 'ip no name-servers') {
            Write-Host ("Provider DNS already disabled on {0}." -f $ifaceName)
            continue
        }
        Write-Host ("Disabling provider DNS on {0} (ip no name-servers)..." -f $ifaceName)
        $null = Invoke-Rci @("interface $ifaceName", 'ip no name-servers', 'exit')
        if (-not (@(Get-IfaceLines $ifaceName) -contains 'ip no name-servers')) {
            throw ("Could not disable provider DNS on '{0}', aborting. Configuration NOT saved." -f $ifaceName)
        }
        Write-Host '  ok'
    }
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
    if ($iface) {
        $disableRoute = ($disabledLists -contains $desc)
        if ($disableRoute) { Write-Host "  route: disabled" }
        $errors += Set-GroupRoute -Group $name -Interface $iface -Disable $disableRoute
    }

    if ($errors -gt 0) { throw "[$desc] failed, aborting. Configuration NOT saved." }
}

[void](Send-Rci @('system configuration save'))
Write-Host 'Done, configuration saved.'
}

# Switches the routes of all installed lists (domain-listN) to another interface,
# keeping their enabled/disabled state. The dns-proxy block is rebuilt line by line:
# this also works on builds that refuse "no route object-group ...", and it keeps
# DoH upstreams, rebind-protect, filter and routes of other groups.
function Switch-ToReserve {
param([string]$ip, [string]$login, [string]$pass, [string]$preferred)

$base = "http://$ip"
$sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Connect-Session -base $base -sess $sess -login $login -pass $pass -ip $ip

# --- interfaces ---
$ifaces = @{}
try {
    $info = Get-Utf8Json '/rci/show/interface'
    foreach ($p in $info.PSObject.Properties) {
        if (-not $p.Name -or $p.Name -like '*/*' -or $p.Name -match '^\d+$') { continue }
        $d = ''
        if ($p.Value -and $p.Value.description) { $d = [string]$p.Value.description }
        $ifaces[$p.Name] = $d
    }
} catch { Write-Warning "Could not read the interface list: $($_.Exception.Message)" }

# default target: name or description contains "awg-reserve"
$reserve = $null
if ($preferred) {
    foreach ($n in $ifaces.Keys) {
        if ($n -eq $preferred -or "$n $($ifaces[$n])" -match [regex]::Escape($preferred)) { $reserve = $n; break }
    }
}

if ($ifaces.Count -gt 0) {
    Write-Host ''
    Write-Host 'Interfaces:'
    foreach ($n in (@($ifaces.Keys) | Sort-Object)) {
        $d = ''
        if ($ifaces[$n]) { $d = "  ($($ifaces[$n]))" }
        $m = ''
        if ($n -eq $reserve) { $m = '  <- reserve' }
        Write-Host ("  {0}{1}{2}" -f $n, $d, $m)
    }
}

$routes = @(Get-GroupRoutes | Where-Object { $_.Group -match '^domain-list\d+$' })
if ($routes.Count -eq 0) {
    Write-Warning 'No list routes on the router (domain-listN), nothing to switch.'
    return
}

if ($reserve) {
    Write-Host ''
    Write-Host ("Reserve interface: {0}" -f $reserve)
    $answer = (Read-Host "Interface to switch list routes to (Enter = $reserve)").Trim()
    $target = $answer
    if (-not $target) { $target = $reserve }
}
else {
    Write-Warning ("No interface with '{0}' in its name or description found." -f $preferred)
    $target = (Read-Host 'Interface to switch list routes to (Enter = cancel)').Trim()
}
if (-not $target) { Write-Host 'Cancelled.'; return }
if ($ifaces.Count -gt 0 -and -not $ifaces.ContainsKey($target)) {
    Write-Warning ("Interface {0} is not in the router interface list, trying anyway" -f $target)
}

# --- plan: which groups change, and their enabled/disabled state ---
$state = @{}
foreach ($r in $routes) {
    if ($state.ContainsKey($r.Group)) { $state[$r.Group] = ([bool]$state[$r.Group] -or [bool]$r.Disabled) }
    else { $state[$r.Group] = [bool]$r.Disabled }
}

$changes = @()
foreach ($g in @($state.Keys | Sort-Object)) {
    $ifcs = @($routes | Where-Object { $_.Group -eq $g } | ForEach-Object {
        if ($_.Cmd -match '^route\s+object-group\s+\S+\s+(\S+)') { $Matches[1] }
    } | Sort-Object -Unique)
    $dup = (@($routes | Where-Object { $_.Group -eq $g }).Count -gt 1)
    if (@($ifcs | Where-Object { $_ -ne $target }).Count -eq 0 -and -not $dup) { continue }
    $changes += $g
    $note = ''
    if ($state[$g]) { $note += '  (disabled)' }
    if ($dup) { $note += '  (duplicate routes)' }
    Write-Host ("  {0}: {1} -> {2}{3}" -f $g, (($ifcs) -join ','), $target, $note)
}

if ($changes.Count -eq 0) {
    Write-Host ("All list routes already use {0}, nothing to change." -f $target)
    Write-Host 'Configuration NOT saved (no changes).'
    return
}

Write-Host ("Switching {0} route(s) to {1}..." -f $changes.Count, $target)

# Some builds accept "no route object-group ..." and the routes can be moved one by
# one. That is probed on a single group first; if it is refused, the groups are
# deleted and re-created (deleting an object-group also removes its routes), which
# only relies on commands every build supports.
$probe = $changes[0]
$null = Set-GroupRoute -Group $probe -Interface $target -Disable ([bool]$state[$probe]) 3>$null
$probeNow = @(Get-GroupRoutes | Where-Object { $_.Group -eq $probe })
$fastPath = ($probeNow.Count -eq 1 -and $probeNow[0].Cmd -eq "route object-group $probe $target auto")

if ($fastPath) {
    Write-Host '  per-route update is supported, moving routes one by one'
    foreach ($g in ($changes | Where-Object { $_ -ne $probe })) {
        $e = Set-GroupRoute -Group $g -Interface $target -Disable ([bool]$state[$g]) 3>$null
        if ($e -ne 0) { throw ("Could not switch route {0} to {1}, aborting. Configuration NOT saved." -f $g, $target) }
    }
}
else {
    Write-Host '  per-route update is refused by this firmware, re-creating groups'

    $blocks = @(Get-GroupBlocks | Where-Object { $changes -contains $_.Name })
    $weird = @($blocks | Where-Object { $_.Other.Count -gt 0 })
    if ($weird.Count -gt 0) {
        throw ("Group(s) {0} contain unsupported lines, refusing to re-create them. Configuration NOT saved." -f `
            (($weird | ForEach-Object { $_.Name }) -join ', '))
    }
    if ($blocks.Count -ne $changes.Count) {
        Write-Warning ("{0} group(s) have a route but no object-group on the router" -f ($changes.Count - $blocks.Count))
    }

    # 1) delete the groups (their routes disappear with them)
    Write-Host ("  deleting {0} group(s)" -f $blocks.Count)
    $errors = Send-Rci @($blocks | ForEach-Object { "no object-group fqdn $($_.Name)" })
    $left = @(Get-DomainListGroups)
    $leftChanged = @($blocks | Where-Object { $left -contains $_.Name })
    if ($leftChanged.Count -gt 0) {
        throw ("Could not delete group(s): {0}, aborting. Configuration NOT saved." -f `
            (($leftChanged | ForEach-Object { $_.Name }) -join ', '))
    }

    # 1b) routes the deleted groups left behind must go too, otherwise the new
    #     routes would be added next to them
    $stale = @(Get-GroupRoutes | Where-Object { $changes -contains $_.Group })
    if ($stale.Count -gt 0) {
        Write-Host ("  removing {0} leftover route(s)" -f $stale.Count)
        foreach ($g in @($stale | ForEach-Object { $_.Group } | Sort-Object -Unique)) {
            $null = Remove-GroupRoutes $g 3>$null
        }
        $stale = @(Get-GroupRoutes | Where-Object { $changes -contains $_.Group })
        if ($stale.Count -gt 0) {
            Write-Host '  routes cannot be removed, restoring the deleted groups'
            $null = Restore-GroupBlocks $blocks
            throw ("Could not remove leftover route(s) of: {0}. Groups restored, configuration NOT saved." -f `
                (($stale | ForEach-Object { $_.Group } | Sort-Object -Unique) -join ', '))
        }
    }

    # 2) re-create the groups with the same description and includes
    Write-Host ("  re-creating {0} group(s)" -f $blocks.Count)
    $errors += Restore-GroupBlocks $blocks

    # 3) add the routes on the target interface, keeping "route disable"
    $cmds = @('dns-proxy')
    foreach ($g in $changes) {
        $cmds += "route object-group $g $target auto"
        if ($state[$g]) { $cmds += 'route disable' }
    }
    $cmds += 'exit'
    $errors += Send-Rci $cmds
    if ($errors -gt 0) { throw "Switching routes failed, aborting. Configuration NOT saved." }

    # 4) the groups must be back with the same number of entries
    $nowBlocks = @(Get-GroupBlocks)
    $lost = @()
    foreach ($g in $blocks) {
        $have = @($nowBlocks | Where-Object { $_.Name -eq $g.Name })
        if ($have.Count -ne 1 -or @($have[0].Includes).Count -ne @($g.Includes).Count) { $lost += $g.Name }
    }
    if ($lost.Count -gt 0) {
        throw ("Group(s) not restored: {0}, aborting. Configuration NOT saved." -f ($lost -join ', '))
    }
}

# --- verify: every list route on the target, one route per group, state kept ---
$now = @(Get-GroupRoutes | Where-Object { $_.Group -match '^domain-list\d+$' })
$bad = @($now | Where-Object { $_.Cmd -notmatch ('^route\s+object-group\s+' + [regex]::Escape($_.Group) + '\s+' + [regex]::Escape($target) + '(\s|$)') })
$dup = @($now | Group-Object Group | Where-Object { $_.Count -ne 1 })
$disBad = @($now | Where-Object { $changes -contains $_.Group -and [bool]$_.Disabled -ne [bool]$state[$_.Group] })
if ($bad.Count -gt 0 -or $dup.Count -gt 0 -or $disBad.Count -gt 0) {
    throw ("Switching to {0} failed: {1} off target, {2} duplicated, {3} with wrong state. Configuration NOT saved." -f `
        $target, $bad.Count, $dup.Count, $disBad.Count)
}
[void](Send-Rci @('system configuration save'))
Write-Host ("Done, {0} route(s) switched to {1}, configuration saved." -f $now.Count, $target)
}

# --- run ---
$failed = @()
foreach ($ip in $targets) {
    Write-Host ''
    Write-Host ("=== {0} ===" -f $ip)
    try {
        if ($mode -eq 'switch') { Switch-ToReserve -ip $ip -login $login -pass $pass -preferred $reserveIfaceName }
        else { Install-ToRouter -ip $ip -login $login -pass $pass }
    }
    catch {
        Write-Warning ("[{0}] {1}" -f $ip, $_.Exception.Message)
        $failed += $ip
    }
}
if ($failed.Count -gt 0) { throw ("Failed on: {0}" -f ($failed -join ', ')) }
if ($mode -eq 'switch') { Write-Host ("All done, list routes switched on: {0}" -f ($targets -join ', ')) }
else { Write-Host ("All done, configuration saved on: {0}" -f ($targets -join ', ')) }
