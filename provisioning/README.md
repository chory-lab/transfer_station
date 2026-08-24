# Transfer Station SD card provisioning

Turns a stock Raspberry Pi OS Lite image into a ready-to-run transfer station:
the repo installed, the Flask server started automatically at boot, and `eth0`
pinned to a static address on an **isolated** ethernet segment.

## What you end up with

| | |
|---|---|
| UI | `http://192.168.10.1:5000` |
| SSH | `ssh chorylab@192.168.10.1` |
| Server | `systemd` unit `transfer-station.service` (auto-restarts on failure) |
| Logs | `journalctl -u transfer-station -f` |

`eth0` gets a static address with **no gateway and no DNS**. Without a default
route on that interface the Pi cannot reach — and cannot be reached from — the
lab LAN. It is visible only to hosts plugged into the same switch.

Edit `config.env` before flashing to change the address, port, hostname or
password.

> `api_step_motor.py` hardcodes `/home/chorylab/transfer_station/templates`,
> so `PI_USER` must stay `chorylab` unless you also change that path.

## Flashing

### Windows

Flash the base image with Raspberry Pi Imager first, then:

```powershell
.\provisioning\flash.ps1
```

It finds the card by looking for the FAT32 volume that has a `cmdline.txt` in
it. Pass `-BootDrive E:` when more than one card is attached and you want to
name the right one; `E:` is the small FAT partition Windows mounts after
imaging (the one with `config.txt` and `cmdline.txt` in it).

#### If the boot partition has no drive letter

Windows does not always assign one. Disk Management then shows the partition
under its `bootfs` label with the drive-letter column blank, and nothing --
not `tar`, not PowerShell's own `New-Item` -- can write to it, because the
only path it has is a `\\?\Volume{GUID}\` path that those tools reject.

Both `flash.ps1` and `bootstrap.ps1` still *find* such a card, and will assign
a free letter themselves if PowerShell was started with **Run as
administrator**. Without elevation they stop and say so; assign the letter by
hand instead:

> Win+X -> Disk Management -> right-click the `bootfs` partition ->
> Change Drive Letter and Paths -> Add -> OK

### Which image, and Raspberry Pi Imager's customisation

Lite 64-bit is the intended base, but Desktop and Full work too -- nothing
here depends on the absence of a GUI.

Current Imager versions provision through **cloud-init**: applying any OS
customisation writes `user-data`, `meta-data` and `network-config` to the boot
partition and appends `ds=nocloud;...` to `cmdline.txt`. That is compatible
with the two-stage flow, but cloud-init runs *after* stage A and wins wherever
the two overlap:

| Setting | Winner on a customised card |
|---|---|
| hostname | Imager's, not `PI_HOSTNAME` |
| account password | Imager's, not `PI_PASSWORD` |
| SSH enabled | both do it |
| isolated static IP | stage B (its profile has `autoconnect-priority=100`) |

So either leave Imager's customisation switched off and let `config.env` own
everything, or set it in Imager and treat `PI_HOSTNAME` and `PI_PASSWORD` as
ignored. Stage B is ordered `After=cloud-final.service`, so the two never
contend for the apt lock.

### Linux / macOS

```bash
# flash and provision in one go
sudo ./provisioning/flash.sh --image raspios-bookworm-arm64-lite.img.xz --device /dev/sdX

