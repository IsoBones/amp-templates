# a3nobewatchrpt.ps1
# Mirrors the newest MAIN SERVER Arma 3 RPT into a fixed-name file so AMP's
# TailLogFile console can display it. Headless client RPTs are excluded.
#
# Launched by AMP as a PreStartStage on every server start.
# Arguments:
#   [0] ProfilesDir - the -profiles directory where RPTs are written (e.g. ...\233780\A3Master)
#   [1] MirrorPath  - the fixed file AMP tails (e.g. ...\233780\A3Master\amp_console.log)
#   [2] BaseDir     - the server base directory, used to scope process checks to THIS instance

param(
    [Parameter(Mandatory = $true)][string]$ProfilesDir,
    [Parameter(Mandatory = $true)][string]$MirrorPath,
    [Parameter(Mandatory = $true)][string]$BaseDir
)

$ErrorActionPreference = 'SilentlyContinue'

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
$share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
try {
    $tmp = [System.IO.File]::Open($MirrorPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, $share)
    $tmp.Close()
} catch { }

# ---------------------------------------------------------------------------
# 3. Wait for a NEW main-server RPT to appear (created around/after our start)
#    Headless clients also write RPTs to this folder. Their RPT header command
#    line contains " -client ", the main server's does not. That is the
#    discriminator, not the filename case.
# ---------------------------------------------------------------------------
$startTime = Get-Date
$cutoff = $startTime.AddSeconds(-10)
$rpt = $null

while (-not $rpt) {
    if (((Get-Date) - $startTime).TotalSeconds -gt 300) { exit }
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
        $rpt = $c
        break
    }
}

# ---------------------------------------------------------------------------
# 4. Tail the RPT into the mirror file, byte for byte, on line boundaries
# ---------------------------------------------------------------------------
$in  = [System.IO.File]::Open($rpt.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
$out = [System.IO.File]::Open($MirrorPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, $share)

$pos = 0
$pending = New-Object System.IO.MemoryStream
$deadChecks = 0
$loop = 0

while ($true) {
    $len = $in.Length
    if ($len -gt $pos) {
        $null = $in.Seek($pos, [System.IO.SeekOrigin]::Begin)
        $chunk = New-Object byte[] ($len - $pos)
        $read = $in.Read($chunk, 0, $chunk.Length)
        if ($read -gt 0) {
            $pos += $read
            $pending.Write($chunk, 0, $read)

            # Flush only up to the last complete line (byte 10 = LF)
            $bytes = $pending.ToArray()
            $lastNl = [System.Array]::LastIndexOf($bytes, [byte]10)
            if ($lastNl -ge 0) {
                $out.Write($bytes, 0, $lastNl + 1)
                $out.Flush()
                $pending.SetLength(0)
                if ($lastNl + 1 -lt $bytes.Length) {
                    $pending.Write($bytes, $lastNl + 1, $bytes.Length - $lastNl - 1)
                }
            }
        }
        $deadChecks = 0
    }

    # Every ~5 seconds of idle, check the main server process is still alive
    $loop++
    if (($loop % 10) -eq 0 -and $len -le $pos) {
        $alive = Get-CimInstance Win32_Process -Filter "Name LIKE 'arma3server%'" | Where-Object {
            $_.CommandLine -and
            $_.CommandLine -notmatch '\s-client\s' -and
            $_.CommandLine -like "*$BaseDir*"
        }
        if (-not $alive) {
            $deadChecks++
            if ($deadChecks -ge 3) {
                # Flush any trailing partial line and exit
                $bytes = $pending.ToArray()
                if ($bytes.Length -gt 0) { $out.Write($bytes, 0, $bytes.Length); $out.Flush() }
                $in.Close()
                $out.Close()
                exit
            }
        } else {
            $deadChecks = 0
        }
    }

    Start-Sleep -Milliseconds 500
}
