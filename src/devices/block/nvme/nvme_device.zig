const pcie = @import("../../../io/bus/pci/pcie.zig");
const nvme_driver = @import("../../../drivers/Nvme.zig"); //TODO - refactor

const NvmeDevice = struct {
    const nvme_ncqr = 0x2; //number of completion queues requested (+1 is admin cq)
    const nvme_nsqr = nvme_ncqr; //number of submission queues requested

    bar: pcie.BAR = undefined,
    msix_cap: pcie.MsixCap = undefined,

    //expected_phase: u1 = 1, //private counter to keep track of the expected phase
    mdts_bytes: u32 = 0, // Maximum Data Transfer Size in bytes

    ncqr: u16 = nvme_ncqr, //number of completion queues requested - TODO only one cq now
    nsqr: u16 = nvme_nsqr, //number of submission queues requested - TODO only one sq now

    cq: [nvme_ncqr]nvme_driver.Queue(nvme_driver.CQEntry) = undefined, //+1 for admin cq
    //cq: [nvme_ncqr + 1]Queue(CQEntry) = undefined, //+1 for admin
    sq: [nvme_nsqr]nvme_driver.Queue(nvme_driver.SQEntry) = undefined, //+1 for admin sq

    //slice of NsInfo
    ns_info_map: nvme_driver.NsInfoMap = undefined,

    mutex: bool = false,
};
