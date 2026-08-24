#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sdm custom phase script.
#
# Invoked by sdm as:  cscript.sh <phase>   where phase is 0 | 1 | post-install
#
#   phase 0        runs on the HOST with the image mounted at $SDMPT. Both
#                  filesystems are visible, so this is where files are copied in.
#   phase 1        runs INSIDE the image under nspawn. The host filesystem is
#                  gone. This is where anything that must execute against the
#                  image belongs -- apt, uv, systemctl.
#   post-install   also inside the image, after sdm's own plugins have run.
#
# Everything project-specific comes from pi-app.env, passed through by
# build.sh as environment variables.
# ---------------------------------------------------------------------------
set -euo pipefail

phase="${1:-}"

# sdm copies this script INTO the image and runs it from there, so the
# manifest is not sitting beside it at run time. Phase 0 runs on the host,
# where build.sh's exports are visible, so it takes the staging directory
# from the environment; phase 1 reads the copy phase 0 planted in the image.
CONF_IMG=/etc/pi-image-app.env

case "$phase" in

0)
    echo "cscript phase 0: staging files into the image"
    : "${PI_IMAGE_BUILD:?phase 0 needs PI_IMAGE_BUILD, exported by build.sh}"
    CONF_HOST="$PI_IMAGE_BUILD/pi-app.env"
    # shellcheck disable=SC1090
    . "$CONF_HOST"

    # Carry the manifest into the image so phase 1 can read it.
    install -m 600 "$CONF_HOST" "$SDMPT$CONF_IMG"

    install -d "$SDMPT$REPO_DEST"
    tar -C "$PI_IMAGE_REPO" \
        --exclude=./.git --exclude=./foobar --exclude=./pi-image \
        --exclude=./provisioning "--exclude=./3D Files" \
        --exclude=__pycache__ --exclude='*.pyc' --exclude=./dump.rdb \
        -cf - . | tar -C "$SDMPT$REPO_DEST" -xf -

    # The isolated profile. sdm's network plugin can also place this, but
    # writing it here keeps one source of truth for its contents.
    install -d -m 700 "$SDMPT/etc/NetworkManager/system-connections"
    install -m 600 "$PI_IMAGE_BUILD/eth0-isolated.nmconnection" \
        "$SDMPT/etc/NetworkManager/system-connections/${ETH_IFACE}-isolated.nmconnection"

    install -d -m 755 "$SDMPT/etc/systemd/system"
    install -m 644 "$PI_IMAGE_BUILD/${APP_NAME}.service" \
        "$SDMPT/etc/systemd/system/${APP_NAME}.service"
    ;;

1)
    echo "cscript phase 1: building the runtime inside the image"
    # shellcheck disable=SC1091
    . "$CONF_IMG"
    VENV="${REPO_DEST}/.venv"

    # uv, from the installer. This runs at BUILD time, so the Pi itself never
    # needs a network -- which is the entire point of baking the image.
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh \
            | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
    fi
    uv --version

    # System interpreter with system site-packages, so apt's prebuilt
    # RPi.GPIO stays importable. A uv-managed standalone Python would hide it.
    rm -rf "$VENV"
    uv venv --python /usr/bin/python3 --system-site-packages "$VENV"
    uv pip install --python "$VENV/bin/python" -r "${REPO_DEST}/requirements.txt"

    # Verify by spec, not import: RPi.GPIO raises on non-Pi hardware, and this
    # is running under emulation on a build machine.
    "$VENV/bin/python" - <<'PYCHECK'
import importlib.util as u
import flask, flask_caching, redis          # noqa: F401
assert u.find_spec("RPi.GPIO"), "RPi.GPIO is not visible in the venv"
print("deps ok")
PYCHECK

    # The repo landed in phase 0, before sdm's user plugin created the
    # account, so nothing under the home directory is owned by anyone yet.
    chown -R "${PI_USER}:${PI_USER}" "/home/${PI_USER}"

    # Authorized keys have to wait for the account to exist, which is why
    # this is here and not in phase 0 beside the other file staging.
    if [ -n "${PI_SSH_PUBKEY:-}" ]; then
        install -d -m 700 -o "$PI_USER" -g "$PI_USER" "/home/${PI_USER}/.ssh"
        printf '%s\n' "$PI_SSH_PUBKEY" > "/home/${PI_USER}/.ssh/authorized_keys"
        chown "${PI_USER}:${PI_USER}" "/home/${PI_USER}/.ssh/authorized_keys"
        chmod 600 "/home/${PI_USER}/.ssh/authorized_keys"
    fi

    # sdm has no --timezone switch; set it here where it is unambiguous.
    if [ -n "${TIMEZONE:-}" ] && [ -e "/usr/share/zoneinfo/${TIMEZONE}" ]; then
        ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
        echo "${TIMEZONE}" > /etc/timezone
    fi

    systemctl enable "${APP_NAME}.service"
    systemctl enable ssh

    # NM auto-creates a DHCP profile for a wired interface; ours must win.
    find /etc/NetworkManager/system-connections -name 'Wired connection*' -delete 2>/dev/null || true

    rm -f "$CONF_IMG"
    ;;

post-install)
    echo "cscript post-install: nothing to do"
    ;;
esac
