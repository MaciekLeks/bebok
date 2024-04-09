// pub fn memset(ptr: [*]u8, value: u8, len: usize) void {
//     // var tmp_ptr = ptr;
//     // for (0..len) |_| {
//     //     tmp_ptr +=  1;
//     //     tmp_ptr.* = value;
//     // }
// }
// pub fn memset(ptr: [*]u8, value: u8, len: usize) void {
//     var tmp_ptr = ptr;
//     for (tmp_ptr[0..len]) |*byte| {
//         byte.* = value;
//     }
// }
//

// pub fn memset(ptr: [*]u8, value: u8, len: usize) void {
//     var i: usize = 0;
//     const tmp = ptr;
//     while (i < len): (i += 1) {
//         tmp[i] = value;
//     }
// }

pub fn memset(ptr: [*]u8, value: u8, len: usize) void {
    for (ptr[0..len]) |*byte| {
        byte.* = value;
    }
}
