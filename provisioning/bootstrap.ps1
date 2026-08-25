<#
  One-shot Transfer Station SD card builder for Windows. No clone required:

    irm https://raw.githubusercontent.com/chory-lab/transfer_station/main/provisioning/bootstrap.ps1 | iex

  Insert the SD card and run the line above from an ADMINISTRATOR PowerShell.
  It writes Raspberry Pi OS to the card, provisions it, and verifies the
  result. If the card already has Raspberry Pi OS on it, the write is skipped.

  Requires Raspberry Pi Imager: https://www.raspberrypi.com/software/
#>
param(
    # Skip detection and use this drive letter as the card, e.g. -BootDrive E:
    [string]$BootDrive
)

$ErrorActionPreference = 'Stop'

$RepoZip  = 'https://github.com/chory-lab/transfer_station/archive/refs/heads/main.zip'
$ImageUrl  = $null   # set from the bundle manifest, or the current release
$BundleUrl = 'https://github.com/chory-lab/transfer_station/releases/latest/download/offline-bundle.tar.gz'
$Cache    = Join-Path $env:LOCALAPPDATA 'transfer-station'

Write-Host ''
Write-Host '=== Transfer Station SD card builder ===' -ForegroundColor Cyan

function Find-Imager {
    $c = (Get-Command 'rpi-imager' -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Raspberry Pi Imager\rpi-imager.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Raspberry Pi Imager\rpi-imager.exe')
    )) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- boot-partition discovery ---------------------------------------------
# The FAT partition is the one carrying cmdline.txt. Two Windows quirks make
# this harder than it looks, and both have bitten us:
#   * Get-Volume reports FileSystem inconsistently -- it can come back empty
#     for a perfectly good partition -- so filtering on 'FAT32' silently hides
#     the card. Do not filter on it; cmdline.txt is the real signal.
#   * Windows does not always assign a drive letter. Disk Management then
#     shows the volume under its "bootfs" label with the letter column blank,
#     and the only path it has is \\?\Volume{GUID}\, which both New-Item and
#     tar reject. Match those too, and assign a letter before writing.
function Find-PiBootVolume {
    $vols = @()
    try { $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -ne 'Remote' }) } catch {}
    foreach ($v in $vols) {
        $root = if ($v.DriveLetter) { "$($v.DriveLetter):\" } else { $v.Path }
        if ($root -and (Test-Path -LiteralPath (Join-Path $root 'cmdline.txt'))) { $v }
    }
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

# --- offline dependency bundle -------------------------------------------
# Fetched for EVERY card, not only ones we image ourselves: a card that
# already had Raspberry Pi OS on it needs the bundle just as much. The
# manifest also pins the image its .debs were built against, which is what
# $ImageUrl uses when we do write the OS.
function Get-OfflineBundle {
    $dir = Join-Path $Cache "bundle"
    if (Test-Path (Join-Path $dir "manifest.env")) {
        Write-Host ">> using the cached offline bundle"
        return $dir
    }
    Write-Host ">> downloading the offline dependency bundle"
    try {
        New-Item -ItemType Directory -Force -Path $Cache | Out-Null
        $bz = Join-Path $Cache "bundle.tar.gz"
        Invoke-WebRequest -Uri $BundleUrl -OutFile $bz -UseBasicParsing
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        & tar -xzf $bz -C $dir
        return $dir
    } catch {
        Write-Warning "No bundle available; the Pi will need one connected boot."
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        return $null
    }
}

function Read-BundleManifest {
    param([string]$Dir)
    $m = @{}
    if (-not $Dir) { return $m }
    $mf = Join-Path $Dir "manifest.env"
    if (Test-Path $mf) {
        Get-Content $mf | ForEach-Object {
            if ($_ -match "^([A-Z_]+)=(.*)$") { $m[$Matches[1]] = $Matches[2] }
        }
    }
    return $m
}


function Show-VolumeDiagnostics {
    Write-Host ''
    Write-Host 'Drives Windows can currently see:' -ForegroundColor DarkGray
    try {
        Get-Volume | Where-Object DriveLetter |
            Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType,
                          @{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}} |
            Format-Table -AutoSize | Out-String -Width 120 | Write-Host
    } catch { Write-Host '  (Get-Volume failed)' }
    Write-Host 'If one of those is the card, re-run with:  -BootDrive X:' -ForegroundColor DarkGray
}

