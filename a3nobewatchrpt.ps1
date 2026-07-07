# a3nobewatchrpt.ps1 (v7)
# v7: never holds the mirror file open. Every write is open-append-close so
# AMP's tail reader can always open the file between our writes.
# Mirrors the newest MAIN SERVER Arma 3 RPT plus server_console.log into a
# fixed-name file for AMP's TailLogFile console.
#
# Design rule: never fail closed. Filter errors fall back to raw mirroring.
# Everything of interest is logged to a3nobewatchrpt.log in the instance root.
#
# Arguments:
#   [0] ProfilesDir  - the -profiles dir where RPTs are written
#   [1] MirrorPath   - the fixed file AMP tails
#   [2] BaseDir      - server base dir, scopes process checks to this instance
#   [3] HideWarnings - "1" to filter Warning Message / bone / follow-up spam

param(
    [Parameter(Mandatory = $true)][string]$ProfilesDir,
    [Parameter(Mandatory = $true)][string]$MirrorPath,
    [Parameter(Mandatory = $true)][string]$BaseDir,
    [string]$HideWarnings = '0'
)

$share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete

# ----- logging ---------------------------------------------------------------
$logPath = Join-Path (Get-Location) 'a3nobewatchrpt.log'
function Write-Log([string]$msg) {
    try { Add-Content -Path $logPath -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $msg) } catch { }
}
try { Set-Content -Path $logPath -Value ("{0:yyyy-MM-dd HH:mm:ss} watcher v7 starting, pid $PID" -f (Get-Date)) } catch { }
Write-Log "raw args: ProfilesDir=[$ProfilesDir] MirrorPath=[$MirrorPath] BaseDir=[$BaseDir] HideWarnings=[$HideWarnings]"

# ----- repair args mangled by trailing backslash-before-quote -----------------
if ($BaseDir -match '^(.*?)["\s]+([01])\s*$') {
    $HideWarnings = $Matches[2]
    $BaseDir = $Matches[1]
}
$BaseDir = $BaseDir.Trim().TrimEnd('"', ' ', '\', '.')
if ($HideWarnings -notmatch '1') { $HideWarnings = '0' }
$script:FilterOn = ($HideWarnings -eq '1')
Write-Log "repaired: BaseDir=[$BaseDir] HideWarnings=[$HideWarnings] filterOn=$script:FilterOn"

# ----- counters / state --------------------------------------------------------
$script:ReadySeen     = $false
$script:ReadyRepeats  = 0
$script:LastSentinel  = [DateTime]::MinValue
$script:BytesIn       = 0
$script:BytesOut      = 0
$script:LinesDropped  = 0
$script:FilterErrors  = 0
$script:LastHeartbeat = Get-Date

# ----- kill stale watchers for this instance -----------------------------------
try {
    $self = $PID
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.ProcessId -ne $self -and
        $_.CommandLine -like '*a3nobewatchrpt.ps1*' -and
        $_.CommandLine -like "*amp_console.log*"
    } | ForEach-Object {
        Write-Log "killing stale watcher pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Log "stale-kill error: $($_.Exception.Message)" }

# ----- reset mirror (truncate then RELEASE the handle) ---------------------------
try {
    New-Item -ItemType Directory -Path $ProfilesDir -Force -ErrorAction SilentlyContinue | Out-Null
    $t = [System.IO.File]::Open($MirrorPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, $share)
    $t.Close()
} catch {
    Write-Log "FATAL cannot reset mirror: $($_.Exception.Message)"
    exit
}
$script:WriteFails = 0

# Open-append-flush-close per write. Never hold the mirror between writes so
# AMP's tail reader can always open it. Retries briefly if AMP has it locked.
function Write-Mirror([byte[]]$bytes, [int]$count) {
    for ($try = 1; $try -le 5; $try++) {
        try {
            $fs = [System.IO.File]::Open($MirrorPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, $share)
            $fs.Write($bytes, 0, $count)
            $fs.Flush()
            $fs.Close()
            $script:BytesOut += $count
            return $true
        } catch {
            if ($try -eq 5) {
                $script:WriteFails++
                if ($script:WriteFails -le 5) { Write-Log "mirror write failed after retries: $($_.Exception.Message)" }
            } else {
                Start-Sleep -Milliseconds 100
            }
        }
    }
    return $false
}

$startTime = Get-Date
$cutoff = $startTime.AddSeconds(-10)

# ----- filter: returns $true to DROP the line -----------------------------------
function Test-DropLine($state, [string]$line) {
    if ($line -match 'Warning Message:') { return $true }
    if ($line -match 'Error: Bone .* doesn.t exist in skeleton') { return $true }
    if ($line -match 'Error: Bad bone name') { return $true }
    if ($state.DroppedLast) {
        if ($line -match 'Context:') { return $true }
        if ($line -match 'Cannot evaluate') { return $true }
        if ($line -match '^\s*->Last modified by:') { return $true }
    }
    return $false
}

# ----- write one complete-lines block to the mirror ------------------------------
function Write-Block($state, [byte[]]$bytes, [int]$count) {
    # Ready detection on the raw block, independent of filtering
    if (-not $script:ReadySeen) {
        try {
            $probe = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $count)
            if ($probe -match 'Connected to Steam servers') {
                $script:ReadySeen = $true
                Write-Log 'ready line seen in RPT'
            }
        } catch { }
    }

    if (-not $script:FilterOn) {
        [void](Write-Mirror $bytes $count)
        return
    }

    try {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $count)
        $sb = New-Object System.Text.StringBuilder ($count)
        foreach ($line in $text.Split("`n")) {
            if ($line.Length -eq 0) { continue }
            if (Test-DropLine $state $line) {
                $state.DroppedLast = $true
                $script:LinesDropped++
            } else {
                $state.DroppedLast = $false
                [void]$sb.Append($line)
                [void]$sb.Append("`n")
            }
        }
        if ($sb.Length -gt 0) {
            $outBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
            [void](Write-Mirror $outBytes $outBytes.Length)
        }
    } catch {
        # Fail open: write the block raw, count the error, degrade permanently
        # to unfiltered if it keeps happening.
        $script:FilterErrors++
        Write-Log "filter error #$($script:FilterErrors): $($_.Exception.Message) - writing block unfiltered"
        [void](Write-Mirror $bytes $count)
        if ($script:FilterErrors -ge 5) {
            $script:FilterOn = $false
            Write-Log 'filter disabled after 5 errors, mirroring raw from here on'
        }
    }
}

