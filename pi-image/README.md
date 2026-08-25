# pi-image

Builds a ready-to-flash Raspberry Pi image with the application, its
dependencies, an autostarting service, and an isolated static-IP ethernet
link all baked in.

Flash it and switch the Pi on. There is no first-boot provisioning, no
two-stage boot, and **the Pi never needs a network**.

## Why this shape

The obvious approach is to flash stock Raspberry Pi OS and configure it on
first boot. We built that first, and it cost us: a `systemd.run=` hook whose
path depends on the OS release, Windows volumes that sometimes have no drive
letter, CRLF mangling the shebang of the first-boot script, a Pi with no RTC
whose clock made `apt` reject repositories, and a 23 MB dependency bundle to
avoid needing internet on the device.

Every one of those problems exists only because work was deferred to the
device. Doing it at build time, in a chroot on a machine that can be tested,
deletes the entire category.

[`sdm`](https://github.com/gitbls/sdm) does the image customisation. It
already handles the account wizard, cloud-init, `machine-id`, root expansion
and the rest — the things we would otherwise rediscover one bug at a time.

## Building

```bash
sudo PI_PASSWORD='your-password' ./pi-image/build.sh
```

Produces `transfer-station-YYYY-MM-DD.img.xz` (currently about 900 MB). Flash it with
Raspberry Pi Imager, with **no customisation** — this image already has it.

CI builds and audits the final compressed image on every relevant push. Main
publishes the rolling `pi-image` release; the top-level README flashers
download that exact asset and verify its checksum.

## Configuring

Everything project-specific is in [`pi-app.env`](pi-app.env). That file is
the entire interface:

| Key | Meaning |
|---|---|
| `APP_NAME`, `PI_HOSTNAME`, `PI_USER` | identity |
| `REPO_DEST` | where the app is installed |
| `APT_PACKAGES` | system packages (C extensions, services) |
| `APP_EXEC` | the command the service runs; `${VENV}` and `${SERVER_PORT}` are substituted |
| `ETH_*`, `SERVER_PORT` | the isolated link |

Pure-Python dependencies come from `pyproject.toml` and are installed from
the hash-pinned `uv.lock` with `uv sync --frozen`
into a venv built on the system interpreter with `--system-site-packages` so
apt's prebuilt `RPi.GPIO` stays importable.

> **Never commit a real password.** This repository is public. Pass
> `PI_PASSWORD` in the environment, or set `PI_SSH_PUBKEY` and use a key.

## Using it for another instrument

Copy `pi-image/` and write a new `pi-app.env`. `build.sh`, `cscript.sh` and
the CI workflow are project-agnostic; only the manifest changes.

## The isolated link

`eth0` gets a static address with **no gateway and no DNS**, plus
`never-default=true` and IPv6 disabled. Without a default route on that
interface the Pi cannot reach, or be reached from, the lab LAN — only hosts
plugged into the same switch.

The controller PC needs a static address on the same subnet with no gateway
(e.g. `192.168.10.2/24`). Leave its normal Wi-Fi/LAN adapter alone so it
keeps its own default route and stays online.

## How it works

`build.sh` downloads the official Raspberry Pi OS Lite image, renders the
service unit and NetworkManager profile from the manifest, and hands the lot
to `sdm`, which runs [`cscript.sh`](cscript.sh) in three hooks:

- **phase 0** — on the host, image mounted at `$SDMPT`. Copies the repo, the
  service unit and the network profile in.
- **phase 1** — inside the image under `nspawn`. Installs `uv`, builds the
  This hook is deliberately empty because sdm has not created the user or
  installed apt packages yet.
- **post-install** runs inside the image after sdm's plugins. It installs
  `uv`, performs `uv sync --frozen`, verifies the imports, and enables the
  service and SSH.

Then the image is compressed, decompressed again, mounted, and audited before
publication. CI checks the real filesystem, packages, venv, enabled services,
boot layout and the no-gateway/no-DNS static network profile.

## Limits

- Linux only. `sdm` mounts and chroots into the image.
- Needs `qemu-user-static` binfmt for aarch64 when building on x86.
- The venv is built under emulation, so `RPi.GPIO` is checked by spec rather
  than imported — it raises on non-Pi hardware by design.
- Updating a deployed Pi means either re-flashing or copying files over SSH.
  SSH is enabled precisely so re-flashing is not the only option.
