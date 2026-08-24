<#
  One-shot Transfer Station SD card builder for Windows. No clone required:

    irm https://raw.githubusercontent.com/chory-lab/transfer_station/main/provisioning/bootstrap.ps1 | iex

  Flash stock Raspberry Pi OS Lite (64-bit) with Raspberry Pi Imager first,
  leave the card inserted, then run the line above. This script finds the
  card, asks for a password, and provisions it.
#>
$ErrorActionPreference = 'Stop'

$RepoZip = 'https://github.com/chory-lab/transfer_station/archive/refs/heads/main.zip'

Write-Host ''
Write-Host '=== Transfer Station SD card builder ===' -ForegroundColor Cyan

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

# --- 1. find the card's boot partition ------------------------------------
$candidates = @(Find-PiBootVolume)

if ($candidates.Count -eq 0) {
    Write-Host ''
    Write-Host 'No Raspberry Pi OS card found.' -ForegroundColor Yellow
    Write-Host 'Flash Raspberry Pi OS Lite (64-bit) with Raspberry Pi Imager first,'
    Write-Host 'leave the card inserted, then run this again.'
    Write-Host ''
    Write-Host 'Get Imager: https://www.raspberrypi.com/software/'
    return
}

if ($candidates.Count -eq 1) {
    $volume = $candidates[0]
} else {
    Write-Host ''
    Write-Host 'Multiple cards found:'
    $i = 1
    foreach ($c in $candidates) {
        $where = if ($c.DriveLetter) { "$($c.DriveLetter):" } else { "$($c.FileSystemLabel) (no drive letter)" }
        Write-Host "  [$i] $where ($([math]::Round($c.Size/1GB,1)) GB)"; $i++
    }
    $choice = Read-Host "Which one? [1-$($candidates.Count)]"
    $volume = $candidates[[int]$choice - 1]
}
$boot = (Mount-PiBootVolume -Volume $volume) + ':'
Write-Host "Found the card at $boot"

# --- 2. password ----------------------------------------------------------
Write-Host ''
$pw1 = Read-Host 'Password for the "chorylab" account (SSH login)' -AsSecureString
$pw2 = Read-Host 'Again' -AsSecureString
$p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
if (-not $p1)      { throw 'Password cannot be empty.' }
if ($p1 -ne $p2)   { throw 'Passwords do not match.' }

# --- 3. fetch the provisioning scripts ------------------------------------
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
    # Rewrite the line rather than regex-replacing into it: $ and \ in a
    # password would otherwise be interpreted as replacement metacharacters.
    $kept = Get-Content $cfg | Where-Object { $_ -notmatch '^PI_PASSWORD=' }
    # Base64 so the value is safe for both bash's `source` and our own parser.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p1))
    ($kept + "PI_PASSWORD_B64=$b64") | Set-Content $cfg -Encoding utf8

    Write-Host '>> provisioning the card'
    & (Join-Path $src.FullName 'provisioning\flash.ps1') -BootDrive $boot
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Done. Put the card in the Pi and boot it ONCE plugged into a router' -ForegroundColor Green
Write-Host 'with internet. It reboots twice by itself, then comes up at:'
Write-Host ''
Write-Host '    http://192.168.10.1:5000     ssh chorylab@192.168.10.1'
