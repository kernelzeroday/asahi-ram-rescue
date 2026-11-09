#!/bin/bash
set -euo pipefail

echo "=== Removing the RAM rescue entry from GRUB ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)." >&2
    exit 1
fi

# Reset 40_custom to default clean template
cat << 'EOF' > /etc/grub.d/40_custom
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.
EOF
chmod +x /etc/grub.d/40_custom

echo "Regenerating /boot/grub2/grub.cfg..."
grub2-mkconfig -o /boot/grub2/grub.cfg

sync
echo "=== Done. /etc/grub.d/40_custom is back to the Fedora default ==="
