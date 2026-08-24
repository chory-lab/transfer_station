<#
.SYNOPSIS
    Build a provisioned Transfer Station SD card (Windows).

.DESCRIPTION
    Windows cannot write the ext4 root partition, so this script provisions
    entirely through the FAT boot partition. Flash the base Raspberry Pi OS
    Lite image first with Raspberry Pi Imager (no customisation needed --
    this script supplies it), then run:

        .\flash.ps1 -BootDrive E:

    If Raspberry Pi Imager's CLI is installed, -Image and -Device will flash
    the card for you first.

.EXAMPLE
    .\flash.ps1 -BootDrive E:

.EXAMPLE
    .\flash.ps1 -Image .\raspios-bookworm-arm64-lite.img.xz -Device 2 -BootDrive E:
#>
[CmdletBinding()]
param(
    [string]$BootDrive,
    [string]$Image,
    [string]$Device,
    # Directory holding an unpacked offline dependency bundle. When given it
    # is staged on the card, and stage B installs with no network at all.
    [string]$Bundle
)

$ErrorActionPreference = 'Stop'
$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $Here

# --- boot-partition discovery ---------------------------------------------
# Raspberry Pi OS's FAT partition is the one carrying cmdline.txt. Windows does
# not always give it a drive letter -- Disk Management then shows the volume
# under its "bootfs" label with the letter column blank -- and a letterless
# volume is reachable only through its \\?\Volume{GUID}\ path, which both
# New-Item and tar reject. So match candidates by volume, letter or not, and
# mount the chosen one before writing to it.
function Find-PiBootVolume {
    Get-Volume |
        Where-Object { $_.FileSystem -eq 'FAT32' -and $_.DriveType -ne 'Remote' } |
        Where-Object {
            $root = if ($_.DriveLetter) { "$($_.DriveLetter):\" } else { $_.Path }
            $root -and (Test-Path -LiteralPath (Join-Path $root 'cmdline.txt'))
        }
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Return the volume's drive letter, assigning one first if it has none.
function Mount-PiBootVolume {
    param([Parameter(Mandatory = $true)]$Volume)
    if ($Volume.DriveLetter) { return [string]$Volume.DriveLetter }

    if (-not (Test-IsAdmin)) {
        throw @"
The card's boot partition ("$($Volume.FileSystemLabel)") has no drive letter,
so nothing can be written to it. Either:
  * re-run this from a PowerShell started with "Run as administrator", or
  * give it a letter by hand -- Win+X, Disk Management, right-click the
    "bootfs" partition, Change Drive Letter and Paths, Add, OK -- then re-run.
"@
    }

    $part = Get-Partition | Where-Object { $_.AccessPaths -contains $Volume.Path }
    if (-not $part) { throw "Could not find the partition behind $($Volume.Path)." }
    $used = (Get-Volume).DriveLetter | Where-Object { $_ }
    $free = 69..90 | ForEach-Object { [char]$_ } |
            Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $free) { throw 'No free drive letters left to assign.' }

    Write-Host "Boot partition has no drive letter; assigning ${free}:"
    $part | Set-Partition -NewDriveLetter $free
    foreach ($try in 1..20) {
        if (Test-Path -LiteralPath "${free}:\cmdline.txt") { return [string]$free }
        Start-Sleep -Milliseconds 500
    }
    throw "Assigned ${free}: but the boot partition never appeared there."
}


# --- read config.env ------------------------------------------------------
$cfg = @{}
Get-Content (Join-Path $Here 'config.env') | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $k, $v = $line.Split('=', 2)
        $cfg[$k.Trim()] = $v.Trim()
    }
}

# A password written by bootstrap.ps1 is base64-encoded so it survives being
# sourced by bash on the Pi; decode it back for our own use.
if ($cfg['PI_PASSWORD_B64']) {
    $cfg['PI_PASSWORD'] = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($cfg['PI_PASSWORD_B64']))
}

