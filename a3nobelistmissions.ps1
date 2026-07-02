# a3nobelistmissions.ps1
# Regenerates missions_available.txt from the pbo files in mpmissions so the
# "Available Missions" list in AMP settings stays current.
# Runs on every server update and every server start.
#
# Arguments:
#   [0] MissionsDir - the mpmissions folder (e.g. ...\233780\mpmissions)
#   [1] OutFile     - the list file AMP reads (e.g. ...\233780\missions_available.txt)

param(
    [Parameter(Mandatory = $true)][string]$MissionsDir,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$ErrorActionPreference = 'SilentlyContinue'

$names = @()
if (Test-Path $MissionsDir) {
    $names = Get-ChildItem -Path $MissionsDir -Filter '*.pbo' -File |
        ForEach-Object { $_.Name -replace '\.pbo$', '' } |
        Sort-Object
}

if ($names.Count -eq 0) {
    Set-Content -Path $OutFile -Value 'No pbo files found in mpmissions' -Encoding UTF8
} else {
    Set-Content -Path $OutFile -Value $names -Encoding UTF8
}
