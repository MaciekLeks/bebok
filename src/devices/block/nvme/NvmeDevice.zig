const Pcie = @import("../../../bus/Pcie.zig");
const NvmeDriver = @import("../../mod.zig").NvmeDriver;

const BlockDevice = @import("../block.zig").BlockDevice;
const Device = @import("../../Device.zig");

const NvmeDevice = @This();

const nvme_ncqr = 0x2; //number of completion queues requested (+1 is admin cq)
const nvme_nsqr = nvme_ncqr; //number of submission queues requested

base: *Device,

bar: Pcie.Bar = undefined,
msix_cap: Pcie.MsixCap = undefined,

//expected_phase: u1 = 1, //private counter to keep track of the expected phase
mdts_bytes: u32 = 0, // Maximum Data Transfer Size in bytes

ncqr: u16 = nvme_ncqr, //number of completion queues requested - TODO only one cq now
nsqr: u16 = nvme_nsqr, //number of submission queues requested - TODO only one sq now

cq: [nvme_ncqr]NvmeDriver.com.Queue(NvmeDriver.com.CQEntry) = undefined, //+1 for admin cq
//cq: [nvme_ncqr + 1]Queue(CQEntry) = undefined, //+1 for admin
sq: [nvme_nsqr]NvmeDriver.com.Queue(NvmeDriver.com.SQEntry) = undefined, //+1 for admin sq

//slice of NsInfo
ns_info_map: NvmeDriver.NsInfoMap = undefined,

mutex: bool = false,

pub fn deinit(self: *NvmeDevice) void {
    self.ns_info_map.deinit();
}
