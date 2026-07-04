# a3nobewatchrpt.ps1  (v4.1 - optional filtering of 'Warning Message:' and bone spam,
# plus the v3 ready sentinel so AMP cannot miss "Connected to Steam servers")
# Mirrors the newest MAIN SERVER Arma 3 RPT plus server_console.log into a
# fixed-name file so AMP's TailLogFile console can display it.
#
# Launched by AMP as a PreStartStage on every server start.
# Arguments:
#   [0] ProfilesDir  - the -profiles directory where RPTs are written
#   [1] MirrorPath   - the fixed file AMP tails
#   [2] BaseDir      - the server base directory, used to scope process checks
#   [3] HideWarnings - "1" to skip Warning Message lines (and their Context /
#                      Cannot evaluate follow-ups) in the console mirror.
#                      The RPT file itself is never modified.

param(
    [Parameter(Mandatory = $true)][string]$ProfilesDir,
    [Parameter(Mandatory = $true)][string]$MirrorPath,
    [Parameter(Mandatory = $true)][string]$BaseDir,
    [string]$HideWarnings = '0'
)

$ErrorActionPreference = 'SilentlyContinue'
$share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
$filterOn = ($HideWarnings -eq '1')

# Ready sentinel state
$script:ReadySeen = $false
$script:ReadyRepeats = 0
$script:LastSentinel = [DateTime]::MinValue

# ---------------------------------------------------------------------------
# 1. Kill any stale watcher from a previous run of this instance
# ---------------------------------------------------------------------------
$self = $PID
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    $_.ProcessId -ne $self -and
    $_.CommandLine -like '*a3nobewatchrpt.ps1*' -and
    $_.CommandLine -like "*$MirrorPath*"
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# ---------------------------------------------------------------------------
# 2. Reset the mirror file (truncate, shared so AMP can read it)
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $ProfilesDir -Force | Out-Null
$out = [System.IO.File]::Open($MirrorPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, $share)

$startTime = Get-Date
$cutoff = $startTime.AddSeconds(-10)

# ---------------------------------------------------------------------------
# Tail state helpers. One state object per source file. Complete lines only.
# ---------------------------------------------------------------------------
function New-TailState([string]$Path, [long]$StartPos) {
    $s = New-Object psobject
    $s | Add-Member NoteProperty Path        $Path
    $s | Add-Member NoteProperty Stream      ([System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share))
    $s | Add-Member NoteProperty Pos         $StartPos
    $s | Add-Member NoteProperty Pending     (New-Object System.IO.MemoryStream)
    $s | Add-Member NoteProperty DroppedLast $false
    return $s
}

function Write-Block($state, $outStream, [byte[]]$bytes, [int]$count) {
    # Watch for the ready indicator in the raw block, before any filtering
    if (-not $script:ReadySeen) {
        $probe = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $count)
        if ($probe -match 'Connected to Steam servers') { $script:ReadySeen = $true }
    }

    if (-not $filterOn) {
        $outStream.Write($bytes, 0, $count)
        return
    }

    # Filter mode: drop Warning Message lines and their continuation lines
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $count)
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in ($text -split "`n")) {
        if ($line.Length -eq 0) { continue }   # trailing empty from final newline
        $drop = $false
        if ($line -match 'Warning Message:') {
            $drop = $true
        } elseif ($line -match 'Error: Bone .* doesn.t exist in skeleton' -or $line -match 'Error: Bad bone name') {
            $drop = $true
        } elseif ($state.DroppedLast -and ($line -match 'Context:' -or $line -match 'Cannot evaluate')) {
            $drop = $true
        }
        $state.DroppedLast = $drop
        if (-not $drop) { [void]$sb.Append($line).Append("`n") }
    }
    if ($sb.Length -gt 0) {
        $outBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $outStream.Write($outBytes, 0, $outBytes.Length)
    }
}

function Pump-Tail($state, $outStream) {
    $wrote = $false
    $len = $state.Stream.Length
    if ($len -lt $state.Pos) { $state.Pos = 0 }            # file was truncated, restart
    if ($len -gt $state.Pos) {
        $null = $state.Stream.Seek($state.Pos, [System.IO.SeekOrigin]::Begin)
        $chunk = New-Object byte[] ($len - $state.Pos)
        $read = $state.Stream.Read($chunk, 0, $chunk.Length)
        if ($read -gt 0) {
            $state.Pos += $read
            $state.Pending.Write($chunk, 0, $read)
            $bytes = $state.Pending.ToArray()
            $lastNl = [System.Array]::LastIndexOf($bytes, [byte]10)
            if ($lastNl -ge 0) {
                Write-Block $state $outStream $bytes ($lastNl + 1)
                $state.Pending.SetLength(0)
                if ($lastNl + 1 -lt $bytes.Length) {
                    $state.Pending.Write($bytes, $lastNl + 1, $bytes.Length - $lastNl - 1)
                }
                $wrote = $true
            }
        }
    }
    return $wrote
}

