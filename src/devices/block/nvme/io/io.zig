const cmnd = @import("command.zig");
const com = @import("../deps.zig").com;

pub const IoNvmCommandSetCommand = packed union {
    const DatasetManagement = packed struct(u8) { access_frequency: u4, access_latency: u2, sequential_request: u1, incompressible: u1 };
    read: packed struct(u512) {
        cdw0: cmnd.IoNvmCDw0, //cdw0 - 00:03 byte
        nsid: com.NsId, //cdw1 - 04:07 byte - nsid
        elbst_eilbst_a: u48, //cdw2,cdw3 - Expected Logical Block Storage Tag and Expected Initial Logical Block Storage Tag
        rsrv_a: u16 = 0, //cdw3
        mptr: u64, //cdw4,cdw5 - Metadata Pointer
        dptr: com.DataPointer, //cdw6,cdw7,cdw8,cdw9 - Data Pointer
        slba: u64, //cdw10,cdw11 - Starting LBA
        nlb: u16, //cdw12 - Number of Logical Blocks
        rsrv_b: u8 = 0, //cdw12 - Reserved
        stc: u1, //cdw12 - Storage Tag Check
        rsrv_c: u1 = 0, //cdw12 - Reserved
        prinfo: u4, //cdw12 - Protection Information Field
        fua: u1, //cdw12 - Force Unit Access
        lr: u1, //cdw12 - Limited Retry
        dsm: DatasetManagement, //cdw13 - Dataset Management
        rsrv_d: u24 = 0, //cdw13 - Reserved
        elbst_eilbst_b: u32, //cdw14 - Expected Logical Block Storage Tag and Expected Initial Logical Block Storage Tag
        elbat: u16, //cdw15 - Expected Logical Block Application Tag
        elbatm: u16, //cdw15 - Expected Logical Block Application Tag Mask
    },
    write: packed struct(u512) {
        cdw0: cmnd.IoNvmCDw0, //cdw0
        nsid: com.NsId, //cdw1
        lbst_ilbst_a: u48, //cdw2,cdw3
        rsrv_a: u16 = 0, //cdw3
        mptr: u64, //cdw4,cdw5
        dptr: com.DataPointer, //cdw6,cdw7,cdw8,cdw9
        slba: u64, //cdw10,cdw11
        nlb: u16, //cdw12
        rsrv_b: u4 = 0, //cdw12
        dtype: u4, //cdw12 - Directive type
        stc: u1, //cdw12 - Storage Tag Check
        rsrv_c: u1 = 0, //cdw12
        prinfo: u4, //cdw12 - Protection Information Field
        fua: u1, //cdw12 - Force Unit Access
        lr: u1, //cdw12 - Limited Retry
        dsm: DatasetManagement, //cdw13 - Dataset Management
        rsrv_d: u8 = 0, //cdw13
        dspec: u16, //cdw14 - Directive Specific
        lbst_ilbst_b: u32, //cdw15
        lbat: u16, //cdw15 - Logical Block Application Tag
        lbatm: u16, //cdw15 - Logical Block Application Tag Mask
    },
};
