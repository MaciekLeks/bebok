const GenericEntry = usize;

// We assume 52 max physical address bits

pub fn Cr3Structure(comptime pcid: bool) type {
    if (pcid) {
        return  packed struct(GenericEntry) {
            pcid: u12, //0-11
            aligned_address_4kbytes: u40, //12-51- PMPL4|PML5 address
            rsrvd: u12 = 0, //52-63
        };
    } else {
        return  packed struct(GenericEntry) {
            ignrd_a: u3, //0-2
            write_though: bool, //3
            cache_disabled: bool, //4
            ignrd_b: u7, //5-11
            aligned_address_4kbytes: u40, //12-51- PMPL4|PML5 address
            rsrvd: u12 = 0, //52-63
        };
    }
}

const PagingTablePageSizeEnum = enum { pml4e, pml4e1gbyte, pdpte, pdpte2mbytes, pde, pte};

pub fn PagingStructureEntry(comptime pse: PagingTablePageSizeEnum) type {
    return packed struct(GenericEntry) {
        present: bool, //0
        writable: bool, //1
        user: bool, //2
        write_through: bool, //3
        cache_disabled: bool, //4
        accessed: bool, //5

        usingnamespace switch (pse) {
            .pml4e => packed struct {
                dirty: bool, //6
                rsrvd_a: u1, //7
                ignrd_a: u3, //8-10
                restart: u1, //11
                aligned_address_4kbytes: u39, //12-50- PML3 address
                rsrvd_b: u1, //51
                ignrd_b: u11, //52-62
                execute_disable: bool, //63
            },
            .pml4e1gbytes => packed struct {
                dirty: bool, //6
                huge: bool, //7
                global: bool, //8
                ignrd_a: u2, //9-10
                restart: u1, //11
                pat: u1, //12
                rsrvd_a: u17, //13-29
                aligned_address_1gbyte: u21,
                rsrvd_b: u1, //51
                ignrd_b: u7, //52-58
                protection_key: u4, //59-62
                execute_disable: bool, //63
            },
            .pdpte => packed struct {
                ignrd_a: u1, //6
                hudge: bool, //7
                ignrd_b: u3, //8-10
                restart: u1, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1, //50
                ignr_b: u11, //52-62
                execute_disable: bool, //63
            },
            .pdpte2mbytes => packed struct {
                dirty: bool, //6
                hudge: bool, //7
                global: bool, //8
                ignrd_a: u2, //9-10
                restart: u1, //11
                pat: u1, //12
                rsrvd_a: u8, //13-20
                aligned_address_2mbyte: u29, //21-50
                rsrvd_b: u1, //51
                ignrd_b: u7, //52-58
                protection_key: u4, //59-62
                execute_disable: bool, //63
            },
            .pde => packed struct {
                ignrd_a: bool, //6
                hudge: bool, //7 //must be 0
                ignrd_b: u3, //8-10
                restart: u1, //11
                aligned_address_4kbyte: u39, //12-50
                rsrvd_a: u1, //51-51 //must be 0
                ignored_c: u11, //52-62
                execute_disable: bool, //63
            },
            .pte => packed struct {
                dirty: bool, //6
                pat: u1, //7
                global: bool, //8
                ignrd_a: u1, //11
                aligned_address_4kbyte: u39, //12-50
                rsrvd_a: u1, //51-51 //must be 0
                ignrd_b: u7, //52-58
                protection_key: u11, //59-62
                execute_disable: bool, //63
            },
            else => packed struct {},
        };
    };
}
