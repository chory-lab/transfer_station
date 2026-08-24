<#
    Runs flash.ps1 against a synthetic boot directory and asserts the same
    properties test_flash_inject.sh asserts for flash.sh.

    Two independent implementations of the cmdline.txt rewrite exist (bash and
    PowerShell); this is what stops them drifting apart.
#>
$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Prov = Split-Path -Parent $Here

$script:Run = 0
$script:Failed = 0

function It([string]$Name, [scriptblock]$Body) {
    $script:Run++
    try {
        $result = & $Body
        if ($result -eq $true) {
            Write-Host "  ok:   $Name" -ForegroundColor Green
        } else {
            $script:Failed++
            Write-Host "  FAIL: $Name" -ForegroundColor Red
        }
    } catch {
        $script:Failed++
        Write-Host "  FAIL: $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-FakeBoot([string]$Dir, [string]$Release) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $lf = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $Dir 'cmdline.txt'),
        "console=serial0,115200 console=tty1 root=PARTUUID=1a2b3c4d-02 rootfstype=ext4 fsck.repair=yes rootwait quiet`n", $lf)
    [IO.File]::WriteAllText((Join-Path $Dir 'config.txt'), "dtparam=audio=on`n", $lf)
    if ($Release -eq 'bookworm') {
        [IO.File]::WriteAllText((Join-Path $Dir 'issue.txt'), "Raspberry Pi reference 2024-11-19 (stage2, bookworm)`n", $lf)
    } elseif ($Release -eq 'bullseye') {
        [IO.File]::WriteAllText((Join-Path $Dir 'issue.txt'), "Raspberry Pi reference 2023-05-03 (stage2, bullseye)`n", $lf)
    }
    [IO.File]::WriteAllText((Join-Path $Dir 'userconf.txt'), "pi:`$6`$fakehash`n", $lf)
}

