# Captured provisioning logs

Real logs pulled off a card's FAT boot partition, kept here so the two stages
can be compared against a known-good run. Both stages write their log to
`transfer-station/` on that partition, which mounts on any machine — pull the
card and read it there when a boot goes wrong.

## `firstrun-2026-08-24.log`

Stage A, complete and successful.

| | |
|---|---|
| Image | Raspberry Pi OS 64-bit **Desktop**, `Raspberry Pi reference 2026-06-18` (pi-gen stage4) |
| Customised in Imager | yes — cloud-init `user-data` on the card (user `chorylab`, hostname `transferstation`, SSH on) |
| Host | Windows, card flashed with `flash.ps1` |

Things in it that look alarming but are not:

- **`usermod: no changes`** — the account already existed. Stage A runs before
  cloud-init, but this card had been booted once already, so cloud-init had
  created `chorylab` on that earlier boot. Stage A is idempotent here.
- **`tar: … time stamp … is 5860264 s in the future`**, once per repo entry —
  the Pi has no RTC and stage A runs before any network, so its clock is still
  at the image build date and every file in `repo.tar.gz` looks
  future-dated. Extraction succeeds regardless.

Stage A then self-disarmed correctly: `systemd.run=` stripped back out of
`cmdline.txt`, `userconf.txt` deleted, `firstrun.sh` and `repo.tar.gz` removed
from the payload directory.

## No `provision.log` alongside it

Stage B left no log on this card. The card was flashed from a `provision.sh`
that predates `1d4b399`, which added `trap 'sync' EXIT` — without it the log
sits in the page cache and the `systemctl reboot` at the end of stage B
discards it. Cards flashed after that commit should keep their stage B log.
