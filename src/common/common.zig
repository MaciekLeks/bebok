pub const OsError = error {
    InvalidArgument,
    NoMemory,
};

pub const OS_HEAP_BLOCK_SIZE: u16 = 0x1000;
pub const OS_HEAP_BLOCK_SIZE_MASK: u16 = 0x0FFF;
pub const OS_HEAP_TABLE_ADDRESS = 0x0000_A000;
pub const OS_HEAP_ADDRESS = 0x0000_B000; //TODO: change it

pub fn panic() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}