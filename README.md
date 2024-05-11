# What is Bebok
A 64-bit kernel (and eventually an operating system) written in Zig, currently targeting x86_64. Utilizes Limine as a bootloader.

# Name Origin
In Silesian language, a creature from our (Upper Silesians) demonology. 

# About Bebok
- Bebok is a basic version of an x64 operating system, crafted in Zig using the capabilities of the Limine bootloader.

# Current Implemented Features :
- All Limine features
- PMM (Physical Memory Manager) using Buddy Allocator for memory slices and AVL tree for the whole regions
- Custom GDT (Global Descriptor Table) with kernel code and data segments, in addition to the default one provided by Limine
- Basic terminal support in graphical mode with the PC Screen Fonts (version 1 and 2)


# Current Development Steps
- [ ] Implementing IDT

# How to run
```bash
zig build iso-qemu 
```