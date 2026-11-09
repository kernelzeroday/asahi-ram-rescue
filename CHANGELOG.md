# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- AsahiLocker is vendored in `vendor/AsahiLocker` (upstream `93351ce` plus
  the RAM-rescue patch, kept in `vendor/patches/`). No separate checkout is
  needed; `ASAHILOCKER_DIR` still overrides it.

### Changed
- Moved into its own repository. The README now explains how to point
  `ASAHILOCKER_DIR` at AsahiLocker when it isn't a sibling directory.
- README lists both tested Macs: the MacBook Air M1 (0.1.0) and the MacBook
  Pro 13" M1 (0.2.0).

## [0.2.0] - 2026-11-08

Tested: a MacBook Pro 13" M1 (2020) was encrypted in place by a full
unattended run. luks-deploy.sh passed all 8 steps and its 12-point
verification gate, then the machine booted encrypted.

### Changed
- Partitions, UUIDs, btrfs subvolume and disk are read from the running
  system rather than hardcoded. `/start.sh` resolves them by UUID inside the
  rescue.
- AsahiLocker is found at `../AsahiLocker`, or set `ASAHILOCKER_DIR`.

### Added
- Refuses to run if `/` is already encrypted, isn't btrfs, or `/boot` isn't
  separate.
- Refuses to run if the AsahiLocker checkout lacks the RAM-rescue fixes.
- Checks every required tool before starting. dracut builds the image even
  when a tool is missing, which is how `sgdisk` went missing on the MacBook
  Pro.
- `sgdisk` and `partprobe` are in the image verification.

### Fixed
- A failed partition-table backup in step 0 now stops the script. Before,
  `|| true` hid the failure.

## [0.1.0] - 2026-11-08

First release. Encrypted a MacBook Air M1 in place, from an earlier draft;
see the tag message for details.
