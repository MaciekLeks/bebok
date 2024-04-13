# What is Bebok
A 64-bit kernel (and eventually an operating system) written in Zig, currently targeting x86_64. Utilizes Limine as a bootloader.

# What Bebok means
In Silesian language, a creature from their demonology. 

# About Bebok
- Bebok is a basic version of an x64 operating system, crafted in Zig using the capabilities of the Limine bootloader.

# Current features include:
- All Limine features
- Basic terminal support in graphical mode with the PC Screen Fonts (version 1 and 2)

# Next steps
- [ ] Implementing the heap
- ...

# How to run
```bash
zig build iso-qemu 
```