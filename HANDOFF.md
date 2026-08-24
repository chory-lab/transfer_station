# Transfer Station — session handoff, 24 Aug 2026

Provisioning a Raspberry Pi 4B to run the stepper-rail server on an isolated
ethernet segment. **Stage A now works on real hardware. Stage B does not run,
and nobody has seen it fail** — that is the open question.

| | |
|---|---|
| Branch | `main`, plus `sdm-image-builder` (not merged) |
| Hardware | Raspberry Pi 4 Model B |
| Target | `http://192.168.10.1:5000`, `ssh chorylab@192.168.10.1` |
| Bundle | published, pinned to Trixie |

---

## Start here

The Pi is on the bench with a monitor. It boots fine, stage A completed, and
there is **no `provision.log` anywhere** — so stage B either never ran or died
before it could write one. Two commands at the Pi console settle it:

```bash
# why didn't stage B run?
systemctl status transfer-station-provision
journalctl -u transfer-station-provision --no-pager

# run it by hand, output straight to screen
sudo /usr/local/sbin/transfer-station-provision
```

The last line is the fast path: it runs stage B in the foreground, so the log
file is irrelevant. If it completes, the Pi reboots onto the static address
and the job is done.

---

## What the instrument is

A NEMA stepper on a linear rail, driven through an A4988 from a Pi 4B.
`api_step_motor.py` serves a Flask UI whose buttons jog the rail; `A4988.py`
does the stepping. Redis backs flask-caching, which is how the stop button
reaches a move already in progress.

The Pi must sit on an ethernet segment reachable from a controller PC over a
switch, but **not** from the lab LAN. That means one static address with no
gateway and no DNS — without a default route on that interface it cannot
bridge the two networks.

`api_step_motor.py` hardcodes `/home/chorylab/transfer_station/templates`, so
the account name and install path are load-bearing.

---

## Where it stands

"Proven" means observed working on hardware, not "the tests pass".

| Link in the chain | State | Evidence |
|---|---|---|
| Card builds from one command | proven | built on the lab PC |
| Firmware reads `cmdline.txt` | proven | stage A ran on hardware |
| `systemd.run=` fires stage A | proven | `firstrun.log` on the card |
| Account, hostname, SSH, repo unpack | proven | same log |
| Reboot into stage B | unclear | Pi reboots, but no stage B log |
| Stage B installs deps | unproven | works in CI, never on hardware |
| Static IP applied to a real NIC | unproven | Pi is not at `.1` yet |
| Server reachable over the switch | unproven | blocked on the above |
| Motor moves at the new step rate | unproven | needs the rail |

Everything above the break was broken this morning and is fixed. One bug
caused all of it — see "the boot-path bug" below.

---

## Open threads

### BLOCKING — stage B leaves no trace

No `provision.log` on the card, and the Pi boots normally. Two candidates;
the console commands above distinguish them.

**Candidate 1, now fixed.** `provision.sh` sourced its config *before*
setting up logging, so under `set -euo pipefail` a missing
`/usr/local/share/transfer-station-config.env` killed it with no output
anywhere. Fixed in `7fc0209`. But **the card on the bench carries the old
copy**, so re-flash or copy the new `provision.sh` across before concluding
anything from its behaviour.

**Candidate 2, unchecked.** The unit never ran at all — `ConditionPathExists`
unmet, or stuck behind `network-online.target` / `cloud-final.service`, which
it is ordered after. `systemctl status` says which.

### UNKNOWN — does that card carry the offline bundle?

Nobody checked. `ls /boot/firmware/transfer-station/` answers it. If
`bundle/` is present, stage B was never waiting on internet and the network
theory is dead. If absent, re-running the one-liner now stages it — that gap
was fixed in `0c79017`.

### CHECK FIRST — controller PC addressing

