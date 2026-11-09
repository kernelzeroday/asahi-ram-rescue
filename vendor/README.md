# Vendored: AsahiLocker

`AsahiLocker/` is a copy of [doug445/AsahiLocker](https://github.com/doug445/AsahiLocker)
(MIT, © William MacKinnon; see `AsahiLocker/LICENSE`) with one patch applied.

| | |
|---|---|
| Upstream commit | `93351ce93500d34fc79e79ed4c6ccba17da87fa7` (docs: Step 3 recovery downloads AsahiLocker onto the stick (#3)) |
| Patch | `patches/0001-luks-deploy-run-cleanly-from-a-RAM-only-dracut-rescue.patch` |
| Removed | `.github/` (upstream CI and rulesets; they do nothing in a subdirectory) |

The patch changes only `bin/luks-deploy.sh`, so it runs from a dracut RAM
rescue where `/` is `rootfs`:

- `lsblk -dno PKNAME` on `rootfs` exits 32. Under `set -euo pipefail` that
  killed the script without a message; it now ends with `|| true`.
- `rootfs` counts as a live environment, like `tmpfs` and `overlay`.
- `cryptsetup reencrypt` and `luksAddKey` get `--force-password`. The
  cracklib dictionary isn't in the image, and without it pwquality rejects
  every passphrase. **cryptsetup no longer refuses weak passphrases, so
  choose a strong one.**

## Updating

```bash
git clone https://github.com/doug445/AsahiLocker /tmp/al
git -C /tmp/al am "$PWD/vendor/patches/"*.patch
rm -rf vendor/AsahiLocker
git -C /tmp/al archive --prefix=AsahiLocker/ HEAD | tar -x -C vendor
rm -rf vendor/AsahiLocker/.github
```

Then update the commit above, and test on a real machine before tagging.