$Work = Join-Path ([IO.Path]::GetTempPath()) ("tsflash_" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $Work | Out-Null

try {
    Write-Host "== cmdline.txt hook (bookworm) =="
    $boot = Join-Path $Work 'bw'
    New-FakeBoot $boot 'bookworm'
    & (Join-Path $Prov 'flash.ps1') -BootDrive $boot | Out-Null
    $cmdline = [IO.File]::ReadAllText((Join-Path $boot 'cmdline.txt'))

    It "appends the systemd.run hook"           { $cmdline -match [regex]::Escape('systemd.run=/boot/firmware/transfer-station/firstrun.sh') }
    It "sets reboot as the success action"      { $cmdline -match 'systemd\.run_success_action=reboot' }
    It "targets kernel-command-line.target"     { $cmdline -match 'systemd\.unit=kernel-command-line\.target' }
    It "preserves original kernel parameters"   { $cmdline -match 'root=PARTUUID=1a2b3c4d-02' }
    It "cmdline.txt stays a single line"        { ($cmdline.TrimEnd("`n")).Split("`n").Count -eq 1 }
    It "cmdline.txt has no CR"                  { -not $cmdline.Contains("`r") }

    Write-Host ""
    Write-Host "== release detection =="
    $bootBe = Join-Path $Work 'be'
    New-FakeBoot $bootBe 'bullseye'
    & (Join-Path $Prov 'flash.ps1') -BootDrive $bootBe | Out-Null
    $cmdBe = [IO.File]::ReadAllText((Join-Path $bootBe 'cmdline.txt'))
    It "bullseye uses the /boot mount path"     { $cmdBe -match [regex]::Escape('systemd.run=/boot/transfer-station/firstrun.sh') }
    It "bullseye avoids /boot/firmware"         { -not $cmdBe.Contains('/boot/firmware/') }

    $bootNone = Join-Path $Work 'none'
    New-FakeBoot $bootNone 'none'
    & (Join-Path $Prov 'flash.ps1') -BootDrive $bootNone | Out-Null
    $cmdNone = [IO.File]::ReadAllText((Join-Path $bootNone 'cmdline.txt'))
    It "missing issue.txt falls back to /boot"  { $cmdNone -match [regex]::Escape('systemd.run=/boot/transfer-station/firstrun.sh') }

    Write-Host ""
    Write-Host "== idempotence =="
    & (Join-Path $Prov 'flash.ps1') -BootDrive $boot | Out-Null
    & (Join-Path $Prov 'flash.ps1') -BootDrive $boot | Out-Null
    $cmdline2 = [IO.File]::ReadAllText((Join-Path $boot 'cmdline.txt'))
    It "no duplicate systemd.run" {
        ([regex]::Matches($cmdline2, 'systemd\.run=')).Count -eq 1
    }
    It "no duplicate systemd.unit" {
        ([regex]::Matches($cmdline2, 'systemd\.unit=')).Count -eq 1
    }
    It "still a single line" { ($cmdline2.TrimEnd("`n")).Split("`n").Count -eq 1 }

    Write-Host ""
    Write-Host "== payload staging =="
    $payload = Join-Path $boot 'transfer-station'
    It "firstrun.sh present"      { Test-Path (Join-Path $payload 'firstrun.sh') }
    It "provision.sh present"     { Test-Path (Join-Path $payload 'provision.sh') }
    It "service template present" { Test-Path (Join-Path $payload 'transfer-station.service') }
    It "config.env present"       { Test-Path (Join-Path $payload 'config.env') }
    It "repo tarball present"     { Test-Path (Join-Path $payload 'repo.tar.gz') }
    It "ssh flag file written"    { Test-Path (Join-Path $boot 'ssh') }
    It "userconf.txt fallback written" { Test-Path (Join-Path $boot 'userconf.txt') }
    It "userconf.txt holds a hash, not plaintext" {
        $uc = [IO.File]::ReadAllText((Join-Path $boot 'userconf.txt'))
        $uc.StartsWith('chorylab:$6$') -and (-not $uc.Contains('changeme'))
    }

    # This is the failure mode unique to the Windows path: a CRLF in
    # firstrun.sh breaks the shebang and the Pi silently never provisions.
    foreach ($f in @('firstrun.sh', 'provision.sh', 'config.env')) {
        It "$f written with LF endings only" {
            -not ([IO.File]::ReadAllText((Join-Path $payload $f))).Contains("`r")
        }
    }

    Write-Host ""
    Write-Host "== repo tarball contents =="
    $list = & tar -tzf (Join-Path $payload 'repo.tar.gz')
    It "includes the flask app"    { $list -contains './api_step_motor.py' }
    It "includes the templates"    { $list -contains './templates/buttons.html' }
    It "includes requirements.txt" { $list -contains './requirements.txt' }
    It "excludes the stale venv"   { -not ($list | Where-Object { $_ -like './foobar/*' }) }
    It "excludes .git"             { -not ($list | Where-Object { $_ -like './.git/*' }) }
    It "excludes provisioning/"    { -not ($list | Where-Object { $_ -like './provisioning/*' }) }
    It "excludes the 3D files"     { -not ($list | Where-Object { $_ -like './3D Files/*' }) }

    Write-Host ""
    Write-Host "== argument validation =="
    It "rejects a directory with no cmdline.txt" {
        $bad = Join-Path $Work 'notboot'
        New-Item -ItemType Directory -Force -Path $bad | Out-Null
        try { & (Join-Path $Prov 'flash.ps1') -BootDrive $bad | Out-Null; $false }
        catch { $true }
    }

    Write-Host ""
    Write-Host "== parity with flash.sh =="
    # Both implementations must produce byte-identical cmdline.txt for the
    # same input. This is the whole point of having this file.
    It "produces the same cmdline.txt as flash.sh would" {
        $expected = "console=serial0,115200 console=tty1 root=PARTUUID=1a2b3c4d-02 rootfstype=ext4 fsck.repair=yes rootwait quiet systemd.run=/boot/firmware/transfer-station/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target`n"
        $cmdline2 -ceq $expected
    }

} finally {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failed -eq 0) {
    Write-Host "$($script:Run) passed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Failed) of $($script:Run) failed" -ForegroundColor Red
    exit 1
}
