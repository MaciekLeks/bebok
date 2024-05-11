const gdt = @import("gdt.zig");

pub fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub inline fn outb(port: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [data] "{al}" (data),
          [port] "{dx}" (port),
    );
}

pub inline fn outw(port: u16, data: u16) void {
    asm volatile ("outw %[data], %[port]"
        :
        : [data] "{ax}" (data),
          [port] "{dx}" (port),
    );
}

// QEMU debug port
pub fn putb(byte: u8) void {
    outb(0xE9, byte);
}

pub inline fn cr3() usize {
    return asm volatile ("mov %cr3, %[result]"
        : [result] "={eax}" (-> usize),
    );
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

// pub inline fn lgdt(gdtd: *const gdt.Gdtd) void {
//     asm volatile (
//         \\gdt (%%rax)
//         :
//         : [gdtd] "{rax}" (gdtd),
//     );
// }


pub inline fn lgdt(gdtd: *const gdt.Gdtd) void {
    asm volatile (
        \\lgdt (%%rax)
        \\pushq $0x28
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movq $0x30, %%rax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        :
        : [gdtd] "{rax}" (gdtd),
        : "rax"
    );
}
