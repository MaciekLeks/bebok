const OsError = @import("../../common/common.zig").OsError;
const com = @import("../../common/common.zig");
const mem = @import("../memory.zig");

const HEAP_BLOCK_TABLE_ENTRY_TAKEN: u8 = 0b0000_0001;
const HEAP_BLOCK_TABLE_ENTRY_FREE : u8 = 0b0000_0000;
const HEAP_BLOCK_HAS_NEXT : u8 = 0b1000_0000;
const HEAP_BLOCK_IS_FIRST: u8 = 0b0100_0000;

const HeapTableEntry = u8;
// TODO: finish it
pub const Heap = struct {
    const Self = @This();
    heap_table: [*]HeapTableEntry,
    heap: [*]align(com.OS_HEAP_BLOCK_SIZE)[com.OS_HEAP_BLOCK_SIZE]u8,
    len: usize,

    fn isAligned(ptr: usize) bool {
        return ptr & com.OS_HEAP_BLOCK_SIZE_MASK == 0;
    }

    pub fn init(comptime heap_addr: usize, comptime table_addr: usize, comptime len: usize) OsError!?Self {
        if (!isAligned(heap_addr) and !isAligned(heap_addr + len)) {
            return OsError.InvalidArgument;
        }

        const table =@as(*[len]HeapTableEntry, @ptrFromInt(table_addr));
        const heap = @as([*]align(com.OS_HEAP_BLOCK_SIZE)[com.OS_HEAP_BLOCK_SIZE]u8 , @ptrFromInt(heap_addr));
        const self =  Self{
           //.heap_table = table[1..len], //coerse: *[N]T -> []T
            .heap_table = table,
            .heap = heap,
            //.len = len,
           // .heap_table = table[0..],
            .len = len,
        };

        mem.memset(self.heap_table, HEAP_BLOCK_TABLE_ENTRY_FREE, len);

        if (self.heap_table[10] != HEAP_BLOCK_TABLE_ENTRY_FREE) {
            return OsError.InvalidArgument;
        }

        return self;
    }

    // Aliugn with the next block, e.g. 1 -> 4096, 4097 -> 8192
    fn alignUp(size: usize) usize {
        return (size + com.OS_HEAP_BLOCK_SIZE_MASK) & !com.OS_HEAP_BLOCK_SIZE_MASK;
    }

    fn getStartBlock(self: *Self, blocks: usize) OsError!usize {
        var block = 0;
        var count = 0;
        while (block < self.len) {
            if (self.heap_table[block] == HEAP_BLOCK_TABLE_ENTRY_FREE) {
                count += 1;
                if (count == blocks) {
                    return block - count + 1;
                }
            } else {
                count = 0;
            }
            block += 1;
        }
        return OsError.NoMemory;
    }

    fn blockToAddr(self: *Self, block: usize) usize {
        return self.heap_addr + block * com.OS_HEAP_BLOCK_SIZE;
    }

    // Allocate a number of blocks
    fn allocBlocks(self: *Self, blocks: usize) OsError![]u8 {
        //const start_block = try self.getStarBlock(blocks);
        _ = blocks;
        _ = self;
        return OsError.NoMemory;



    }

    pub fn alloc(self: *Self, size: usize) []u8 {
        const aligned_size = alignUp(size);
        const total_blocks = aligned_size / com.OS_HEAP_BLOCK_SIZE;

        return self.allocBlocks(total_blocks);
    }

};