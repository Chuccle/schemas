<#
.SYNOPSIS
    Checks a live server-rs against the behaviours in contract.json, over the
    wire, exactly as the BlorgFS driver talks to it.

.DESCRIPTION
    The structural contract (routes, status codes, FlatBuffer layout) is
    checked at build time on both sides. This script checks the behavioural
    one: what a running server actually does with the requests the driver
    actually sends -- framing, keep-alive, ranges across the resident/streamed
    boundary, error codes, Windows-style paths, and whether metadata and
    content stay consistent when a file changes underneath.

    It speaks raw HTTP/1.1 over a TcpClient (no HttpClient, which would hide
    chunking and connection reuse) and needs nothing but PowerShell, so the
    same script runs in server-rs CI on Linux (pwsh 7) and inside the Windows
    test guest (Windows PowerShell 5.1 or pwsh 7) against a deployed server.

    It works against a probe tree, -ProbeDir (contract-probe\ by default),
    under the server's served root. With -SeedRoot (the served directory,
    reachable from where this runs) it creates the tree itself and also runs
    the change tests (B08); without it, the tree has to be served already:
    seed it with -SeedOnly on a machine that can reach the served directory,
    or serve a committed copy of what -SeedOnly writes.

    Each check prints PASS, FAIL or INFO with its behaviour ID. Exit code is
    the number of failed checks, so 0 means conformant. Behaviours marked
    "gap" in contract.json are reported as INFO and never fail the run.

.PARAMETER Server
    host:port of the server under test.

.PARAMETER SeedRoot
    The server's served directory. Enables seeding and the change tests.

.PARAMETER ProbeDir
    Name of the probe tree's directory directly under the served root.

.PARAMETER SeedOnly
    Create the probe tree under -SeedRoot and exit.

.PARAMETER ResultPath
    Optional path to write results as JSON, for a harness to collect.

.EXAMPLE
    ./Test-BlorgContract.ps1 -Server 127.0.0.1:8080 -SeedRoot /srv/blorg

.EXAMPLE
    # In the guest, against a server on the host network
    .\Test-BlorgContract.ps1 -Server 10.0.50.17:8080 -ResultPath C:\results\contract.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [string]$SeedRoot,
    [string]$ProbeDir = "contract-probe",
    [switch]$SeedOnly,
    [string]$ResultPath,
    [int]$TimeoutMs = 10000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$SmallSize = 1000
# Above server-rs's default max_resident_file_bytes (8 MiB), so it is streamed
# from disk rather than served from memory -- the two code paths B01 covers.
$LargeSize = 9 * 1024 * 1024
$ShrinkFrom = 4096
$ShrinkTo = 100
# Watcher debounce is 2 s; allow generous slack for a loaded guest.
$ChangeDeadlineSeconds = 8

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Failures = 0

function Report([string]$Behaviour, [string]$Outcome, [string]$Check, [string]$Detail = "") {
    $line = "{0,-4} {1} {2}" -f $Outcome, $Behaviour, $Check
    if ($Detail) { $line += " -- $Detail" }
    Write-Host $line
    if ($Outcome -eq "FAIL") { $script:Failures++ }
    $script:Results.Add([pscustomobject]@{ behaviour = $Behaviour; outcome = $Outcome; check = $Check; detail = $Detail })
}

function Check([string]$Behaviour, [string]$Check, [bool]$Condition, [string]$Detail = "") {
    if ($Condition) { Report $Behaviour "PASS" $Check } else { Report $Behaviour "FAIL" $Check $Detail }
}

# --------------------------------------------------------------------------
# Probe tree
# --------------------------------------------------------------------------

function Get-PatternBytes([int]$Length, [int]$Modulus) {
    $block = New-Object byte[] $Modulus
    for ($i = 0; $i -lt $Modulus; $i++) { $block[$i] = [byte]$i }
    $stream = New-Object System.IO.MemoryStream $Length
    $left = $Length
    while ($left -gt 0) {
        $n = [Math]::Min($left, $Modulus)
        $stream.Write($block, 0, $n)
        $left -= $n
    }
    return $stream.ToArray()
}

