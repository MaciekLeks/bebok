const gdt = @import("gdt.zig");
const idt = @import("int.zig");

pub fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub const PortNumberType = u16; // Port numbers are 16-bit for all x86 architectures

pub inline fn in(comptime T: type, port: PortNumberType) T {
    return switch (T) {
        u8 => asm volatile ("inb %[port], %[ret]"
            : [ret] "={al}" (-> u8),
            : [port] "N{dx}" (port),
        ),

        u16 => asm volatile ("inw %[port], %[ret]"
            : [ret] "={al}" (-> u16),
            : [port] "N{dx}" (port),
        ),

        u32 => asm volatile ("inl %[port], %[ret]"
            : [ret] "={eax}" (-> u32),
            : [port] "N{dx}" (port),
        ),

        else => unreachable,
    };
}

pub inline fn out(comptime T: type, port: PortNumberType, value: T) void {
    switch (T) {
        u8 => asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (port),
        ),

        u16 => asm volatile ("outw %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (port),
        ),

        u32 => asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value),
              [port] "N{dx}" (port),
        ),

        else => unreachable,
    }
}

// DEPRECIATED: use in instead
pub inline fn inb(port: PortNumberType) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}


// DEPRECIATED: use in instead
pub inline fn inw(port: PortNumberType) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

// DEPRECIATED: use out instead
pub inline fn outb(port: PortNumberType, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [data] "{al}" (data),
          [port] "{dx}" (port),
    );
}

// DEPRECIATED: use out instead
pub inline fn outw(port: PortNumberType, data: u16) void {
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

pub inline fn lidt(idtd: *const idt.Idtd) void {
    asm volatile (
        \\lidt (%%rax)
        :
        : [idtd] "{rax}" (idtd),
    );
}

// Load the GDT and set the code and data segment registers; Setting the segment registers is necessary even if Limine already had set the same selectors.
pub inline fn lgdt(gdtd: *const gdt.Gdtd, code_selector: usize, data_selector: usize) void {
    asm volatile (
        \\lgdt (%%rax)
        \\pushq %%rdi
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movq %%rsi, %%rax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        :
        : [gdtd] "{rax}" (gdtd),
          [code_selector_idx] "{rdi}" (code_selector),
          [data_selector_idx] "{rsi}" (data_selector),
        : "rax"
    );
}

pub inline fn div0() void {
    asm volatile ("int $0");
}