# ----- tail state ------------------------------------------------------------------
function New-TailState([string]$Path, [long]$StartPos) {
    $s = New-Object psobject
    $s | Add-Member NoteProperty Path        $Path
    $s | Add-Member NoteProperty Stream      ([System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share))
    $s | Add-Member NoteProperty Pos         $StartPos
    $s | Add-Member NoteProperty Pending     (New-Object System.IO.MemoryStream)
    $s | Add-Member NoteProperty DroppedLast $false
    return $s
}

function Pump-Tail($state) {
    $wrote = $false
    try {
        $len = $state.Stream.Length
        if ($len -lt $state.Pos) { $state.Pos = 0 }
        if ($len -gt $state.Pos) {
            $null = $state.Stream.Seek($state.Pos, [System.IO.SeekOrigin]::Begin)
            $chunk = New-Object byte[] ($len - $state.Pos)
            $read = $state.Stream.Read($chunk, 0, $chunk.Length)
            if ($read -gt 0) {
                $state.Pos += $read
                $script:BytesIn += $read
                $state.Pending.Write($chunk, 0, $read)
                $bytes = $state.Pending.ToArray()
                $lastNl = [System.Array]::LastIndexOf($bytes, [byte]10)
                if ($lastNl -ge 0) {
                    Write-Block $state $bytes ($lastNl + 1)
                    $state.Pending.SetLength(0)
                    if ($lastNl + 1 -lt $bytes.Length) {
                        $state.Pending.Write($bytes, $lastNl + 1, $bytes.Length - $lastNl - 1)
                    }
                    $wrote = $true
                }
            }
        }
    } catch {
        Write-Log "pump error on $($state.Path): $($_.Exception.Message)"
    }
    return $wrote
}

function Flush-Tail($state) {
    try {
        $bytes = $state.Pending.ToArray()
        if ($bytes.Length -gt 0) { [void](Write-Mirror $bytes $bytes.Length) }
        $state.Stream.Close()
    } catch { }
}