# --- offline bundle (needed whether or not we write the OS) ---------------
$bundleDir = Get-OfflineBundle
$manifest  = Read-BundleManifest $bundleDir
if ($manifest["BUNDLE_CODENAME"]) {
    Write-Host "   bundle: $($manifest['BUNDLE_CODENAME']) (built $($manifest['BUNDLE_BUILT']))"
    if (-not $ImageUrl) { $ImageUrl = $manifest["BUNDLE_IMAGE_URL"] }
}
if (-not $ImageUrl) {
    $ImageUrl = "https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
}

# --- find the card --------------------------------------------------------
if ($BootDrive) {
    $forced = $BootDrive.TrimEnd([char]92).TrimEnd(':') + ':'
    if (-not (Test-Path -LiteralPath (Join-Path ($forced + [char]92) 'cmdline.txt'))) {
        throw "$forced has no cmdline.txt - that is not a Raspberry Pi OS boot partition."
    }
    $boot = $forced
    Write-Host "Using the card at $boot"
} else {
    $candidates = @(Find-PiBootVolume)

    if ($candidates.Count -eq 1) {
        $boot = (Mount-PiBootVolume -Volume $candidates[0]) + ':'
        Write-Host "Found Raspberry Pi OS on the card at $boot"
    } elseif ($candidates.Count -gt 1) {
        Write-Host ''
        Write-Host 'Multiple Raspberry Pi OS cards found:'
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c = $candidates[$i]
            $where = if ($c.DriveLetter) { "$($c.DriveLetter):" } else { "$($c.FileSystemLabel) (no drive letter)" }
            Write-Host "  [$($i+1)] $where ($([math]::Round($c.Size/1GB,1)) GB)"
        }
        $choice = Read-Host "Which one? [1-$($candidates.Count)]"
        $boot = (Mount-PiBootVolume -Volume $candidates[[int]$choice - 1]) + ':'
        Write-Host "Using the card at $boot"
    } else {
        # --- no OS on the card: write it -----------------------------------
        Write-Host ''
        Write-Host 'No Raspberry Pi OS card found - the card looks blank.'
        Write-Host 'This script can write Raspberry Pi OS Lite (64-bit) for you.'
        Show-VolumeDiagnostics

        $imager = Find-Imager
        if (-not $imager) {
            Write-Host ''
            Write-Host 'Raspberry Pi Imager is not installed.' -ForegroundColor Yellow
            Write-Host 'Install it from https://www.raspberrypi.com/software/ and run this again.'
            return
        }
        if (-not (Test-IsAdmin)) {
            Write-Host ''
            Write-Host 'Writing to a disk needs Administrator.' -ForegroundColor Yellow
            Write-Host 'Close this window, open PowerShell as Administrator, and paste the same line again.'
            return
        }

        # Only removable media. A wrong disk here is unrecoverable, so the
        # filter is deliberately strict and the confirmation is explicit.
        $disks = @(Get-Disk | Where-Object {
            $_.BusType -in @('USB', 'SD', 'MMC') -and
            -not $_.IsBoot -and -not $_.IsSystem -and
            $_.Size -lt 130GB   # plausible SD card, not a second internal drive
        })
        if ($disks.Count -eq 0) {
            Write-Host ''
            Write-Host 'No removable disk found. Is the card inserted?' -ForegroundColor Yellow
            Write-Host 'Note: some built-in card readers report as a fixed disk. If that is the'
            Write-Host 'case here, write the OS with Raspberry Pi Imager and run this again.'
            return
        }

        Write-Host ''
        Write-Host 'Removable disks:'
        for ($i = 0; $i -lt $disks.Count; $i++) {
            $d = $disks[$i]
            Write-Host "  [$($i+1)] Disk $($d.Number)  $($d.FriendlyName)  $([math]::Round($d.Size/1GB,1)) GB  ($($d.BusType))"
        }
        $c = Read-Host "Which one? [1-$($disks.Count)]"
        $disk = $disks[[int]$c - 1]

        Write-Host ''
        Write-Host "  !! Disk $($disk.Number) ($($disk.FriendlyName), $([math]::Round($disk.Size/1GB,1)) GB) will be COMPLETELY ERASED" -ForegroundColor Red
        if ((Read-Host '  Type ERASE to continue') -ne 'ERASE') { Write-Host 'Aborted.'; return }

        New-Item -ItemType Directory -Force -Path $Cache | Out-Null


        $xz = Join-Path $Cache 'raspios.img.xz'
        if (-not (Test-Path $xz)) {
            Write-Host ''
            Write-Host '>> downloading Raspberry Pi OS Lite (about 500 MB, cached for next time)'
            Invoke-WebRequest -Uri $ImageUrl -OutFile "$xz.part" -UseBasicParsing
            Move-Item "$xz.part" $xz
        } else {
            Write-Host '>> using the cached Raspberry Pi OS image'
        }

        Write-Host '>> writing the image (Imager verifies the write; this takes a few minutes)'
        & $imager --cli $xz "\\.\PHYSICALDRIVE$($disk.Number)"
        if ($LASTEXITCODE -ne 0) { throw "rpi-imager failed with exit code $LASTEXITCODE" }

        Write-Host '>> waiting for Windows to mount the boot partition'
        $boot = $null
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            $v = @(Find-PiBootVolume)
            if ($v.Count -gt 0) { $boot = (Mount-PiBootVolume -Volume $v[0]) + ':'; break }
        }
        if (-not $boot) {
            throw 'The card was written but Windows did not mount its boot partition. Re-insert the card and run this again.'
        }
        Write-Host "   mounted at $boot"
    }
}

