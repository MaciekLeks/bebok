const std = @import("std");
const Ext2 = @import("../Ext2.zig");
const mext2 = @import("mocks/ext2.zig");
const minode = @import("mocks/inode.zig");
const BlockNum = @import("../types.zig").BlockNum;

const inode_block_data = [_]BlockNum{
    60, //0 - direct block num
    62, //1 - direct block num
    64, //2 - direct block num
    66, //3 - direct block num
    68, //4 - direct block num
    70, //5 - direct block num
    72, //6 - direct block num
    74, //7 - direct block num
    76, //8 - direct block num
    78, //9 - direct block num
    80, //10 - direct block num
    82, //11 - direct block num
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
    1004, //63 - data}
    1005, //64 - {data
    1006, //65 - data}
    1007, //66 - {data
    1008, //67 - data}
    1009, //68 - {data
    1010, //69 - data}
    1011, //70 - {data
    1012, //71 - data}
    1013, //72 - {data
    1014, //73 - data}
    1015, //74 - {data
    1016, //75 - data}
    1017, //76 - {data
    1018, //77 - data}
    1020, //78 - {data
    1022, //79 - data}
    1024, //80 - {data
    1025, //81 - data}
    1026, //82 - {data
    1027, //83 - data}
};

test "InodeBlockIterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ext2 = try mext2.createMockExt2(allocator);
    const inode = try minode.createMockInode(allocator, try allocator.dupe(BlockNum, inode_block_data[0..15]));

    //std.debug.print("mext: {}\n", .{ext2});

    var iter = Ext2.InodeBlockIterator.init(allocator, ext2, inode);
    while (iter.next()) |opt_block_num| {
        const block_num = opt_block_num orelse break;
        std.debug.print("Block number: {}\n", .{block_num});
        //print data from block_num till blovk_num + block_size\
        var i: u8 = 0;
        while (i < 2) : (i += 1) { //block_size is 2, see the mock superblock
            std.debug.print("Data: {}\n", .{inode_block_data[block_num + i]});
        }
    } else |err| {
        std.debug.print("Error: {}\n", .{err});
    }
}

test "dwa" {}

test "trzy" {}

test "cztery" {}
