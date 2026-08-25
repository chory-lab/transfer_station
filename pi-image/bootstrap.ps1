<#
  Download the CI-audited sdm image and write it with Raspberry Pi Imager:

    irm https://raw.githubusercontent.com/chory-lab/transfer_station/main/pi-image/bootstrap.ps1 | iex
#>
param([int]$DiskNumber = -1)
$ErrorActionPreference = 'Stop'

$ImageUrl = 'https://github.com/chory-lab/transfer_station/releases/download/pi-image/transfer-station.img.xz'
$ShaUrl = "$ImageUrl.sha256"
$Cache = Join-Path $env:LOCALAPPDATA 'transfer-station-sdm'
$Image = Join-Path $Cache 'transfer-station.img.xz'

# Upper bound on what can plausibly be the SD card. SD cards for this job top
# out around 128GB and the image needs only a few; any machine doing the
# writing has far more. IsBoot and IsSystem are the guards that matter, but
# they only protect the disk you booted from -- a second internal drive is
# neither. This is what stops -DiskNumber naming one of those by mistake, so
# keep it near the top of the plausible card range rather than the disk range.
$MaxCardBytes = 130GB

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Imager moves. v1 installed to 'Raspberry Pi Imager', v2 to
# 'Raspberry Pi Ltd\Imager', and a per-user install lands somewhere else
# again -- so hardcoded paths go stale and the script claims Imager is not
# installed when it plainly is. Ask Windows where it is before guessing:
# App Paths and the uninstall entry are both written by the installer and
# survive the vendor renaming its directory.
function Find-Imager {
    $cmd = Get-Command rpi-imager -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $appPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\rpi-imager.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\rpi-imager.exe'
    )
    foreach ($key in $appPaths) {
        $entry = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
        if ($entry -and (Test-Path -LiteralPath $entry)) { return $entry }
    }

    $uninstall = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstall) {
        foreach ($app in (Get-ItemProperty $key -ErrorAction SilentlyContinue |
                          Where-Object { $_.DisplayName -like '*Raspberry Pi Imager*' })) {
            if (-not $app.InstallLocation) { continue }
            $exe = Join-Path $app.InstallLocation 'rpi-imager.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }

    # Last resort: the layouts we have actually seen, newest first.
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs") |
             Where-Object { $_ }
    foreach ($root in $roots) {
        foreach ($leaf in @('Raspberry Pi Ltd\Imager', 'Raspberry Pi Imager')) {
            $exe = Join-Path $root (Join-Path $leaf 'rpi-imager.exe')
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    return $null
}

Write-Host ''
Write-Host '=== Transfer Station ready-image flasher ===' -ForegroundColor Cyan
if (-not (Test-IsAdmin)) { throw 'Open PowerShell with Run as administrator and try again.' }
$Imager = Find-Imager
if (-not $Imager) { throw 'Install Raspberry Pi Imager from https://www.raspberrypi.com/software/ and try again.' }

# Two tiers. Writable is the real safety boundary: never the disk we booted
# from, never the system disk, never something too big to be removable media.
# Autodetect narrows that further by bus, because guessing wrong unprompted is
# unforgivable -- but the bus is only a hint. Built-in PCIe card readers report
# SCSI (a Realtek reader here does), so an explicit -DiskNumber has to be able
# to reach a disk autodetect passed over, or the recovery path does not run on
# the machine you would be recovering from.
$Writable = @(Get-Disk | Where-Object {
    -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -lt $MaxCardBytes
})
$Disks = @($Writable | Where-Object { $_.BusType -in @('USB','SD','MMC') })
if ($DiskNumber -ge 0) {
    $Disk = $Writable | Where-Object Number -eq $DiskNumber
    if (-not $Disk) {
        $limit = [math]::Round($MaxCardBytes / 1GB)
        throw "Disk $DiskNumber is not writable here: it must not be the boot or system disk, and must be under ${limit}GB."
    }
} else {
    if ($Disks.Count -eq 0) {
        # Say which disks were rejected and why, so the next person knows what
        # to pass rather than concluding the card is not detected at all.
        Write-Host ''
        Write-Host 'No removable disk found by bus type.' -ForegroundColor Yellow
        if ($Writable.Count -gt 0) {
            Write-Host 'These are writable but did not look removable:'
            foreach ($d in $Writable) {
                Write-Host "  Disk $($d.Number)  $($d.FriendlyName)  $([math]::Round($d.Size/1GB,1)) GB  (bus: $($d.BusType))"
            }
            Write-Host ''
            Write-Host 'Built-in card readers often report SCSI. If one of those is your card,'
            Write-Host 'name it explicitly, e.g.  .\bootstrap.ps1 -DiskNumber ' -NoNewline
            Write-Host "$($Writable[0].Number)"
        }
        throw 'No removable disk found.'
    }
    Write-Host ''
    for ($i = 0; $i -lt $Disks.Count; $i++) {
        $d = $Disks[$i]
        Write-Host "  [$($i+1)] Disk $($d.Number)  $($d.FriendlyName)  $([math]::Round($d.Size/1GB,1)) GB"
    }
    $choice = [int](Read-Host "Which one? [1-$($Disks.Count)]")
    if ($choice -lt 1 -or $choice -gt $Disks.Count) { throw 'Invalid selection.' }
    $Disk = $Disks[$choice - 1]
}

Write-Host ''
Write-Host "  !! Disk $($Disk.Number) ($($Disk.FriendlyName)) will be COMPLETELY ERASED" -ForegroundColor Red
if ((Read-Host '  Type ERASE to continue') -ne 'ERASE') { Write-Host 'Aborted.'; return }

New-Item -ItemType Directory -Force -Path $Cache | Out-Null
Write-Host '>> fetching the published checksum'
$ShaFile = Join-Path $Cache 'transfer-station.img.xz.sha256'
Invoke-WebRequest -Uri $ShaUrl -OutFile $ShaFile -UseBasicParsing
$Expected = ((Get-Content -Raw $ShaFile).Trim() -split '\s+')[0].ToLowerInvariant()
if ($Expected -notmatch '^[0-9a-f]{64}$') { throw 'Published checksum is invalid.' }

$NeedDownload = -not (Test-Path -LiteralPath $Image)
if (-not $NeedDownload) {
    $NeedDownload = (Get-FileHash -Algorithm SHA256 -LiteralPath $Image).Hash.ToLowerInvariant() -ne $Expected
}
if ($NeedDownload) {
    Write-Host '>> downloading the ready-to-flash image (about 1 GB)'
    Invoke-WebRequest -Uri $ImageUrl -OutFile "$Image.part" -UseBasicParsing
    Move-Item -Force "$Image.part" $Image
} else {
    Write-Host '>> using the verified cached image'
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Image).Hash.ToLowerInvariant() -ne $Expected) {
    throw 'Downloaded image checksum does not match the published checksum.'
}

Write-Host '>> writing and verifying the audited image'
& $Imager --cli $Image "\\.\PHYSICALDRIVE$($Disk.Number)"
if ($LASTEXITCODE -ne 0) { throw "Raspberry Pi Imager failed with exit code $LASTEXITCODE" }

Write-Host ''
Write-Host 'Done. Put the media in the Pi and switch it on.' -ForegroundColor Green
Write-Host '  UI:  http://192.168.10.1:5000'
Write-Host '  SSH: ssh chorylab@192.168.10.1'
Write-Warning 'This branch image currently uses the build credential (default: changeme).'
