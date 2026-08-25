<#
.SYNOPSIS
    Inspect a real flashed SD card from the PC, without booting the Pi.

.DESCRIPTION
    Reads the card's FAT boot partition and checks that everything the Pi
    needs is present and well-formed. Run it after flashing and before the
    first boot; run it again afterwards to see how far the Pi actually got.

.EXAMPLE
    .\verify-card.ps1 -BootDrive E:
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$BootDrive)

$ErrorActionPreference = 'Stop'
$script:run = 0
$script:bad = 0
$script:warn = 0

function Check {
    param([string]$Name, [bool]$Condition)
    $script:run++
    if ($Condition) {
        Write-Host "  ok    $Name" -ForegroundColor Green
    } else {
        $script:bad++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}
function Note { param([string]$Message)
    $script:warn++
    Write-Host "  note  $Message" -ForegroundColor Yellow
}
function Info { param([string]$Message)
    Write-Host "  info  $Message" -ForegroundColor DarkGray
}

$boot = $BootDrive.TrimEnd('\')
if (-not ($boot.Contains(':') -or $boot.Contains('\') -or $boot.Contains('/'))) {
    $boot = "${boot}:"
}
if (-not (Test-Path (Join-Path $boot 'cmdline.txt'))) {
    throw "$boot is not a Raspberry Pi boot partition (no cmdline.txt)"
}

$payload = Join-Path $boot 'transfer-station'
if (-not (Test-Path $payload)) {
    throw "No transfer-station payload on this card. Provision it with bootstrap.ps1 first."
}

$cmdline     = [IO.File]::ReadAllText((Join-Path $boot 'cmdline.txt'))
$hasFirstrun = Test-Path (Join-Path $payload 'firstrun.sh')
$hasFirstLog = Test-Path (Join-Path $payload 'firstrun.log')
$hasProvLog  = Test-Path (Join-Path $payload 'provision.log')

Write-Host ''
Write-Host "=== Card at $boot ===" -ForegroundColor Cyan

# Stage A deletes firstrun.sh from the card when it succeeds, so its presence
# tells us which phase the card is in.
if ($hasFirstrun -and -not $hasFirstLog) {
    $phase = 'preboot'
    Write-Host 'State: provisioned, not yet booted' -ForegroundColor Cyan
} elseif ($hasFirstrun -and $hasFirstLog) {
    $phase = 'stageA-failed'
    Write-Host 'State: stage A started but did NOT complete' -ForegroundColor Yellow
} else {
    $phase = 'booted'
    Write-Host 'State: stage A completed' -ForegroundColor Cyan
}
Write-Host ''

if ($phase -eq 'preboot') {

    Write-Host 'Boot hook'
    # Same rule as flash.ps1: pi-gen's issue.txt names no codename, only a
    # build date, so matching codenames alone sends every current image down
    # the pre-bookworm branch and this check fails on a perfectly good card.
    $release = ''
    if (Test-Path -LiteralPath (Join-Path $boot 'issue.txt')) {
        $release = [IO.File]::ReadAllText((Join-Path $boot 'issue.txt'))
    }
    $bookwormPlus = $false
    if ($release -match 'bookworm|trixie|forky') {
        $bookwormPlus = $true
    } elseif ($release -match '\d{4}-\d{2}-\d{2}') {
        $built = [datetime]::ParseExact($Matches[0], 'yyyy-MM-dd', $null)
        $bookwormPlus = $built -ge [datetime]'2023-10-10'
    }
    if ($bookwormPlus) {
        $expected = '/boot/firmware/transfer-station/firstrun.sh'
    } else {
        $expected = '/boot/transfer-station/firstrun.sh'
    }
    Check "cmdline.txt points at $expected" $cmdline.Contains("systemd.run=$expected")
    Check 'reboots after stage A'         ([bool]($cmdline -match 'systemd\.run_success_action=reboot'))
    Check 'runs at kernel-command-line'   ([bool]($cmdline -match 'systemd\.unit=kernel-command-line\.target'))
    Check 'original kernel params intact' ([bool]($cmdline -match 'root='))
    Check 'cmdline.txt is a single line'  (($cmdline.TrimEnd("`n")).Split("`n").Count -eq 1)
    Check 'cmdline.txt has no CR'         (-not $cmdline.Contains("`r"))
    if ($release) { Info "image: $($release.Trim())" }

    Write-Host ''
    Write-Host 'Payload'
    foreach ($f in @('firstrun.sh', 'provision.sh', 'transfer-station.service', 'config.env', 'repo.tar.gz')) {
        Check "$f present" (Test-Path (Join-Path $payload $f))
    }
    # A CRLF here breaks the shebang and the Pi silently never provisions.
    foreach ($f in @('firstrun.sh', 'provision.sh', 'config.env')) {
        $p = Join-Path $payload $f
        if (Test-Path $p) {
            Check "$f has LF endings only" (-not ([IO.File]::ReadAllText($p)).Contains("`r"))
        }
    }

    Write-Host ''
    Write-Host 'Recovery access (used if the boot hook never fires)'
    Check 'ssh flag file present' (Test-Path (Join-Path $boot 'ssh'))
    $ucPath = Join-Path $boot 'userconf.txt'
    Check 'userconf.txt present' (Test-Path $ucPath)
    if (Test-Path $ucPath) {
        $uc = [IO.File]::ReadAllText($ucPath)
        Check 'userconf holds a hash, not a plaintext password' ([bool]($uc -match ':\$6\$'))
    }

    Write-Host ''
    Write-Host 'Configuration'
    $cfg = @{}
    Get-Content (Join-Path $payload 'config.env') | ForEach-Object {
        $l = $_.Trim()
        if ($l -and -not $l.StartsWith('#') -and $l.Contains('=')) {
            $k, $v = $l.Split('=', 2)
            $cfg[$k.Trim()] = $v.Trim()
        }
    }
    $pwSet = [bool]$cfg['PI_PASSWORD_B64'] -or ($cfg['PI_PASSWORD'] -and $cfg['PI_PASSWORD'] -ne 'changeme')
    Check 'a password is set' $pwSet
    Check 'ethernet address configured' ([bool]($cfg['ETH_ADDRESS'] -match '^\d+\.\d+\.\d+\.\d+$'))
    Info "will come up at http://$($cfg['ETH_ADDRESS']):$($cfg['SERVER_PORT'])"
    Info "ssh $($cfg['PI_USER'])@$($cfg['ETH_ADDRESS'])"
    if ($cfg['PI_PASSWORD'] -eq 'changeme') { Note 'password is still the default "changeme"' }

    Write-Host ''
    Write-Host 'Repo archive'
    $list = $null
    try { $list = & tar -tzf (Join-Path $payload 'repo.tar.gz') 2>$null } catch {}
    $tarOk = ($LASTEXITCODE -eq 0 -and $list)
    Check 'repo.tar.gz is a readable archive' ([bool]$tarOk)
    if ($tarOk) {
        Check 'contains the flask app' ($list -contains './api_step_motor.py')
        Check 'contains the templates' ($list -contains './templates/buttons.html')
        Check 'contains pyproject.toml' ($list -contains './pyproject.toml')
        Check 'contains uv.lock'        ($list -contains './uv.lock')
    }

} else {

    # The card has been booted at least once; the logs are the interesting part.
    Write-Host 'Stage A'
    Check 'firstrun.log written' $hasFirstLog
    if ($hasFirstLog) {
        $flPath = Join-Path $payload 'firstrun.log'
        $fl = Get-Content $flPath -Raw
        $ok = [bool]($fl -match 'stage A complete')
        Check 'stage A reported completion' $ok
        if (-not $ok) {
            Write-Host '  --- last 25 lines of firstrun.log ---' -ForegroundColor DarkGray
            Get-Content $flPath -Tail 25 | ForEach-Object { Write-Host "      $_" }
        }
    }
    Check 'boot hook was disarmed' (-not $cmdline.Contains('systemd.run='))

    Write-Host ''
    Write-Host 'Stage B'
    if (-not $hasProvLog) {
        Note 'no provision.log - stage B never ran.'
        Note 'Did the Pi have internet on its second boot?'
    } else {
        $plPath = Join-Path $payload 'provision.log'
        $pl = Get-Content $plPath -Raw
        $ok = [bool]($pl -match 'provisioning complete')
        Check 'stage B reported completion' $ok
        if (-not $ok) {
            Write-Host '  --- last 30 lines of provision.log ---' -ForegroundColor DarkGray
            Get-Content $plPath -Tail 30 | ForEach-Object { Write-Host "      $_" }
        }
    }
}

Write-Host ''
if ($script:bad -eq 0) {
    $msg = "$($script:run) checks passed"
    if ($script:warn -gt 0) { $msg += ", $($script:warn) note(s)" }
    Write-Host $msg -ForegroundColor Green
    if ($phase -eq 'preboot') {
        Write-Host 'Card looks good. Put it in the Pi and boot it once with internet.'
    }
    exit 0
} else {
    Write-Host "$($script:bad) of $($script:run) checks FAILED" -ForegroundColor Red
    exit 1
}
