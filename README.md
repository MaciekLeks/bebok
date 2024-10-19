# What is Bebok
A 64-bit kernel (and eventually an operating system) written in Zig, currently targeting x86_64, using Limine as a bootloader. I've been working on it for a while now, just for fun.

# Name Origin
In Silesian language, a creature from our (Upper Silesians) demonology. 

# About Bebok
- Bebok is a basic version of an x64 operating system, crafted in Zig using the capabilities of the Limine bootloader.

# Current Features :
- Ready-to-use features provided by Limine
- PMM (Physical Memory Manager) using Buddy Allocator for memory slices and AVL tree for the whole regions
- Custom GDT (Global Descriptor Table) with kernel code and data segments, in addition to the default one provided by Limine
- IDT (Interrupt Descriptor Table) with basic handlers for the Exceptions and LAPIC (Local Programmable Interrupt Controller)
- Basic terminal support in graphical mode with the PC Screen Fonts (version 1 and 2)
- PCI Express (Peripheral Component Interconnect Express) driver  
- MSI-X (Message Signaled Interrupts - Extended) support
- NVMe (Non-Volatile Memory Express) driver in progress (75% ready)

# In progress
- [ ] NVMe driver (I/O operations - read, write)
- [ ] Block operations for NVMe

# How to run
zig build iso-qemu 
```
