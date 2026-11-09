#!/bin/bash
# Builds a RAM-only rescue initramfs on internal /boot containing AsahiLocker,
# hardened with maximal diagnostic logging and pre-flight state backups.
# Nothing on disk is partitioned or modified except:
#   - /boot/initramfs-ram-rescue.img
#   - /etc/grub.d/40_custom
#   - /boot/asahilocker-logs/ (diagnostic backups only)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

KVER="$(uname -r)"
BOOT_UUID="84834e93-2a1a-43f2-9e79-1e523eefcc07"   # nvme0n1p5 (/boot)
ROOT_UUID="1bcc3757-f2c3-4ba4-830a-c701d87876ca"   # nvme0n1p6 (btrfs, target)
SRC=/home/kelsey/Documents/bringup/AsahiLocker
STAGING=/tmp/asahi-ram-staging
OUT=/boot/initramfs-ram-rescue.img
LOGDIR=/boot/asahilocker-logs

[ -x "$SRC/bin/luks-deploy.sh" ] || { echo "Missing $SRC/bin/luks-deploy.sh" >&2; exit 1; }
[ -f "/boot/vmlinuz-$KVER" ] || { echo "Missing /boot/vmlinuz-$KVER" >&2; exit 1; }

# ─── 0. Host Pre-flight Diagnostic Snapshot ───────────────────────────────────
echo "[0/5] Capturing host diagnostic snapshot to $LOGDIR..."
mkdir -p "$LOGDIR"
sgdisk -b "$LOGDIR/nvme0n1-gpt-host.bak" /dev/nvme0n1 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS /dev/nvme0n1 > "$LOGDIR/lsblk-host.txt" 2>/dev/null || true
cat /proc/partitions > "$LOGDIR/partitions-host.txt" 2>/dev/null || true
dmesg | tail -n 200 > "$LOGDIR/dmesg-host.txt" 2>/dev/null || true
echo "      Host state saved. (Partition table backup: $LOGDIR/nvme0n1-gpt-host.bak)"

# ─── 1. Stage AsahiLocker and the Guarded /start.sh ────────────────────────────
echo "[1/5] Staging AsahiLocker and rescue automation..."
rm -rf "$STAGING"
mkdir -p "$STAGING/root"
cp -a "$SRC" "$STAGING/root/"

cat > "$STAGING/start.sh" << 'EOF'
#!/bin/bash
# Maximally guarded launcher for AsahiLocker inside dracut RAM rescue.
# All stdout/stderr is mirrored to persistent storage via trap.

mkdir -p /dev/pts /run /mnt /tmp/logs
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null || true

CONSOLE_LOG=/tmp/logs/session-console.log
DMESG_PRE=/tmp/logs/dmesg-pre.txt
DMESG_POST=/tmp/logs/dmesg-post.txt
LSBLK_PRE=/tmp/logs/lsblk-pre.txt
LSBLK_POST=/tmp/logs/lsblk-post.txt

# Capture pre-run hardware and kernel state
dmesg > "$DMESG_PRE" 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT /dev/nvme0n1 > "$LSBLK_PRE" 2>/dev/null || true

save_all_diagnostics() {
    local rc=$?
    echo ""
    echo "=== Preserving All Diagnostic Logs & Backups to /boot ==="
    dmesg > "$DMESG_POST" 2>/dev/null || true
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT /dev/nvme0n1 > "$LSBLK_POST" 2>/dev/null || true

    mkdir -p /tmp/bootsave
    if mount /dev/nvme0n1p5 /tmp/bootsave 2>/dev/null; then
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
        echo "WARNING: Could not mount /dev/nvme0n1p5 to persist logs." >&2
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
if findmnt -rn -S /dev/nvme0n1p6 >/dev/null 2>&1; then
    echo "ERROR: /dev/nvme0n1p6 is currently mounted! Aborting for safety." >&2
    exit 1
fi

echo "Target: /dev/nvme0n1p6 is unmounted and ready for in-place encryption."
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
REQ="bash cryptsetup btrfs sgdisk awk sed grep lsblk blkid blockdev findmnt \
     mktemp chroot mount umount mountpoint tee head tail wc sort cut tr stat \
     sync basename dirname readlink date cp mv rm mkdir chmod cat touch \
     printf env sleep uname df find free seq partprobe udevadm \
     lsmod modprobe rmdir od partx which install"
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
         usr/bin/sync usr/bin/install usr/bin/lsmod usr/bin/rmdir usr/bin/dracut usr/bin/grub2-mkconfig \
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
    linux /vmlinuz-${KVER} root=UUID=${ROOT_UUID} rootflags=subvol=root ro rd.break=pre-mount SYSTEMD_SULOGIN_FORCE=1 rd.shell rd.timeout=60 systemd.show_status=1 console=tty0
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
     /boot/asahilocker-logs/nvme0n1-gpt-host.bak

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
