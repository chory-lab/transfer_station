<#
  Download the CI-audited sdm image and write it with Raspberry Pi Imager:

    irm https://raw.githubusercontent.com/chory-lab/transfer_station/sdm-image-builder/pi-image/bootstrap.ps1 | iex
#>
param([int]$DiskNumber = -1)
$ErrorActionPreference = 'Stop'

$ImageUrl = 'https://github.com/chory-lab/transfer_station/releases/download/pi-image-sdm/transfer-station.img.xz'
$ShaUrl = "$ImageUrl.sha256"
$Cache = Join-Path $env:LOCALAPPDATA 'transfer-station-sdm'
$Image = Join-Path $Cache 'transfer-station.img.xz'

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-Imager {
    $cmd = Get-Command rpi-imager -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $paths = @((Join-Path $env:ProgramFiles 'Raspberry Pi Imager\rpi-imager.exe'))
    if (${env:ProgramFiles(x86)}) {
        $paths += Join-Path ${env:ProgramFiles(x86)} 'Raspberry Pi Imager\rpi-imager.exe'
    }
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { return $path } }
    return $null
}

Write-Host ''
Write-Host '=== Transfer Station ready-image flasher ===' -ForegroundColor Cyan
if (-not (Test-IsAdmin)) { throw 'Open PowerShell with Run as administrator and try again.' }
$Imager = Find-Imager
if (-not $Imager) { throw 'Install Raspberry Pi Imager from https://www.raspberrypi.com/software/ and try again.' }

$Disks = @(Get-Disk | Where-Object {
    $_.BusType -in @('USB','SD','MMC') -and -not $_.IsBoot -and
    -not $_.IsSystem -and $_.Size -lt 1TB
})
if ($DiskNumber -ge 0) {
    $Disk = $Disks | Where-Object Number -eq $DiskNumber
    if (-not $Disk) { throw "Disk $DiskNumber is not an eligible removable disk." }
} else {
    if ($Disks.Count -eq 0) { throw 'No removable disk found.' }
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
