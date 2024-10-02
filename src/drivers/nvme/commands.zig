// TODO: is that the right place for this struct?
pub const DataPointer = packed union {
    prp: packed struct(u128) {
        prp1: u64,
        prp2: u64 = 0,
    },
    sgl: packed struct(u128) {
        sgl1: u128,
    },
};

const AdminOpcode = enum(u8) {
    identify = 0x06,
    abort = 0x0c,
    set_features = 0x09,
    get_features = 0x0a,
    create_io_sq = 0x01,
    delete_io_sq = 0x00,
    create_io_cq = 0x05,
    delete_io_cq = 0x04,
};

const IoNvmOpcode = enum(u8) {
    write = 0x01,
    read = 0x02,
};

fn GenNCDw0(OpcodeType: type) type {
    return packed struct(u32) {
        opc: OpcodeType,
        fuse: u2 = 0, //0 for nromal operation
        rsvd: u4 = 0,
        psdt: u2 = 0, //0 for PRP tranfer
        cid: u16,
    };
}

pub const AdminCDw0 = GenNCDw0(AdminOpcode);
pub const IoNvmCDw0 = GenNCDw0(IoNvmOpcode);
