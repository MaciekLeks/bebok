#!/bin/bash

# Mount disk.img with GPT and ext4 partition
#
# Usage:
#   scripts/mount_disk.sh <mount_point> [source_dir]
#
#   mount_point         Directory where to mount the partition
#   source_dir         Optional. Directory containing disk.img (defaults to .zig-out)
#
# Example:
#   scripts/mount_disk.sh /mnt/rootfs              # Mounts .zig-out/disk.img
#   scripts/mount_disk.sh /mnt/rootfs /path/prefix # Mounts /path/prefix/disk.img
#
# Requirements:
#   - Root privileges for mount operations
#   - disk.img must exist and contain GPT and ext4 partition
#   - Mount point directory must exist

set -e

if [ $# -lt 1 ]; then
  echo "Error: Mount point not specified"
  echo "Usage: $0 <mount_point> [source_dir]"
  exit 1
fi

MOUNT_POINT="$1"
SOURCE_DIR="${2:-./zig-out}"
DISK_IMG="${SOURCE_DIR}/disk.img"

# Check if mount point exists
if [ ! -d "$MOUNT_POINT" ]; then
  echo "Error: Mount point $MOUNT_POINT does not exist"
  exit 1
fi

# Check if disk image exists
if [ ! -f "$DISK_IMG" ]; then
  echo "Error: Disk image not found at $DISK_IMG"
  exit 1
fi

echo "Setting up loop device..."
LOOP_DEV=$(sudo losetup --show -fP "$DISK_IMG")

echo "Mounting partition..."
sudo mount "${LOOP_DEV}p1" "$MOUNT_POINT"

echo "Disk mounted successfully at $MOUNT_POINT"
echo "To unmount, use: sudo umount $MOUNT_POINT && sudo losetup -d $LOOP_DEV"
