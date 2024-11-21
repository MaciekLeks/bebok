pub const Guid = extern struct {
    data1: u32 align(1),
    data2: u16 align(1),
    data3: u16 align(1),
    data4: [8]u8 align(1),
};