function Initialize-ProbeTree([string]$Root) {
    $dir = Join-Path $Root $ProbeDir
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "sub") | Out-Null
    # So a committed copy of the tree keeps sub\ (git drops empty directories).
    [System.IO.File]::WriteAllBytes((Join-Path $dir "sub\.gitkeep"), (New-Object byte[] 0))
    [System.IO.File]::WriteAllBytes((Join-Path $dir "small.bin"), (Get-PatternBytes $SmallSize 251))
    [System.IO.File]::WriteAllBytes((Join-Path $dir "large.bin"), (Get-PatternBytes $LargeSize 251))
    [System.IO.File]::WriteAllBytes((Join-Path $dir "shrink.bin"), (Get-PatternBytes $ShrinkFrom 251))
    [System.IO.File]::WriteAllText((Join-Path $dir ([string][char]0x00e9 + "t" + [char]0x00e9 + ".txt")), "hello")
    [System.IO.File]::WriteAllText((Join-Path $dir "MixedCase.txt"), "case")
}

# --------------------------------------------------------------------------
# Wire
# --------------------------------------------------------------------------

$SafeBytes = [System.Text.Encoding]::ASCII.GetBytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

# Byte-for-byte the driver's UrlEncodePathToAnsi: UTF-8, upper-case hex.
function ConvertTo-DriverEncoding([string]$Path) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Path)) {
        if ($SafeBytes -contains $b) { [void]$sb.Append([char]$b) } else { [void]$sb.AppendFormat("%{0:X2}", $b) }
    }
    return $sb.ToString()
}

# The request the driver sends (see contract.json "requests"), or a raw query.
function New-Request([string]$Route, [string]$Path, [object]$Range, [object]$RawQuery) {
    $query = if ($null -ne $RawQuery) { $RawQuery } else { "?path=" + (ConvertTo-DriverEncoding $Path) }
    $text = "GET $Route$query HTTP/1.1`r`nHost: $($Server.Split(':')[0])`r`nConnection: keep-alive`r`n"
    if ($Range) { $text += "Range: bytes=$($Range[0])-$($Range[1])`r`n" }
    return [System.Text.Encoding]::ASCII.GetBytes($text + "`r`n")
}

function New-Connection {
    $hostName, $port = $Server.Split(':')
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.ReceiveTimeout = $TimeoutMs
    $client.SendTimeout = $TimeoutMs
    $client.Connect($hostName, [int]$port)
    return $client
}

# Reads exactly one Content-Length framed response. Returns status, headers
# (name -> list of values, lower-cased names) and body. Never reads past the
# declared body, so the connection is reusable afterwards.
function Read-Response([System.Net.Sockets.NetworkStream]$Stream) {
    $head = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($true) {
        $n = $Stream.Read($one, 0, 1)
        if ($n -eq 0) { throw "connection closed before end of headers" }
        $head.Add($one[0])
        $c = $head.Count
        if ($c -ge 4 -and $head[$c - 4] -eq 13 -and $head[$c - 3] -eq 10 -and $head[$c - 2] -eq 13 -and $head[$c - 1] -eq 10) { break }
        if ($c -gt 65536) { throw "headers exceed 64 KB" }
    }
    $lines = ([System.Text.Encoding]::ASCII.GetString($head.ToArray()) -split "`r`n") | Where-Object { $_ -ne "" }
    $statusLine = @($lines)[0]
    if ($statusLine -notmatch '^HTTP/1\.1 (\d{3})') { throw "bad status line '$statusLine'" }
    $headers = @{}
    foreach ($line in @($lines) | Select-Object -Skip 1) {
        $i = $line.IndexOf(':')
        $name = $line.Substring(0, $i).Trim().ToLowerInvariant()
        if (-not $headers.ContainsKey($name)) { $headers[$name] = New-Object System.Collections.Generic.List[string] }
        $headers[$name].Add($line.Substring($i + 1).Trim())
    }
    $body = New-Object byte[] 0
    if ($headers.ContainsKey("content-length")) {
        $length = [int64]$headers["content-length"][0]
        $body = New-Object byte[] $length
        $got = 0
        while ($got -lt $length) {
            $n = $Stream.Read($body, $got, [int][Math]::Min($length - $got, 1048576))
            if ($n -eq 0) { throw "connection closed after $got of $length body bytes" }
            $got += $n
        }
    }
    return [pscustomobject]@{ Status = [int]$Matches[1]; Headers = $headers; Body = $body }
}

# $RawQuery is untyped on purpose: a [string] parameter turns $null into "",
# which would silently send every request without its path.
function Invoke-Driver([string]$Route, [string]$Path, [object]$Range = $null, [object]$RawQuery = $null, $Client = $null) {
    $own = $null -eq $Client
    if ($own) { $Client = New-Connection }
    try {
        $stream = $Client.GetStream()
        $bytes = New-Request $Route $Path $Range $RawQuery
        $stream.Write($bytes, 0, $bytes.Length)
        return Read-Response $stream
    } finally {
        if ($own) { $Client.Dispose() }
    }
}

