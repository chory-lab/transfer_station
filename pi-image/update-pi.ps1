<#
.SYNOPSIS
    Updates the app on a running transfer station Pi from this checkout, over SSH.

.DESCRIPTION
    Run from the robot PC, which is wired to the Pi. The Pi needs no internet.
    Packs the app files, uploads them with apply-update.sh, and runs it on the
    Pi, which backs up, installs, restarts and rolls back on failure.
    update-pi.sh does the same from macOS or Linux.

.EXAMPLE
    git pull
    .\pi-image\update-pi.ps1

.EXAMPLE
    .\pi-image\update-pi.ps1 -Target chorylab@192.168.10.1
#>
param(
    [string]$Target = 'chorylab@192.168.10.1'
)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot

# What runs on the Pi. pyproject.toml and uv.lock go along only so the Pi
# can refuse an update that changes dependencies.
$Files = @('A4988.py', 'api_step_motor.py', 'templates', 'pyproject.toml', 'uv.lock')

foreach ($cmd in 'ssh', 'scp', 'tar') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "$cmd was not found. It ships with Windows 10 and later; for ssh and scp, enable the 'OpenSSH Client' optional feature."
    }
}
foreach ($f in $Files) {
    if (-not (Test-Path (Join-Path $Root $f))) { throw "$f is missing from $Root" }
}

$Name = 'ts-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$Stage = Join-Path ([IO.Path]::GetTempPath()) $Name
New-Item -ItemType Directory -Path $Stage | Out-Null
$code = 1
try {
    Push-Location $Root
    try {
        & tar -cf (Join-Path $Stage 'bundle.tar') @Files
        if ($LASTEXITCODE -ne 0) { throw 'packing the app files failed' }
    } finally {
        Pop-Location
    }
    Copy-Item (Join-Path $PSScriptRoot 'apply-update.sh') $Stage

    Write-Host "==> Uploading to $Target (enter the Pi password if asked)"
    & scp -q -r $Stage "${Target}:/tmp/"
    if ($LASTEXITCODE -ne 0) { throw "upload to $Target failed" }

    Write-Host '==> Installing on the Pi'
    & ssh -t $Target "bash /tmp/$Name/apply-update.sh /tmp/$Name/bundle.tar; s=`$?; rm -rf /tmp/$Name; exit `$s"
    $code = $LASTEXITCODE
} finally {
    Remove-Item -Recurse -Force $Stage -ErrorAction SilentlyContinue
}

if ($code -ne 0) {
    Write-Host 'Update failed; see the messages above.' -ForegroundColor Red
    exit $code
}
Write-Host 'Pi updated.' -ForegroundColor Green
