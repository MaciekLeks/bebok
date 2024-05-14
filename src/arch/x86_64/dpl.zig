pub const PrivilegeLevel = enum(u2) {
    ring0 = 0, //kernel
    ring1 = 1,
    ring2 = 2,
    ring3 = 3, //user
};