function Flush-Tail($state, $outStream) {
    $bytes = $state.Pending.ToArray()
    if ($bytes.Length -gt 0) { $outStream.Write($bytes, 0, $bytes.Length) }
    $state.Stream.Close()
}

# ---------------------------------------------------------------------------
# 3. Wait for a NEW main-server RPT to appear (created around/after our start)
#    Headless clients write RPTs to the same folder; their RPT header command
#    line contains " -client ", the main server's does not.
# ---------------------------------------------------------------------------
$rptState = $null
while (-not $rptState) {
    if (((Get-Date) - $startTime).TotalSeconds -gt 300) { $out.Close(); exit }
    Start-Sleep -Milliseconds 1000

    $candidates = Get-ChildItem -Path $ProfilesDir -Filter '*.rpt' -File |
        Where-Object { $_.LastWriteTime -gt $cutoff } |
        Sort-Object LastWriteTime -Descending

    foreach ($c in $candidates) {
        $head = ''
        try {
            $fs = [System.IO.File]::Open($c.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $buf = New-Object byte[] 4096
            $n = $fs.Read($buf, 0, 4096)
            $fs.Close()
            $head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } catch { continue }

        if ($head.Length -lt 50) { continue }              # header not flushed yet, retry
        if ($head -match '\s-client\s') { continue }       # headless client RPT, skip
        $rptState = New-TailState $c.FullName 0
        break
    }
}

# ---------------------------------------------------------------------------
# 4. server_console.log (Arma's logFile setting) carries the player
#    connecting/connected/disconnected lines that the RPT does not.
#    Location varies, so watch both plausible spots and attach when it shows.
# ---------------------------------------------------------------------------
$conCandidates = @(
    (Join-Path $ProfilesDir 'server_console.log'),
    (Join-Path $BaseDir     'server_console.log')
)
$conState = $null

function Try-AttachConsoleLog {
    foreach ($p in $conCandidates) {
        if (Test-Path $p) {
            $item = Get-Item $p
            if ($item.LastWriteTime -gt $cutoff) { $startPos = 0 } else { $startPos = $item.Length }
            return New-TailState $p $startPos
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 5. Main loop: pump both tails into the mirror, re-emit the ready sentinel,
#    watch for server exit
# ---------------------------------------------------------------------------
$deadChecks = 0
$loop = 0
$sentinel = [System.Text.Encoding]::UTF8.GetBytes("AMP ready marker - Connected to Steam servers`r`n")

while ($true) {
    $activity = Pump-Tail $rptState $out
    if (-not $conState) { $conState = Try-AttachConsoleLog }
    if ($conState) {
        if (Pump-Tail $conState $out) { $activity = $true }
    }

    # Re-emit the ready line a few times after first sighting. If AMP dropped
    # the original during a startup log flood, these quiet repeats catch it.
    if ($script:ReadySeen -and $script:ReadyRepeats -lt 6) {
        if (((Get-Date) - $script:LastSentinel).TotalSeconds -ge 15) {
            $out.Write($sentinel, 0, $sentinel.Length)
            $script:LastSentinel = Get-Date
            $script:ReadyRepeats++
            $activity = $true
        }
    }

    if ($activity) { $out.Flush(); $deadChecks = 0 }

    # Every ~5 seconds of idle, check the main server process is still alive
    $loop++
    if (($loop % 10) -eq 0 -and -not $activity) {
        $alive = Get-CimInstance Win32_Process -Filter "Name LIKE 'arma3server%'" | Where-Object {
            $_.CommandLine -and
            $_.CommandLine -notmatch '\s-client\s' -and
            $_.CommandLine -like "*$BaseDir*"
        }
        if (-not $alive) {
            $deadChecks++
            if ($deadChecks -ge 3) {
                Flush-Tail $rptState $out
                if ($conState) { Flush-Tail $conState $out }
                $out.Flush()
                $out.Close()
                exit
            }
        } else {
            $deadChecks = 0
        }
    }

    Start-Sleep -Milliseconds 500
}