function Test-Framing([string]$Behaviour, [string]$What, $Response) {
    $cl = if ($Response.Headers.ContainsKey("content-length")) { $Response.Headers["content-length"].Count } else { 0 }
    $te = $Response.Headers.ContainsKey("transfer-encoding")
    Check $Behaviour "$What is Content-Length framed" ($cl -eq 1 -and -not $te) "content-length headers: $cl, transfer-encoding: $te"
}

# --------------------------------------------------------------------------
# Minimal FlatBuffer scalar reader (enough for DirectoryEntryMetadata)
# --------------------------------------------------------------------------

function Get-FlatScalar([byte[]]$Buffer, [int]$Field, [int]$Width) {
    $table = [BitConverter]::ToUInt32($Buffer, 0)
    $vtable = $table - [BitConverter]::ToInt32($Buffer, $table)
    $vtableSize = [BitConverter]::ToUInt16($Buffer, $vtable)
    $slot = 4 + 2 * $Field
    if ($slot -ge $vtableSize) { return 0 }
    $offset = [BitConverter]::ToUInt16($Buffer, $vtable + $slot)
    if ($offset -eq 0) { return 0 }
    if ($Width -eq 8) { return [BitConverter]::ToUInt64($Buffer, $table + $offset) }
    return $Buffer[$table + $offset]
}

function Get-EntrySize([string]$Path) {
    $r = Invoke-Driver "/get_dir_entry_info" $Path
    if ($r.Status -ne 200) { return $null }
    return Get-FlatScalar $r.Body 0 8
}

function Test-PatternSlice([byte[]]$Body, [int64]$First) {
    for ($i = 0; $i -lt $Body.Length; $i++) {
        if ($Body[$i] -ne [byte](($First + $i) % 251)) { return $false }
    }
    return $true
}

# --------------------------------------------------------------------------

if ($SeedRoot) {
    Initialize-ProbeTree $SeedRoot
    Write-Host "Seeded $(Join-Path $SeedRoot $ProbeDir)"
    if ($SeedOnly) { exit 0 }
    # Give the server's watcher a debounce window to settle on the new tree.
    Start-Sleep -Seconds 3
} elseif ($SeedOnly) {
    throw "-SeedOnly needs -SeedRoot"
}

$probe = "\$ProbeDir"

# contract: B02 B03 -- framing, and two requests on one connection
$client = New-Connection
try {
    $first = Invoke-Driver "/get_dir_info" $probe -Client $client
    Check "B02" "listing returns 200" ($first.Status -eq 200) "got $($first.Status)"
    Test-Framing "B02" "listing" $first
    $second = Invoke-Driver "/get_dir_entry_info" "$probe\small.bin" -Client $client
    Check "B03" "second request on the same connection is answered" ($second.Status -eq 200) "got $($second.Status)"
    Test-Framing "B02" "entry metadata" $second
} catch {
    Report "B03" "FAIL" "keep-alive connection reuse" $_.Exception.Message
} finally {
    $client.Dispose()
}

# contract: B01 -- resident and streamed ranges
foreach ($case in @(
        @{ Name = "small.bin"; Range = @(100, 103); What = "resident range" },
        @{ Name = "small.bin"; Range = @(0, ($SmallSize - 1)); What = "resident whole-file range" },
        @{ Name = "large.bin"; Range = @(8388600, 8388700); What = "streamed range across the resident limit" },
        @{ Name = "large.bin"; Range = @(($LargeSize - 1), ($LargeSize - 1)); What = "streamed last byte" })) {
    $r = Invoke-Driver "/get_file" "$probe\$($case.Name)" $case.Range
    $want = $case.Range[1] - $case.Range[0] + 1
    Check "B01" "$($case.What) returns 206" ($r.Status -eq 206) "got $($r.Status)"
    Check "B01" "$($case.What) Content-Length is $want" ($r.Body.Length -eq $want) "got $($r.Body.Length)"
    Check "B01" "$($case.What) carries the right bytes" (Test-PatternSlice $r.Body $case.Range[0])
    Test-Framing "B02" $case.What $r
}

# contract: B04 -- error statuses with empty, framed bodies
foreach ($case in @(
        @{ Route = "/get_dir_entry_info"; Path = "$probe\missing.bin"; Want = 404; What = "missing file" },
        @{ Route = "/get_dir_info"; Path = "$probe\small.bin\x"; Want = 404; What = "file used as a directory" },
        @{ Route = "/get_dir_info"; Path = "\..\.."; Want = 403; What = "traversal above the root" },
        @{ Route = "/get_dir_info"; RawQuery = ""; Want = 400; What = "no path parameter" },
        @{ Route = "/get_file"; Path = "$probe\small.bin"; Range = @($SmallSize, ($SmallSize + 3)); Want = 416; What = "range starting at EOF" })) {
    $r = Invoke-Driver $case["Route"] $case["Path"] $case["Range"] $case["RawQuery"]
    Check "B04" "$($case.What) returns $($case.Want)" ($r.Status -eq $case.Want) "got $($r.Status)"
    Test-Framing "B02" $case.What $r
}

