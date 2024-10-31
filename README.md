# What is Bebok
A 64-bit kernel (and eventually an operating system) written in Zig, currently targeting x86_64, using Limine as a bootloader. I've been working on it for a while now, just for fun.

# Name Origin
In Silesian language, a creature from our (Upper Silesians) demonology. 

# About Bebok
- Bebok is a basic version of an x64 operating system, crafted in Zig using the capabilities of the Limine bootloader.

# Current Features :
- Ready-to-use features provided by Limine
- PMM (Physical Memory Manager) using Buddy Allocator for memory slices and AVL tree for entire memory regions
- Custom GDT (Global Descriptor Table) with kernel code and data segments, in addition to the default one provided by Limine
- IDT (Interrupt Descriptor Table) with basic handlers for Exceptions and LAPIC (Local Advanced Programmable Interrupt Controller)
- Basic terminal support in graphical mode using PC Screen Fonts (versions 1 and 2)
- PCI Express (Peripheral Component Interconnect Express) support
- MSI-X (Message Signaled Interrupts - Extended) support
- NVMe (Non-Volatile Memory Express) module (including driver, controller, etc.)
- Basic stream operations for NVMe (read, write)

# In progress
- [ ] Ongoing refactoring and bug fixing
- [ ] ext4 filesystem support

# How to run
zig build iso-qemu 
```
