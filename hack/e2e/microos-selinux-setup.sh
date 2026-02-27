#!/bin/bash

set -eux

# Enable SELinux enforcing mode if not already active.
if grep -q "selinux=1" /proc/cmdline; then
    exit 0
fi

# Install SELinux packages.
zypper -n install selinux-policy-targeted policycoreutils selinux-tools

# Relabel the filesystem now so a second reboot (/.autorelabel) is not needed.
# restorecon reads context definitions from disk and sets xattrs without
# requiring SELinux to be loaded in the kernel.
restorecon -R -e /dev -e /proc -e /run -e /sys / || true

# Configure GRUB to enable SELinux enforcing mode on the next boot,
# preserving any existing kernel parameters.
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="security=selinux selinux=1 enforcing=1 \1"/' /etc/default/grub
update-bootloader --refresh
