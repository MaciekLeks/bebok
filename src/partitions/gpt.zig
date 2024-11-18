const GptHeader = extern struct {
    signature: [8]u8 align(1), // "EFI PART"
    revision: u32 align(1),
    header_size: u32 align(1),
    crc32: u32 align(1),
    reserved: u32 align(1),
    current_lba: u64 align(1),
    backup_lba: u64 align(1),
    first_usable_lba: u64 align(1),
    last_usable_lba: u64 align(1),
    disk_guid: [16]u8 align(1),
    partition_entry_lba: u64 align(1),
    num_partition_entries: u32 align(1),
    partition_entry_size: u32 align(1),
    partition_array_crc32: u32 align(1),
};

const GptEntry = extern struct {
    type_guid: [16]u8,
    guid: [16]u8,
    slba: u64,
    elba: u64,
    flags: u64,
    name: [72]u8, // Unicode-16-LE
};