# contract: B05 -- the path forms the driver sends
foreach ($case in @(
        @{ Path = "\"; What = "backslash root" },
        @{ Path = ""; What = "empty root" },
        @{ Path = "$probe\sub"; What = "backslash separators" },
        @{ Path = "/$ProbeDir/sub"; What = "forward-slash separators" },
        @{ Path = "$probe\sub\..\sub"; What = "dot-dot inside the root" })) {
    $r = Invoke-Driver "/get_dir_info" $case.Path
    Check "B05" "$($case.What) lists" ($r.Status -eq 200) "got $($r.Status)"
}
$accent = [string][char]0x00e9 + "t" + [char]0x00e9 + ".txt"
$r = Invoke-Driver "/get_file" "$probe\$accent" @(0, 4)
Check "B05" "non-ASCII name is percent-encoded UTF-8" ($r.Status -eq 206 -and [System.Text.Encoding]::ASCII.GetString($r.Body) -eq "hello") "got $($r.Status)"

# contract: B08 -- metadata and content agree, and stay agreed after a change
$size = Get-EntrySize "$probe\large.bin"
Check "B08" "reported size of large.bin is $LargeSize" ($size -eq $LargeSize) "got $size"

if ($SeedRoot) {
    $shrinkPath = Join-Path (Join-Path $SeedRoot $ProbeDir) "shrink.bin"
    $before = Get-EntrySize "$probe\shrink.bin"
    $r = Invoke-Driver "/get_file" "$probe\shrink.bin" @(0, ($ShrinkFrom - 1))
    Check "B08" "shrink.bin served whole before the change" ($before -eq $ShrinkFrom -and $r.Status -eq 206) "size $before, status $($r.Status)"

    [System.IO.File]::WriteAllBytes($shrinkPath, (Get-PatternBytes $ShrinkTo 251))
    $deadline = (Get-Date).AddSeconds($ChangeDeadlineSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-EntrySize "$probe\shrink.bin"
    } while ($after -ne $ShrinkTo -and (Get-Date) -lt $deadline)
    Check "B08" "metadata reflects the shrink within $ChangeDeadlineSeconds s" ($after -eq $ShrinkTo) "still $after"

    $r = Invoke-Driver "/get_file" "$probe\shrink.bin" @(200, 299)
    Check "B08" "a range past the new EOF returns 416" ($r.Status -eq 416) "got $($r.Status)"

    $r = Invoke-Driver "/get_file" "$probe\shrink.bin" @(0, ($ShrinkTo - 1))
    Check "B08" "content matches the new size" ($r.Status -eq 206 -and $r.Body.Length -eq $ShrinkTo) "status $($r.Status), $($r.Body.Length) bytes"

    # contract: B11 (gap) -- what a driver still holding the old size gets: a
    # range straddling the new EOF. Reported, not judged; see contract.json.
    $r = Invoke-Driver "/get_file" "$probe\shrink.bin" @(0, ($ShrinkFrom - 1))
    $verdict = if ($r.Status -eq 206 -and $r.Body.Length -lt $ShrinkFrom) { "server sends a short 206 ($($r.Body.Length) of $ShrinkFrom bytes); the driver currently fails this read" } else { "status $($r.Status), $($r.Body.Length) bytes" }
    Report "B11" "INFO" "range straddling a shrunk EOF" $verdict
} else {
    Report "B08" "INFO" "change tests skipped" "needs -SeedRoot"
}

# contract: B09 (gap) -- report the host's case behaviour, never fail on it
$r = Invoke-Driver "/get_file" "$probe\mixedcase.txt" @(0, 3)
$verdict = if ($r.Status -eq 206) { "host is case-insensitive; the driver's case-insensitive opens work" } else { "host is case-sensitive ($($r.Status)); opening a file with different casing will fail at read" }
Report "B09" "INFO" "case mismatch between caller and disk" $verdict

if ($ResultPath) {
    [pscustomobject]@{
        server   = $Server
        failures = $script:Failures
        results  = $script:Results
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultPath -Encoding UTF8
}

Write-Host ""
Write-Host "$($script:Failures) failed check(s)"
exit $script:Failures
