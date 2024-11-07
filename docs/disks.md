# Creating a disk
Disk with GPT and one ext4 partition is created in `istio-qemu` zig build step. It is created in `./build/disk.img` file.

# Mounting a disk
```
mkdir -p /mnt/bebok
sudo mount -t ext4 zig-out/disk-gpt-ext4.img /mnt/bebok
sudo chown -R 1000:1000 /mnt/bebok

```
```
