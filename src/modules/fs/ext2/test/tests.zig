const std = @import("std");
const Ext2 = @import("../Ext2.zig");
const mext2 = @import("mocks/ext2.zig");
const mionode = @import("mocks/inode.zig");
const BlockNum = @import("../types.zig").BlockNum;

const inode_block_data = [_]BlockNum{
    60, //0 - direct block num
    61, //1 - direct block num
    62, //2 - direct block num
    63, //3 - direct block num
    64, //4 - direct block num
    65, //5 - direct block num
    66, //6 - direct block num
    67, //7 - direct block num
    68, //8 - direct block num
    69, //9 - direct block num
    70, //10 - direct block num
    71, //11 - direct block num
    22, //12 - single indirect block num //plays role of 12th element i_block array
    32, //13 - double indirect block num //plays role of 13th element i_block array
    36, //14 - triple indirect block num //plays role of 14th element i_block array
    0, //15
    0, //16
    0, //17
    0, //18
    0, //19
    0, //20
    0, //21
    42, //22 - {l0
    44, //23 - l0}
    46, //24 - {l0
    48, //25 - l0}
    50, //26 - {l0
    52, //27 - l0}
    54, //28 - {l0
    56, //29 - l0}
    0, //30
    0, //31
    22, //32 - {l1
    24, //33 - l1}
    26, //34 - {l1
    28, //35 - l1}
    32, //36 - {l2
    34, //37 - l2}
    0, //38
    0, //39
    0, //40
    0, //41
    // the following are the data blocks accessed by the indirect blocks (l0)
    101, //42 - {data
    102, //43 - data}
    103, //44 - {data
    104, //45 - data}
    105, //46 - {data
    106, //47 - data}
    107, //48 - {data
    108, //49 - data}
    109, //50 - {data
    110, //51 - data}
    111, //52 - {data
    112, //53 - data}
    113, //54 - {data
    114, //55 - data}
    116, //56 - {data
    118, //57 - data}
    0, //58
    0, //59
    // the following are the data blocks accesed directly by the inode (from 0th to 11th)
    1001, //60 - {data
    1002, //61 - data}
    1003, //62 - {data
    1004, //65 - data}
    1006, //66 - {data
    1007, //67 - data}
    1008, //68 - {data
    1009, //69 - data}
    1010, //70 - {data
    1011, //71 - data}
};

test "InodeBlockIterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mext = mext2.mockExt2(allocator);
    const minode = mionode.mockInode(&inode_block_data);

    std.debug.print("mext: {}\n", .{mext});

    var iter = try Ext2.InodeBlockIterator.init(allocator, &mext, &minode);
    _ = &iter;
}

test "dwa" {}

test "trzy" {}

test "cztery" {}
