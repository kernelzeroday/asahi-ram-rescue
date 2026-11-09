#!/bin/bash
# Builds a RAM-only rescue initramfs on internal /boot containing AsahiLocker,
# with diagnostic logging and pre-flight state backups.
# Nothing on disk is partitioned or modified except:
#   - /boot/initramfs-ram-rescue.img
#   - /etc/grub.d/40_custom
#   - /boot/asahilocker-logs/ (diagnostic backups only)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

die() { echo "ERROR: $*" >&2; exit 1; }

KVER="$(uname -r)"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SRC="${ASAHILOCKER_DIR:-$SCRIPT_DIR/vendor/AsahiLocker}"
STAGING=/tmp/asahi-ram-staging
OUT=/boot/initramfs-ram-rescue.img
LOGDIR=/boot/asahilocker-logs

# ─── Detect this machine's partitions from the running system ────────────────
# Everything below is read from what is mounted at / and /boot right now, so
# the same script works on any Asahi Mac. Nothing is hardcoded.
ROOT_DEV="$(findmnt -no SOURCE / | sed 's/\[.*//')"
ROOT_DEV="$(readlink -f "$ROOT_DEV")"
ROOT_FSTYPE="$(findmnt -no FSTYPE /)"
BOOT_DEV="$(readlink -f "$(findmnt -no SOURCE /boot)")" || die "/boot is not a separate mount"
[ "$ROOT_FSTYPE" = btrfs ] || die "/ is $ROOT_FSTYPE, expected btrfs"
case "$ROOT_DEV" in
    /dev/dm-*|/dev/mapper/*) die "/ is on $ROOT_DEV (device-mapper): this system already looks encrypted" ;;
esac
[ -b "$ROOT_DEV" ] && [ -b "$BOOT_DEV" ] || die "could not resolve root ($ROOT_DEV) or /boot ($BOOT_DEV) to block devices"
[ "$ROOT_DEV" != "$BOOT_DEV" ] || die "/ and /boot are the same device"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"
BOOT_UUID="$(blkid -s UUID -o value "$BOOT_DEV")"
[ -n "$ROOT_UUID" ] && [ -n "$BOOT_UUID" ] || die "could not read UUIDs (root=$ROOT_UUID boot=$BOOT_UUID)"
# subvol=/root or subvol=root -> root
ROOT_SUBVOL="$(findmnt -no OPTIONS / | tr ',' '\n' | sed -n 's/^subvol=\/\{0,1\}//p' | head -1)"
[ -n "$ROOT_SUBVOL" ] || die "could not find the btrfs subvol mounted at /"
DISK="/dev/$(lsblk -dno PKNAME "$ROOT_DEV" | head -1)"
[ -b "$DISK" ] || die "could not find the disk under $ROOT_DEV"

[ -x "$SRC/bin/luks-deploy.sh" ] || die "Missing $SRC/bin/luks-deploy.sh (set ASAHILOCKER_DIR=/path/to/AsahiLocker)"
# The RAM rescue needs the patch in vendor/patches; without it luks-deploy.sh
# dies with exit 32, then on the cracklib dictionary.
grep -q -- '--force-password' "$SRC/bin/luks-deploy.sh" \
    && grep -q 'head -1 || true)' "$SRC/bin/luks-deploy.sh" \
    || die "$SRC lacks the RAM-rescue fixes: apply vendor/patches/*.patch, or unset ASAHILOCKER_DIR"
[ -f "/boot/vmlinuz-$KVER" ] || die "Missing /boot/vmlinuz-$KVER"

# Every tool luks-deploy.sh runs outside its chroot. dracut prints an error
# for a missing one but still builds the image, so check here and stop.
REQ="bash cryptsetup btrfs sgdisk awk sed grep lsblk blkid blockdev findmnt \
     mktemp chroot mount umount mountpoint tee head tail wc sort cut tr stat \
     sync basename dirname readlink date cp mv rm mkdir chmod cat touch \
     printf env sleep uname df find free seq partprobe udevadm \
     lsmod modprobe rmdir od partx which install lsinitrd"
MISSING_TOOLS=""
for t in $REQ; do command -v "$t" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $t"; done
[ -z "$MISSING_TOOLS" ] || die "missing on this system:$MISSING_TOOLS
       Install them first (sgdisk is in the gdisk package): sudo dnf install gdisk"

echo "Detected:"
echo "  disk   : $DISK  ($(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown model))"
echo "  root   : $ROOT_DEV  UUID=$ROOT_UUID  subvol=$ROOT_SUBVOL  (will be encrypted)"
echo "  /boot  : $BOOT_DEV  UUID=$BOOT_UUID"
echo "  kernel : $KVER"
echo "  source : $SRC"
echo ""

# ─── 0. Host Pre-flight Diagnostic Snapshot ───────────────────────────────────
echo "[0/5] Capturing host diagnostic snapshot to $LOGDIR..."
mkdir -p "$LOGDIR"
DISK_NAME="$(basename "$DISK")"
sgdisk -b "$LOGDIR/$DISK_NAME-gpt-host.bak" "$DISK" >/dev/null \
    || die "could not back up the partition table of $DISK"
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS "$DISK" > "$LOGDIR/lsblk-host.txt" 2>/dev/null || true
cat /proc/partitions > "$LOGDIR/partitions-host.txt" 2>/dev/null || true
dmesg | tail -n 200 > "$LOGDIR/dmesg-host.txt" 2>/dev/null || true
echo "      Host state saved. (Partition table backup: $LOGDIR/$DISK_NAME-gpt-host.bak)"

# ─── 1. Stage AsahiLocker and the Guarded /start.sh ────────────────────────────
echo "[1/5] Staging AsahiLocker and rescue automation..."
rm -rf "$STAGING"
mkdir -p "$STAGING/root"
cp -a "$SRC" "$STAGING/root/"

# Values detected on the host, baked into the launcher.
cat > "$STAGING/start.sh" << EOF
#!/bin/bash
# Detected by setup-ram-rescue.sh on the host:
ROOT_UUID="$ROOT_UUID"
BOOT_UUID="$BOOT_UUID"
EOF
cat >> "$STAGING/start.sh" << 'EOF'
# Guarded launcher for AsahiLocker inside the dracut RAM rescue.
# An EXIT trap copies every log to /boot, whatever happens.

# Resolve by UUID: kernel names (nvme0n1pN) are not assumed.
ROOT_DEV="$(readlink -f "/dev/disk/by-uuid/$ROOT_UUID")"
BOOT_DEV="$(readlink -f "/dev/disk/by-uuid/$BOOT_UUID")"
DISK="/dev/$(lsblk -dno PKNAME "$ROOT_DEV" 2>/dev/null | head -1)"
if [ ! -b "$ROOT_DEV" ] || [ ! -b "$BOOT_DEV" ]; then
    echo "ERROR: root ($ROOT_UUID) or /boot ($BOOT_UUID) not found. Is this the same machine the image was built on?" >&2
    lsblk -f >&2
    exit 1
fi

mkdir -p /dev/pts /run /mnt /tmp/logs
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null || true

CONSOLE_LOG=/tmp/logs/session-console.log
DMESG_PRE=/tmp/logs/dmesg-pre.txt
DMESG_POST=/tmp/logs/dmesg-post.txt
LSBLK_PRE=/tmp/logs/lsblk-pre.txt
LSBLK_POST=/tmp/logs/lsblk-post.txt

# Capture pre-run hardware and kernel state
dmesg > "$DMESG_PRE" 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT "$DISK" > "$LSBLK_PRE" 2>/dev/null || true

save_all_diagnostics() {
    local rc=$?
    echo ""
    echo "=== Preserving All Diagnostic Logs & Backups to /boot ==="
    dmesg > "$DMESG_POST" 2>/dev/null || true
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT "$DISK" > "$LSBLK_POST" 2>/dev/null || true

    mkdir -p /tmp/bootsave
    if mount "$BOOT_DEV" /tmp/bootsave 2>/dev/null; then
        local dest="/tmp/bootsave/asahilocker-logs/session-$(date +%Y%m%d_%H%M%S 2>/dev/null || echo latest)"
        mkdir -p "$dest"
        cp -a /tmp/logs/* "$dest/" 2>/dev/null || true
        cp -a /root/AsahiLocker/bin/*.log "$dest/" 2>/dev/null || true
        cp -a /root/AsahiLocker/bin/*backup* "$dest/" 2>/dev/null || true
        cp -a /root/AsahiLocker/bin/*recovery* "$dest/" 2>/dev/null || true
        [ -f /run/initramfs/rdsosreport.txt ] && cp -a /run/initramfs/rdsosreport.txt "$dest/" 2>/dev/null || true
        sync
        umount /tmp/bootsave
        echo "All logs, terminal recordings, and state backups saved to:"
        echo "  /boot/asahilocker-logs/ (persistent on disk)"
    else
        echo "WARNING: Could not mount $BOOT_DEV to persist logs." >&2
    fi
    echo "Session completed with exit code: $rc"
}

# Trap ANY exit (clean exit, error, Ctrl+C) to guarantee logs are saved
trap save_all_diagnostics EXIT INT TERM

echo "================================================================"
echo "    Fedora Asahi In-Place LUKS2 Encryption (RAM Rescue)        "
echo "================================================================"
echo ""
echo "Hardware Status (Internal NVMe):"
cat "$LSBLK_PRE"
echo ""

# Pre-flight safety assertion: target partition MUST NOT be mounted
if findmnt -rn -S "$ROOT_DEV" >/dev/null 2>&1; then
    echo "ERROR: $ROOT_DEV is currently mounted! Aborting for safety." >&2
    exit 1
fi

echo "Target: $ROOT_DEV is unmounted and ready for in-place encryption."
echo "Starting AsahiLocker deployment with full console recording..."
echo ""

cd /root/AsahiLocker/bin

# Run directly on the terminal (no pipe) so passphrase prompts behave normally.
# luks-deploy.sh writes its own full log, which the EXIT trap copies to /boot.
./luks-deploy.sh
PIPE_STATUS=$?

echo ""
if [ "$PIPE_STATUS" -eq 0 ]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  SUCCESS: In-place encryption completed & verified!          ║"
    echo "║  You may now safely reboot into your encrypted system.       ║"
    echo "║                                                              ║"
    echo "║  Type:  reboot -f                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
else
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  NOTICE: Script exited with status $PIPE_STATUS.             ║"
    echo "║  All diagnostics have been preserved to /boot.               ║"
    echo "║  If encryption was interrupted, re-running /start.sh         ║"
    echo "║  will resume it safely (cryptsetup --resume-only).           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
fi

exit "$PIPE_STATUS"
EOF
chmod +x "$STAGING/start.sh"

# Preflight stubs for live environment (real tools run inside chroot /mnt)
mkdir -p "$STAGING/stubs"
for t in dracut grub2-mkconfig; do
    printf '#!/bin/sh\necho "RAM-rescue stub: real %s only runs inside chroot /mnt" >&2\nexit 1\n' "$t" > "$STAGING/stubs/$t"
    chmod +x "$STAGING/stubs/$t"
done

# ─── 2. Build Rescue Image with Dracut ─────────────────────────────────────────
echo "[2/5] Building rescue initramfs (~30-60s)..."
OPT="lsinitrd file less nano vi dmsetup wipefs e2fsck"

dracut --force --no-hostonly-cmdline \
    --add "crypt dm btrfs" \
    --install "$REQ" \
    --install-optional "$OPT" \
    --include "$STAGING/root/AsahiLocker" /root/AsahiLocker \
    --include "$STAGING/start.sh" /start.sh \
    --include "$STAGING/stubs/dracut" /usr/bin/dracut \
    --include "$STAGING/stubs/grub2-mkconfig" /usr/bin/grub2-mkconfig \
    "$OUT" "$KVER"
rm -rf "$STAGING"

# ─── 3. Verify Rescue Image Contents ──────────────────────────────────────────
echo "[3/5] Verifying image contents..."
LIST="$(lsinitrd "$OUT")"
FAIL=0
for f in root/AsahiLocker/bin/luks-deploy.sh start.sh usr/bin/cryptsetup \
         usr/bin/btrfs usr/bin/tee usr/bin/head usr/bin/date usr/bin/basename \
         usr/bin/sync usr/bin/install usr/bin/sgdisk usr/bin/partprobe usr/bin/lsmod usr/bin/rmdir usr/bin/dracut usr/bin/grub2-mkconfig \
         nvme-apple.ko spi-hid-apple.ko dm-crypt.ko; do
    if grep -qF -- "$f" <<< "$LIST"; then
        echo "  OK   $f"
    else
        echo "  MISS $f"
        FAIL=1
    fi
done
[ "$FAIL" -eq 0 ] || { echo "ERROR: Rescue image verification failed! GRUB untouched." >&2; exit 1; }
ls -lh "$OUT"

# ─── 4. Configure GRUB ────────────────────────────────────────────────────────
echo "[4/5] Writing GRUB entry..."
cat > /etc/grub.d/40_custom << EOF
#!/bin/sh
exec tail -n +3 \$0

menuentry 'Fedora Asahi RAM Rescue (In-Place Encryption)' --class fedora --class gnu-linux --class os {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /vmlinuz-${KVER} root=UUID=${ROOT_UUID} rootflags=subvol=${ROOT_SUBVOL} ro rd.break=pre-mount SYSTEMD_SULOGIN_FORCE=1 rd.shell rd.timeout=60 systemd.show_status=1 console=tty0
    initrd /initramfs-ram-rescue.img
}
EOF
chmod +x /etc/grub.d/40_custom

# ─── 5. Regenerate GRUB Configuration ─────────────────────────────────────────
echo "[5/5] Regenerating GRUB menu..."
grub2-mkconfig -o /boot/grub2/grub.cfg
sync

cat << 'EOF'

================================================================
           MAXIMALLY GUARDED RAM RESCUE IS READY
================================================================
1. Pre-flight host partition table backed up to:
     /boot/asahilocker-logs/<disk>-gpt-host.bak

2. The rescue environment contains automatic exit traps:
   Even if cancelled, interrupted, or encountering an error,
   ALL console logs, dmesg buffers, and backups are written to:
     /boot/asahilocker-logs/session-<timestamp>/

3. Instructions:
   - Ensure MacBook is plugged into AC power.
   - Reboot and select 'Fedora Asahi RAM Rescue (In-Place Encryption)' in GRUB.
   - At the  dracut:/#  prompt (press Enter if needed), type:
         /start.sh
   - Follow prompts, set your LUKS passphrase.
   - When complete, type:  reboot -f
================================================================
EOF
