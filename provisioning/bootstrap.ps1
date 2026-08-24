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
$ImageUrl = 'https://downloads.raspberrypi.com/raspios_lite_arm64_latest'
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

# --- is a Raspberry Pi OS card already present? ---------------------------
# Deliberately does NOT filter on FileSystem: Get-Volume reports that
# property inconsistently (it can come back empty for a perfectly good
# partition), which silently hides the card. The presence of cmdline.txt is
# the real signal, so just test every drive letter we can see.
function Get-PiBootVolume {
    $letters = @()
    try { $letters += (Get-Volume -ErrorAction Stop | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter }) } catch {}
    try { $letters += (Get-PSDrive -PSProvider FileSystem -ErrorAction Stop | ForEach-Object { $_.Name }) } catch {}
    $letters = $letters | Where-Object { $_ } | ForEach-Object { ("$_").Trim() } | Sort-Object -Unique
    foreach ($l in $letters) {
        $root = $l.TrimEnd(":") + ":" + [char]92
        if (Test-Path (Join-Path $root "cmdline.txt")) {
            [pscustomobject]@{ DriveLetter = $l.TrimEnd(":") }
        }
    }
}

function Show-VolumeDiagnostics {
    Write-Host ""
    Write-Host "Drives Windows can currently see:" -ForegroundColor DarkGray
    try {
        Get-Volume | Where-Object DriveLetter |
            Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType,
                          @{n="SizeGB";e={[math]::Round($_.Size/1GB,2)}} |
            Format-Table -AutoSize | Out-String -Width 120 | Write-Host
    } catch { Write-Host "  (Get-Volume failed)" }
    Write-Host "If one of those is the card, re-run with:  -BootDrive X:" -ForegroundColor DarkGray
}

if ($BootDrive) {
    $forced = $BootDrive.TrimEnd([char]92).TrimEnd(":") + ":"
    if (-not (Test-Path (Join-Path ($forced + [char]92) "cmdline.txt"))) {
        throw "$forced has no cmdline.txt - that is not a Raspberry Pi OS boot partition."
    }
    $existing = @([pscustomobject]@{ DriveLetter = $forced.TrimEnd(":") })
} else {
    $existing = @(Get-PiBootVolume)
}

if ($existing.Count -gt 0) {
    if ($existing.Count -eq 1) {
        $boot = "$($existing[0].DriveLetter):"
        Write-Host "Found Raspberry Pi OS on the card at $boot"
    } else {
        Write-Host ''
        Write-Host 'Multiple Raspberry Pi OS cards found:'
        for ($i = 0; $i -lt $existing.Count; $i++) {
            Write-Host "  [$($i+1)] $($existing[$i].DriveLetter):"
        }
        $c = Read-Host "Which one? [1-$($existing.Count)]"
        $boot = "$($existing[[int]$c - 1].DriveLetter):"
    }
} else {
    # --- no OS on the card: write it ---------------------------------------
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

    $admin = ([Security.Principal.WindowsPrincipal] `
              [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Host ''
        Write-Host 'Writing to a disk needs Administrator.' -ForegroundColor Yellow
        Write-Host 'Close this window, open PowerShell as Administrator, and paste the same line again.'
        return
    }

    # Only removable media. A wrong disk here is unrecoverable, so the filter
    # is deliberately strict and the confirmation is explicit.
    $disks = @(Get-Disk | Where-Object {
        $_.BusType -in @('USB', 'SD', 'MMC') -and
        -not $_.IsBoot -and -not $_.IsSystem -and
        $_.Size -lt 1TB
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
        $v = @(Get-PiBootVolume)
        if ($v.Count -gt 0) { $boot = "$($v[0].DriveLetter):"; break }
    }
    if (-not $boot) {
        throw 'The card was written but Windows did not mount its boot partition. Re-insert the card and run this again.'
    }
    Write-Host "   mounted at $boot"
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
    $kept = Get-Content $cfg | Where-Object { $_ -notmatch '^PI_PASSWORD=' }
    # Base64 so the value is safe for both bash's `source` and our own parser.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p1))
    ($kept + "PI_PASSWORD_B64=$b64") | Set-Content $cfg -Encoding utf8

    Write-Host '>> provisioning the card'
    & (Join-Path $src.FullName 'provisioning\flash.ps1') -BootDrive $boot

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
Write-Host 'Done. Put the card in the Pi and boot it ONCE plugged into a router' -ForegroundColor Green
Write-Host 'with internet. It reboots twice by itself, then comes up at:'
Write-Host ''
Write-Host '    http://192.168.10.1:5000     ssh chorylab@192.168.10.1'