# or provision a card you already flashed
./provisioning/flash.sh --boot /media/$USER/bootfs
```

## Troubleshooting a failed first boot

Both stages write a log to the **FAT boot partition**, which mounts on any
machine. If a boot goes wrong, pull the SD card, put it in your laptop and
read:

```
transfer-station/firstrun.log    # stage A
transfer-station/provision.log   # stage B
```

Stage B also prints to the console, so an HDMI monitor shows it live.

If stage A or B fails, the Pi falls back to DHCP with SSH enabled. Note that
on the isolated switch there is **no DHCP server**, so it will land on a
link-local `169.254.x.x` address and be effectively unreachable — plug it back
into a router to recover it over the network.

## First boot: plug into the internet once

The card boots in three phases:

1. **Stage A** (`firstrun.sh`, no network) — creates the user, sets the
   hostname, enables SSH, unpacks the repo, arms stage B. Reboots.
2. **Stage B** (`provision.sh`, needs internet) — `apt` installs
   `redis-server` and `python3-rpi.gpio`, installs `uv`, builds the venv,
   installs the systemd unit, then writes the isolated static network config.
   Reboots.
3. **Normal operation** — isolated static IP, server running.

Stage B is the only step that needs internet, so **give the Pi a normal
router/switch connection for the first boot**. It takes a few minutes. Once it
reboots into phase 3 you can move it to the isolated switch permanently.

If stage B can't reach the internet it exits with a clear error and retries on
the next boot — nothing is lost, just reconnect and reboot.

## Controller PC setup

Give the NIC facing the switch a static address on the same subnet, no gateway:

```
address 192.168.10.2
netmask 255.255.255.0
gateway <blank>
```

Leave your normal Wi-Fi/LAN adapter alone — it keeps the default route, so the
PC keeps internet while talking to the Pi over the switch.

## Python environment

`uv` manages the pure-Python deps in `requirements.txt`. The venv is built on
the **system** interpreter with `--system-site-packages`, so the apt-provided
`RPi.GPIO` C extension stays importable:

```bash
uv venv --python /usr/bin/python3 --system-site-packages .venv
uv pip install -r requirements.txt
```

To update deps on a running unit:

```bash
cd /home/chorylab/transfer_station
uv pip install --python .venv/bin/python -r requirements.txt
sudo systemctl restart transfer-station
```

The old `foobar/` venv (Python 3.7.3) is not used by the image and can be
ignored.

## Tests

```bash
provisioning/tests/run-all.sh              # host-safe suites
sudo provisioning/tests/run-all.sh         # + loopback SD card write
pwsh provisioning/tests/test_flash_ps1.ps1 # Windows flasher
```

| Suite | Runs | Covers |
|---|---|---|
| `test_flash_inject.sh` | anywhere | `cmdline.txt` hook, release detection, idempotence, payload staging, LF endings, tar excludes, arg validation |
| `test_flash_image.sh` | Linux + root | real MBR/FAT32 image written to a loopback "SD card" via `dd`, partition discovery, mount, on-card contents |
| `test_flash_ps1.ps1` | Windows | same properties as the bash injector, plus **byte-for-byte parity** of the generated `cmdline.txt` |
| `test_firstrun.sh` | container | stage A executed for real: account, groups, sudoers, hostname, repo extraction, stage B arming, self-disarm, password redaction |
| `test_rpios_chroot.sh` | Linux + root | the whole chain inside the **official Raspberry Pi OS rootfs** under qemu-user: real `archive.raspberrypi.com`, real package versions, real filesystem layout. Also asserts the image's own `/etc/fstab` really does mount the FAT partition at `/boot/firmware` |
| `test_deploy.sh` | container | generated unit, isolated network profile (asserts **no** `gateway=`/`dns=`), and the Flask server answering HTTP using the unit's real `ExecStart` |

The destructive suites create users and rewrite `/etc`, so they refuse to run
without `TS_ALLOW_DESTRUCTIVE=1` and are intended for a disposable container.

The deployment smoke test shims `RPi.GPIO` via `PYTHONPATH` (the real module
raises on non-Pi hardware) and runs a real `redis-server`, so it genuinely
exercises the app's import chain, the Redis-backed cache and template
rendering from the hardcoded `templates/` path.

## CI

`.github/workflows/image.yml` runs four jobs: static analysis, the Linux flash
pipeline (including the loopback image write), the Windows flash pipeline, and
the full stage A → stage B → deployment chain inside an **arm64 Debian
bookworm container** under QEMU.

That container is *Debian arm64, not Raspberry Pi OS* — it has no
`archive.raspberrypi.com` apt sources, so package versions differ from the real
device. It validates the logic and dependency resolution, not device fidelity.

### What CI still does *not* catch

The suites cover the *contents* of `cmdline.txt` and the payload, but nothing
in CI actually boots:

- The kernel honouring `systemd.run=` — no bootloader is involved
- `systemd` actually running the units (both stages stub `systemctl`)
- NetworkManager actually applying the profile to a real NIC
- Raspberry Pi OS's own apt archive and package versions
- Anything GPIO, driver or motor related — no hardware, and `RPi.GPIO` is
  shimmed

A test flash onto a spare SD card remains the only real validation of the boot
and network path.