# --- optional flash via Raspberry Pi Imager CLI ---------------------------
if ($Image) {
    if (-not $Device) { throw "-Image requires -Device (the Imager device index or path)" }
    $imager = Get-Command 'rpi-imager' -ErrorAction SilentlyContinue
    if (-not $imager) {
        $candidate = "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe"
        if (Test-Path $candidate) { $imager = $candidate } else {
            throw "Raspberry Pi Imager CLI not found. Flash the card manually, then re-run with -BootDrive only."
        }
    }
    Write-Warning "About to ERASE device '$Device'."
    $confirm = Read-Host "Type the device again to confirm"
    if ($confirm -ne $Device) { throw "aborted" }
    & $imager --cli $Image $Device
    if ($LASTEXITCODE -ne 0) { throw "rpi-imager failed with exit code $LASTEXITCODE" }
    Write-Host "Waiting for the boot partition to remount..."
    Start-Sleep -Seconds 5
}

# --- locate and validate the boot partition -------------------------------
if (-not $BootDrive) {
    $found = @(Find-PiBootVolume)
    if ($found.Count -eq 0) {
        throw "No Raspberry Pi boot partition found. Flash the card first, or pass -BootDrive."
    }
    if ($found.Count -gt 1) {
        throw "More than one Raspberry Pi boot partition is attached; pass -BootDrive to pick one."
    }
    $BootDrive = (Mount-PiBootVolume -Volume $found[0]) + ':'
    Write-Host "Using boot partition $BootDrive"
} elseif ($BootDrive.StartsWith('\\?\Volume')) {
    # A \\?\Volume{GUID}\ path cannot be written through; swap it for a letter.
    $vol = Get-Volume | Where-Object { $_.Path -eq ($BootDrive.TrimEnd('\') + '\') }
    if (-not $vol) { throw "No volume matches $BootDrive." }
    $BootDrive = (Mount-PiBootVolume -Volume $vol) + ':'
    Write-Host "Using boot partition $BootDrive"
}

$boot = $BootDrive.TrimEnd('\')
# A bare drive letter ("E") becomes "E:"; anything already containing a colon
# or a path separator is treated as a path and left alone. Plain string checks,
# not regex: PowerShell single-quoted strings do not escape, so a backslash in a
# -match pattern is an illegal trailing escape and throws at runtime.
if (-not ($boot.Contains(':') -or $boot.Contains('\') -or $boot.Contains('/'))) {
    $boot = "${boot}:"
}
$cmdlinePath = Join-Path $boot 'cmdline.txt'
if (-not (Test-Path -LiteralPath $cmdlinePath)) {
    throw "$boot does not look like a Raspberry Pi boot partition (no cmdline.txt)"
}

$payload = Join-Path $boot 'transfer-station'
New-Item -ItemType Directory -Force -Path $payload | Out-Null

# --- pack the repository --------------------------------------------------
Write-Host "Packing repository..."
$tarPath = Join-Path $payload 'repo.tar.gz'
$excludes = @('.git', 'foobar', 'provisioning', '3D Files', '__pycache__', '*.pyc', 'dump.rdb')
$tarArgs = @('-czf', $tarPath, '-C', $RepoRoot)
foreach ($e in $excludes) { $tarArgs += "--exclude=$e" }
$tarArgs += '.'
& tar @tarArgs
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

# --- copy payload, forcing LF line endings --------------------------------
# The Pi runs these with bash; CRLF would break the shebang and heredocs.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($f in @('firstrun.sh', 'provision.sh', 'transfer-station.service')) {
    $text = [IO.File]::ReadAllText((Join-Path $Here "payload\$f")) -replace "`r`n", "`n"
    [IO.File]::WriteAllText((Join-Path $payload $f), $text, $utf8NoBom)
}
$cfgText = [IO.File]::ReadAllText((Join-Path $Here 'config.env')) -replace "`r`n", "`n"
[IO.File]::WriteAllText((Join-Path $payload 'config.env'), $cfgText, $utf8NoBom)

# --- build timestamp ------------------------------------------------------
# A Pi has no RTC. With no network it boots believing whatever time it last
# saved, often weeks in the past, which makes apt reject repositories as
# "not valid yet" and can break TLS. Record when this card was built so
# stage A can advance the clock to at least that point.
$epoch = [int][double]::Parse((Get-Date -UFormat %s))
[IO.File]::WriteAllText((Join-Path $payload "buildstamp"), "$epoch`n", $utf8NoBom)

# --- offline bundle -------------------------------------------------------
if ($Bundle) {
    if (-not (Test-Path -LiteralPath $Bundle)) { throw "Bundle not found: $Bundle" }
    Write-Host '>> staging offline bundle'
    $dest = Join-Path $payload 'bundle'
    if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse -Force $Bundle $dest
}

# --- arm the first-boot hook ---------------------------------------------
# Bookworm+ mounts the FAT partition at /boot/firmware; earlier releases /boot.
# pi-gen's real issue.txt names no codename -- it is only
#   Raspberry Pi reference <YYYY-MM-DD>
#   Generated using pi-gen, <url>, <sha>, stage<N>
# -- so the build date is the signal that actually exists. Bookworm was
# released 2023-10-10; the codename match stays as a belt-and-braces override.
$release = ''
$issuePath = Join-Path $boot 'issue.txt'
if (Test-Path -LiteralPath $issuePath) { $release = [IO.File]::ReadAllText($issuePath) }
$bookwormPlus = $false
if ($release -match 'bookworm|trixie|forky') {
    $bookwormPlus = $true
} elseif ($release -match '\d{4}-\d{2}-\d{2}') {
    $built = [datetime]::ParseExact($Matches[0], 'yyyy-MM-dd', $null)
    $bookwormPlus = $built -ge [datetime]'2023-10-10'
}
if ($bookwormPlus) {
    $runPath = '/boot/firmware/transfer-station/firstrun.sh'
} else {
    $runPath = '/boot/transfer-station/firstrun.sh'
}

$cmdline = ([IO.File]::ReadAllText($cmdlinePath) -replace "[`r`n]", ' ').Trim()
$cmdline = $cmdline -replace ' systemd\.run=\S*', '' `
                    -replace ' systemd\.run_success_action=\S*', '' `
                    -replace ' systemd\.unit=\S*', ''
$cmdline = "$cmdline systemd.run=$runPath systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"
[IO.File]::WriteAllText($cmdlinePath, "$cmdline`n", $utf8NoBom)

# --- recovery net ---------------------------------------------------------
# If the systemd.run hook never fires, stage A never runs -- and on Bookworm
# that leaves no account and no SSH, i.e. no way in and no option but to
# re-flash. Provision SSH and a login independently of the hook.
# firstrun.sh deletes userconf.txt once stage A has actually succeeded.
New-Item -ItemType File -Force -Path (Join-Path $boot 'ssh') | Out-Null

$openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
if (-not $openssl) {
    $gitSsl = Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'
    if (Test-Path $gitSsl) { $openssl = $gitSsl }
}
$userconf = Join-Path $boot 'userconf.txt'
if ($openssl -and $cfg['PI_PASSWORD']) {
    $hash = & $openssl passwd -6 $cfg['PI_PASSWORD']
    [IO.File]::WriteAllText($userconf, "$($cfg['PI_USER']):$hash`n", $utf8NoBom)
} else {
    Write-Warning 'No openssl or no PI_PASSWORD - skipping the userconf.txt fallback.'
    Write-Warning 'A failed first boot will be unrecoverable without re-flashing.'
    if (Test-Path $userconf) { Remove-Item $userconf -Force }
}

Write-Host ""
Write-Host "Card ready." -ForegroundColor Green
Write-Host ""
Write-Host "  1. Boot the Pi plugged into a router/switch WITH INTERNET."
Write-Host "     Two automatic reboots follow (stage A: offline setup, stage B: packages)."
Write-Host "     Stage B takes a few minutes; watch it on an HDMI display if you like."
Write-Host "  2. When it settles, move the Pi to the isolated switch."
Write-Host "     UI:  http://$($cfg['ETH_ADDRESS']):$($cfg['SERVER_PORT'])"
Write-Host "     SSH: ssh $($cfg['PI_USER'])@$($cfg['ETH_ADDRESS'])"
Write-Host ""
Write-Host "  Set your controller PC's NIC to a static address on the same subnet,"
Write-Host "  e.g. 192.168.10.2/$($cfg['ETH_PREFIX']), with no gateway."