# --- password -------------------------------------------------------------
Write-Host ''
$pw1 = Read-Host 'Password for the "chorylab" account (SSH login)' -AsSecureString
$pw2 = Read-Host 'Again' -AsSecureString
$p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
if (-not $p1)    { throw 'Password cannot be empty.' }
if ($p1 -ne $p2) { throw 'Passwords do not match.' }

# --- provision ------------------------------------------------------------
Write-Host ''
Write-Host '>> fetching provisioning scripts'
$work = Join-Path ([IO.Path]::GetTempPath()) ('ts_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $zip = Join-Path $work 'repo.zip'
    Invoke-WebRequest -Uri $RepoZip -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $work -Force
    $src = Get-ChildItem -Path $work -Directory -Filter 'transfer_station-*' | Select-Object -First 1

    $cfg = Join-Path $src.FullName 'provisioning\config.env'
    # Drop both PI_PASSWORD and PI_PASSWORD_B64 so re-runs cannot leave a stale one.
    $kept = Get-Content $cfg | Where-Object { $_ -notmatch '^PI_PASSWORD' }
    # Base64 so the value is safe for both bash's `source` and our own parser.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p1))
    ($kept + "PI_PASSWORD_B64=$b64") | Set-Content $cfg -Encoding utf8

    Write-Host '>> provisioning the card'
    # Hand the bundle to the flasher so the card carries its own deps.
    $bundleArg = @{}
    if ($bundleDir -and (Test-Path (Join-Path $bundleDir 'manifest.env'))) {
        $bundleArg['Bundle'] = $bundleDir
    }
    & (Join-Path $src.FullName 'provisioning\flash.ps1') -BootDrive $boot @bundleArg

    Write-Host ''
    Write-Host '>> verifying the card'
    & (Join-Path $src.FullName 'provisioning\verify-card.ps1') -BootDrive $boot
    if ($LASTEXITCODE -ne 0) {
        throw 'Verification FAILED. Do not boot this card - re-run to rebuild it.'
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
$haveBundle = [bool]$bundleDir -and (Test-Path (Join-Path $bundleDir 'manifest.env'))
if ($haveBundle) {
    Write-Host 'Done. The card carries all its dependencies, so the Pi needs NO' -ForegroundColor Green
    Write-Host 'internet. Put it in the Pi and boot it. It reboots twice, then:'
} else {
    Write-Host 'Done. No offline bundle was available, so boot the Pi ONCE plugged' -ForegroundColor Yellow
    Write-Host 'into a router with internet. It reboots twice by itself, then:'
}
Write-Host ''
Write-Host '    http://192.168.10.1:5000     ssh chorylab@192.168.10.1'
