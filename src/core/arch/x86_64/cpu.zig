const gdt = @import("./gdt.zig");
const idt = @import("./int.zig");

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

pub fn GenCr3(comptime pcide: bool) type {
    if (pcide) {
        return packed struct(u64) {
            const Self = @This();
            pcid: u12, //0-11
            aligned_address_4kbytes: u39, //12-51- PMPL4|PML5 address
            ingrd: u1, //52
            rsrvd: u12 = 0, //53-63

            pub fn fromRaw(raw: u64) Self {
                return @bitCast(raw);
            }

            pub fn toRaw(self: Self) u64 {
                return @bitCast(self);
            }
        };
    } else {
        return packed struct(u64) {
            const Self = @This();
            ignrd_a: u3, //0-2
            write_though: bool, //3
            cache_disabled: bool, //4
            ignrd_b: u7, //5-11
            aligned_address_4kbytes: u40, //12-51- PMPL4|PML5 address
            ingrd: u1, //52
            rsrvd: u12 = 0, //53-63

            pub fn fromRaw(raw: u64) Self {
                return @bitCast(raw);
            }

            pub fn toRaw(self: Self) u64 {
                return @bitCast(self);
            }
        };
    }
}

pub const Cr3 = struct {
    pub fn read() u64 {
        return asm volatile ("mov %%cr3, %[result]"
            : [result] "={rax}" (-> u64),
        );
    }

    pub fn write(value: u64) void {
        asm volatile ("mov %[value], %%cr3"
            :
            : [value] "r" (value),
            : "memory" // All cached data is invalidated
        );
    }
};

pub const Cr4 = packed struct(u64) {
    vme: bool, // 0 - Virtual 8086 mode extensions
    pvi: bool, // 1 - Protected mode virtual interrupts
    tsd: bool, // 2 - Time Stamp Disable
    de: bool, // 3 - Debugging extensions
    pse: bool, // 4 - Page Size Extensions
    pae: bool, // 5 - Physical Address Extension
    mce: bool, // 6 - Machine Check Enable
    pge: bool, // 7 -Page Global Enable
    pce: bool, // 8 - Performance Monitoring Counter Enable
    osfxsr: bool, // 9 - Operating System Support for FXSAVE and FXRSTOR
    osxmmexcpt: bool, // 10 - Operating System Support for Unmasked SIMD Floating-Point Exceptions
    umip: bool, // 11 - User-Mode Instruction Prevention
    la57: bool, // 12 - 5-Level Paging
    vmxe: bool, // 13 - Virtual Machine Extensions
    smxe: bool, // 14 - Supervisor-Mode Execution Protection
    rsvd_a: u1, // 15 - Reserved bits
    fsgsbase: bool, // 16 - Fast System Call and Global Descriptor Table Base
    pcide: bool, // 17 - Process-Context Identifiers
    osxsave: bool, // 18 - Operating System Support for XSAVE
    rsvd_b: u1, // 19 - Reserved bits
    smep: bool, // 20 - Supervisor Mode Execution Protection
    pke: bool, // 21 - Protection Key Enable
    cet: bool, // 22 - Control-flow Enforcement Technology
    pks: bool, // 24 - Protection Keys for Supervisor-mode pages
    rsvd_c: u40, // Reserved bits

    pub fn read() Cr4 {
        var cr4: usize = undefined;
        asm volatile ("mov %%cr4, %[result]"
            : [result] "={eax}" (cr4),
        );
        return @bitCast(cr4);
    }

    pub fn write(cr4: Cr4) void {
        const value: usize = @bitCast(cr4);
        asm volatile ("mov %[value], %%cr4"
            :
            : [value] "r" (value),
            : "memory"
        );
    }

    pub fn isPcidEnabled() bool {
        const cr4 = Cr4.read();
        return cr4.pcide;
    }

    pub fn enablePcid() !void {
        if (!Id.isPcidSupported()) {
            return error.PcidNotSupported;
        }

        var cr4 = Cr4.read();
        if (!cr4.pcide) {
            cr4.pcide = true;
            Cr4.write(cr4);
        }
    }
};

//     return asm volatile ("mov %%cr4, %[result]"
//         : [result] "={eax}" (-> usize),
//     );
// }

pub inline fn invlpg(addr: usize) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

pub inline fn rdmsr(msr: u32) usize {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

pub inline fn wrmsr(msr: u32, value: usize) void {
    const low: u32 = @intCast(value & 0xFFFFFFFF);
    const high: u32 = @intCast(value >> 32);
    asm volatile (
        \\ wrmsr
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
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
pub inline fn lgdt(gdtd: *const gdt.Gdtd, code_seg_sel: usize, data_seg_sel: usize) void {
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
          [code_seg_sel] "{rdi}" (code_seg_sel),
          [data_seg_sel] "{rsi}" (data_seg_sel),
        : "rax"
    );
}

pub inline fn ltr(tss_sel: u16) void {
    asm volatile ("ltr %[tss_sel]"
        :
        : [tss_sel] "r" (tss_sel),
    );
}

pub const Id = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,

    pub fn read(eax_in: u32) Id {
        var eax: u32 = 0;
        var ebx: u32 = 0;
        var ecx: u32 = 0;
        var edx: u32 = 0;

        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [eax_in] "{eax}" (eax_in),
            : "eax", "ebx", "ecx", "edx"
        );
        return Id{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
    }

    pub fn isPcidSupported() bool {
        const cpuid_res = Id.read(0x1);
        return (cpuid_res.ecx & (1 << 17)) != 0; // Check if PCID is supported
    }
};

// pub fn cpuid(eax_in: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
//     var eax: u32 = 0;
//     var ebx: u32 = 0;
//     var ecx: u32 = 0;
//     var edx: u32 = 0;

//     asm volatile ("cpuid"
//         : [eax] "={eax}" (eax),
//           [ebx] "={ebx}" (ebx),
//           [ecx] "={ecx}" (ecx),
//           [edx] "={edx}" (edx),
//         : [eax_in] "{eax}" (eax_in),
//         : "eax", "ebx", "ecx", "edx"
//     );
//     return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
// }

pub const Fpu = struct {
    // Exception masks as constants
    pub const mask_invalid_operation = 0 << 0; // Invalid Operation
    pub const mask_denormalized_operand = 1 << 1; // Denormalized Operand
    pub const mask_zero_divide = 1 << 2; // Zero Divide
    pub const mask_overflow = 1 << 3; // Overflow
    pub const mask_underflow = 1 << 4; // Underflow
    pub const mask_precision = 1 << 5; // Precision

    // Method to read the current FPU control word
    pub fn readControlWord() u16 {
        var control_word: u16 = 0;
        asm volatile ("fnstcw %[cw]"
            : [cw] "=m" (control_word),
        );
        return control_word;
    }

    // Method to write a new FPU control word
    pub fn writeControlWord(control_word: u16) void {
        const cw_ptr = &control_word;
        asm volatile ("fldcw (%[ptr])"
            :
            : [ptr] "r" (cw_ptr),
        );
    }

    // Method to non-authorative change of the FPU control word with masks
    pub fn updateControlWord(mask: u16) void {
        const current_cw = readControlWord();
        const new_cw = current_cw | mask;
        writeControlWord(new_cw);
    }
};

// --- helper functions ---

pub inline fn div0() void {
    asm volatile ("int $0");
}

pub inline fn int(comptime n: u8) void {
    asm volatile ("int %[n]"
        :
        : [n] "N" (n),
    );
}