The switch has no DHCP. For the PC to reach `192.168.10.1`, its NIC on that
switch needs a static address in the same subnet (e.g. `192.168.10.2/24`, no
gateway). Reported as already configured; worth one `ipconfig`, since it
fails silently.

### RESOLVED — the boot-path bug that wasted a day

Real pi-gen `issue.txt` carries **no codename** — only a build date and the
pi-gen commit. Release detection matched `bookworm|trixie|forky`, which never
matches a real card, so every image got the pre-Bookworm `/boot` path and
`systemd.run=` pointed at a file that does not exist. Stage A could never run.

The test fixtures had the codename baked in, so the suite *confirmed* the bug
rather than catching it. Detection now keys off the build date against
Bookworm's release date, in all four places it appears.

---

## The other direction — branch `sdm-image-builder`

Late in the session the conclusion was that provisioning on first boot is the
wrong shape. Every problem hit today — boot-path detection, Windows volume
discovery, CRLF mangling the shebang, a clock with no RTC breaking apt, a
23 MB bundle to avoid needing internet — exists **only** because work was
deferred to the device.

`pi-image/` on that branch bakes everything at build time using
[sdm](https://github.com/gitbls/sdm), producing a `.img.xz` you flash and
switch on. No two-stage boot, no `systemd.run=` hook, no bundle.
`pi-app.env` is the whole per-project interface, so **syringe_pump** would
need only its own copy of that file.

Status: the manifest lint job passes, the image build fails. First failure was
`--timezone`, which is not an sdm switch — removed, timezone now set in the
phase script instead. Expect one or two more of those.

Nothing on `main` was touched, deliberately. The bench card works and should
keep working until an sdm-built image boots a real Pi.

---

## CI

GitHub Actions was **disabled** on this repo until today, so any run predating
that does not exist.

| Job | Branch | State |
|---|---|---|
| static analysis | main | fixed, rerunning |
| flash pipeline (linux) | main | green |
| flash pipeline (windows) | main | green |
| provisioning on real Raspberry Pi OS (chroot) | main | green |
| offline dependency bundle | main | green, published |
| manifest and scripts | sdm-image-builder | green |
| build the image | sdm-image-builder | **failing** |

The bundle is a release asset at
`releases/latest/download/offline-bundle.tar.gz` — 23 MB, 7 debs, 11 wheels,
pinned to the Trixie image its `.debs` came from. A mismatched release is
refused rather than half-installed.

`PI_PASSWORD` is **not** set as a repository secret. Until it is, CI-built
images bake in `changeme`.

---

## Things that will bite you

- **Tests can confirm a bug.** The fixtures encoded the same wrong assumption
  as the code. Check a fixture against the real artifact before trusting a
  green suite.
- **`grep -P` is not universal.** A control-character check using it silently
  passed a file full of control characters — a failing `-P` with stderr
  redirected is indistinguishable from "no matches". Detectors now self-test
  against known-bad input first.
- **Escape sequences get mangled through editing layers.**
  `provisioning\flash.ps1` became `provisioning<FF>lash.ps1`;
  `.\bootstrap.ps1` in the README became `.<BS>ootstrap.ps1`. Both invisible
  in a diff, both shipped. `test_no_control_chars.sh` guards this now.
- **`Get-Volume` lies about `FileSystem`.** It returns empty for perfectly
  good partitions, so filtering on `FAT32` hid a correctly flashed card. Test
  for `cmdline.txt` instead. Windows also sometimes assigns no drive letter at
  all.
- **A Pi has no RTC.** With no network it booted 68 days behind, which makes
  apt reject repositories as "not valid yet". The flashers now stamp the build
  time and stage A advances the clock.
- **Both stage logs live on the FAT partition** (`transfer-station/*.log`),
  readable from any machine. Fastest diagnostic when the Pi is uncooperative.
  `.prev` copies survive a re-flash.

---

*State above was verified against the repo and CI at the end of the session,
not recalled. `main` at `7fc0209` plus a shellcheck fix.*
