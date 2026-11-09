# asahi-ram-rescue

Encrypt a Fedora Asahi root partition in place with
[AsahiLocker](https://github.com/doug445/AsahiLocker), **without a USB stick**.

On Apple Silicon, U-Boot often can't boot from USB. This tool builds a dracut
initramfs that runs entirely from RAM, with AsahiLocker inside it, and adds a
GRUB entry for it. Booting that entry stops at `rd.break=pre-mount`: the
kernel and tools are in memory and the root partition is never mounted, which
is what `cryptsetup reencrypt --encrypt` needs.

Tested on a MacBook Air M1 (j313), Fedora Asahi, kernel
7.2.12-402.asahi.fc45.aarch64+16k, cryptsetup 2.8.8, on 2026-11-08.

## Files

| File | What it does |
|---|---|
| `setup-ram-rescue.sh` | Builds `/boot/initramfs-ram-rescue.img`, checks its contents, writes the GRUB entry to `/etc/grub.d/40_custom` and regenerates `grub.cfg`. Nothing else on disk changes, apart from diagnostic snapshots in `/boot/asahilocker-logs/`. |
| `clean-grub.sh` | Resets `/etc/grub.d/40_custom` to Fedora's empty template and regenerates `grub.cfg`. This removes the rescue entry. |

## Before you start

Run it **on the Mac you're encrypting**, booted normally. It reads the root
partition, `/boot`, the btrfs subvolume and the disk from whatever is mounted
right now, and prints them before building. Nothing machine-specific is
hardcoded. Check the printed `root` line against `lsblk -f`: that is the
partition that will be encrypted.

It refuses to run if `/` is already on device-mapper (already encrypted), if
`/` isn't btrfs, or if `/boot` isn't a separate partition.

Inside the rescue, `/start.sh` finds the partitions by UUID, not by kernel
name. The image is tied to the machine it was built on, so don't copy it to
another Mac.

AsahiLocker has to sit next to this repo (`../AsahiLocker`), or set
`ASAHILOCKER_DIR=/path/to/AsahiLocker`, and it needs the fixes on its
`fix/ram-rescue-environment` branch. The script checks for those fixes and
stops if they're missing.

```
some-dir/
├── AsahiLocker/        (git checkout fix/ram-rescue-environment)
└── asahi-ram-rescue/
```

## Use

```bash
sudo ./setup-ram-rescue.sh
sudo grub2-editenv - unset menu_auto_hide
sudo grub2-reboot "Fedora Asahi RAM Rescue (In-Place Encryption)"
sudo reboot
```

Fedora hides the GRUB menu by default. `grub2-reboot` boots the rescue
entry once, without needing the menu.

At `dracut:/#` (press Enter if there's no prompt), run `/start.sh`. It runs
`luks-deploy.sh` and, whatever the outcome, copies its log, dmesg, lsblk and
`rdsosreport.txt` to `/boot/asahilocker-logs/session-<timestamp>/`. If
encryption is interrupted, running `/start.sh` again resumes it.

When you're done:

```bash
sudo ./clean-grub.sh
sudo rm /boot/initramfs-ram-rescue.img
```

## Kernel command line

```
root=UUID=<btrfs> rootflags=subvol=root ro rd.break=pre-mount
SYSTEMD_SULOGIN_FORCE=1 rd.shell rd.timeout=60 systemd.show_status=1 console=tty0
```

- `root=` is required. Without it dracut stops with "Empty root= argument".
- `SYSTEMD_SULOGIN_FORCE=1` opens the shell even though Fedora locks root.
- `rd.timeout=60` sends a hang to the shell after 60 s, instead of waiting
  forever.

## What went wrong along the way

Each problem below stopped a real run. All of them are fixed here or on the
AsahiLocker branch.

1. **luks-deploy's tool check wants `dracut` and `grub2-mkconfig`.** It
   only runs them inside `chroot /mnt`. The image ships placeholder scripts
   that pass the check and exit with an error if they're ever called.
2. **`lsblk` exit 32** (AsahiLocker). In RAM, `/` is `rootfs`, not a block
   device. `lsblk` exits 32 and `set -euo pipefail` killed the script
   without a message.
3. **cracklib dictionary missing** (AsahiLocker). cryptsetup's password
   quality check couldn't load `pw_dict` and rejected every passphrase.
   Fixed with `--force-password`, so cryptsetup no longer rejects weak
   passphrases. Pick a strong one.
4. **`install: command not found`** (exit 127), in step 5 of 8, after
   encryption had already finished. Steps 6–8 (crypttab, fstab, initramfs,
   BLS) didn't run and had to be done by hand. `install` is now in the image,
   and every command luks-deploy runs outside the chroot was checked against
   the image's file list.
5. **The verify step reported false "MISS" lines.** `echo "$LIST" | grep -q`
   under `pipefail` fails when grep exits early. It now uses a here-string.

Also: don't send `luks-deploy.sh` output through `| tee` from the launcher.
Its prompts need the terminal directly, and it writes its own log anyway.

## Encrypting a running system: the config steps 6–8 would have done

Kept here in case the deploy dies after encryption again.

- `/etc/crypttab`: `fedora_crypt UUID=<luks-uuid> none luks,discard`
- `/etc/fstab`: `/` and `/home` from `/dev/mapper/fedora_crypt`
- `/etc/dracut.conf.d/99-luks.conf`:
  `add_dracutmodules+=" crypt dm btrfs "`, `add_drivers+=" dm-crypt "`
- `/etc/kernel/cmdline` and every BLS entry (`grubby --update-kernel=ALL
  --args=...`): `rd.luks.uuid=<luks-uuid> rd.luks.name=<luks-uuid>=fedora_crypt`
- `dracut --regenerate-all --force`, `grub2-mkconfig -o /boot/grub2/grub.cfg`,
  `restorecon -Rv /etc /boot`
