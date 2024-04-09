const MMAP_ARRAY_ADDR = 0x8008;
const MMAP_LEN_ADDR = 0x8000;

const SysMemMapEntry = packed struct {
    base: u64,
    len: u64,
    type: u32,
    acpi: u32,
};

pub const SysMemMap = struct {
    const Self  = @This();
    //mem_map : [*]align(1) volatile usize,
    len : usize,
   entries:  [] SysMemMapEntry,


    pub fn  isFree(self: Self, base: u64, len: u64) bool {
        for (self.entries) |*entry| {
            if (entry.base <= base and base + len <= entry.base + entry.len) {
                return entry.type == 1;
            }
        }
        return false;
    }

    pub fn init() Self {
        const len_ptr :*usize = @ptrFromInt(MMAP_LEN_ADDR);
        const mmap_ptr = @as([*] SysMemMapEntry, @ptrFromInt(MMAP_ARRAY_ADDR));
        //const mmap_slice: [*]SMapEntry = @alignCast(mmap_ptr);

        const self = Self{
            //.mem_map = @as([*]align(1) volatile usize, @ptrFromInt(MMAP_ARRAY_ADDR)),
            .len = len_ptr.*,
            .entries = mmap_ptr[0..len_ptr.*],
        };

        var base : u64 = 0 ;
        var len: u64 = 0;
        for (self.entries) |*entry| {
            base = entry.base;
            len = entry.len;
        }

        if (base + len > 0x100000000) {
            _ = {};
        }

        return self;
    }
};