# ----- wait for a NEW main-server RPT (HC RPTs contain " -client " in header) ------
$rptState = $null
while (-not $rptState) {
    if (((Get-Date) - $startTime).TotalSeconds -gt 300) {
        Write-Log 'no main-server RPT within 300s, exiting'
        exit
    }
    Start-Sleep -Milliseconds 1000
    $candidates = @(Get-ChildItem -Path $ProfilesDir -Filter '*.rpt' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $cutoff } |
        Sort-Object LastWriteTime -Descending)
    foreach ($c in $candidates) {
        $head = ''
        try {
            $fs = [System.IO.File]::Open($c.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $buf = New-Object byte[] 4096
            $n = $fs.Read($buf, 0, 4096)
            $fs.Close()
            $head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } catch { continue }
        if ($head.Length -lt 50) { continue }
        if ($head -match '\s-client\s') { continue }
        try { $rptState = New-TailState $c.FullName 0 } catch { Write-Log "cannot open RPT: $($_.Exception.Message)"; continue }
        Write-Log "locked RPT: $($c.FullName)"
        break
    }
}

# ----- server_console.log carries the player join/leave lines ----------------------
$conCandidates = @(
    (Join-Path $ProfilesDir 'server_console.log'),
    (Join-Path $BaseDir     'server_console.log')
)
$conState = $null
function Try-AttachConsoleLog {
    foreach ($p in $conCandidates) {
        if (Test-Path $p) {
            try {
                $item = Get-Item $p
                if ($item.LastWriteTime -gt $cutoff) { $startPos = 0 } else { $startPos = $item.Length }
                $s = New-TailState $p $startPos
                Write-Log "attached console log: $p (from byte $startPos)"
                return $s
            } catch { return $null }
        }
    }
    return $null
}

# ----- sentinel bytes ----------------------------------------------------------------
$sentinel = [System.Text.Encoding]::UTF8.GetBytes("AMP ready marker - Connected to Steam servers`r`n")

# ----- main loop -----------------------------------------------------------------------
$deadChecks = 0
$loop = 0
Write-Log 'entering main loop'

while ($true) {
    try {
        $activity = Pump-Tail $rptState
        if (-not $conState) { $conState = Try-AttachConsoleLog }
        if ($conState) {
            if (Pump-Tail $conState) { $activity = $true }
        }

        if ($script:ReadySeen -and $script:ReadyRepeats -lt 6) {
            if (((Get-Date) - $script:LastSentinel).TotalSeconds -ge 15) {
                [void](Write-Mirror $sentinel $sentinel.Length)
                $script:LastSentinel = Get-Date
                $script:ReadyRepeats++
                $activity = $true
            }
        }

        if ($activity) { $deadChecks = 0 }

        # heartbeat every 30s so the log always shows liveness
        if (((Get-Date) - $script:LastHeartbeat).TotalSeconds -ge 30) {
            Write-Log ("heartbeat: in={0} out={1} dropped={2} writeFails={3} filterOn={4} ready={5}" -f $script:BytesIn, $script:BytesOut, $script:LinesDropped, $script:WriteFails, $script:FilterOn, $script:ReadySeen)
            $script:LastHeartbeat = Get-Date
        }

        # every ~5s of idle, check the main server process is still alive
        $loop++
        if (($loop % 10) -eq 0 -and -not $activity) {
            $alive = $null
            try {
                $alive = Get-CimInstance Win32_Process -Filter "Name LIKE 'arma3server%'" | Where-Object {
                    $_.CommandLine -and
                    $_.CommandLine -notmatch '\s-client\s' -and
                    $_.CommandLine -like "*$BaseDir*"
                }
            } catch { Write-Log "alive-check error: $($_.Exception.Message)"; $alive = 'assume-alive' }
            if (-not $alive) {
                $deadChecks++
                if ($deadChecks -ge 3) {
                    Write-Log 'main server gone for 3 consecutive checks, exiting cleanly'
                    Flush-Tail $rptState
                    if ($conState) { Flush-Tail $conState }
                    exit
                }
            } else {
                $deadChecks = 0
            }
        }
    } catch {
        Write-Log "MAIN LOOP error: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
    }
    Start-Sleep -Milliseconds 500
}