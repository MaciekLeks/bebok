#!/bin/bash

# Usage:
#   ./scritps/create_disk.sh [destination_path]
#
# Arguments:
#   destination_path  Optional. Path where the disk image will be installed.
#                    If not provided, defaults to ./zig-out
#
# Example:
#   ./create_disk.sh                    # Installs to ./zig-out/disk.img
#   ./create_disk.sh /path/to/dir       # Installs to /path/to/dir/disk.img
#
# Note:
#   - Requires root privileges for losetup operations
#   - Creates directory if it doesn't exist
#   - Overwrites existing disk.img if present

set -e

DEST_DIR="${1:-./zig-out}"
TEMP_IMG="temp_disk.img"
FINAL_PATH="${DEST_DIR}/disk.img"

# Check if destination directory exists
mkdir -p "$DEST_DIR"

echo "Creating disk image..."
qemu-img create -f raw "$TEMP_IMG" 1G

echo "Creating GPT partition table..."
sgdisk --clear --new=1:2048:0 --typecode=1:8300 "$TEMP_IMG"

echo "Setting up loop device..."
LOOP_DEV=$(sudo losetup --show -fP "$TEMP_IMG")

echo "Creating ext4 filesystem..."
sudo mkfs.ext4 -F -L rootfs "${LOOP_DEV}p1"

echo "Cleaning up loop device..."
sudo losetup -d "$LOOP_DEV"

echo "Installing disk image to destination..."
mv "$TEMP_IMG" "$FINAL_PATH"

echo "Disk image created and installed successfully at $FINAL_PATH"
