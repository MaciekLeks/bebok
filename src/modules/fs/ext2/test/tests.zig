const std = @import("std");
const Ext2 = @import("../Ext2.zig");
const mext2 = @import("mocks/ext2.zig");
const minode = @import("mocks/inode.zig");
const BlockNum = @import("../types.zig").BlockNum;
const Superblock = @import("../types.zig").Superblock;

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
    1019, //78 - {data
    1020, //79 - data}
    1021, //80 - {data
    1022, //81 - data}
    1023, //82 - {data
    1024, //83 - data}
};

fn mockReadBlock(_: *const Ext2, block_num: u32, buffer: []u8) !void {
    //std.debug.print("mReadBlock\n", .{});
    //defer std.debug.print("mReadBlock end\n", .{});
    const start = block_num;
    const end = start + buffer.len / @sizeOf(BlockNum);

    //std.debug.print("Reading block: {d}, [from:{d};to:{d}) into the buffer@u8 of len:{d}\n", .{ block_num, start, end, buffer.len });

    @memcpy(buffer, std.mem.sliceAsBytes(inode_block_data[start..end]));
}

test "InodeBlockIterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    Superblock.test_overwrite_block_size = 2 * @sizeOf(BlockNum);
    defer Superblock.test_overwrite_block_size = null;
    const ext2 = try mext2.createMockExt2(allocator);
    const inode = try minode.createMockInode(allocator, try allocator.dupe(BlockNum, inode_block_data[0..15]));

    //std.debug.print("mext: {}\n", .{ext2});

    var iter = try Ext2.InodeBlockIterator.new(allocator, ext2, inode);
    defer iter.destroy();
    iter.readBlockFn = mockReadBlock;
    const expected_results = [_]BlockNum{
        1001, //{direct access 0th-11th
        1002,
        1003,
        1004,
        1005,
        1006,
        1007,
        1008,
        1009,
        1010,
        1011,
        1012,
        1013,
        1014,
        1015,
        1016,
        1017,
        1018,
        1019,
        1020,
        1021,
        1022,
        1023,
        1024, //direct access 0th-11th}
        101, //{single indirect access 12th
        102,
        103,
        104, //single indirect access 12th}
        101, //{double indirect access 13th
        102,
        103,
        104,
        105,
        106,
        107,
        108, //double indirect access 13th}
        101, //{tripple indirect access 14th
        102,
        103,
        104,
        105,
        106,
        107,
        108,
        109,
        110,
        111,
        112,
        113,
        114,
        116,
        118, //tripple indirect access 14th}
    };
    //_ = expected_results;
    var res_idx: u8 = 0;
    while (iter.next()) |opt_block_num| {
        const block_num = opt_block_num orelse break;
        //std.debug.print("Block number: {}\n", .{block_num});
        var i: u8 = 0;
        while (i < 2) : (i += 1) { //block_size is 2, see the mock superblock
            //std.debug.print("{d},\n", .{inode_block_data[block_num + i]});
            try std.testing.expectEqual(expected_results[res_idx], inode_block_data[block_num + i]);
            res_idx += 1;
        }
    } else |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    }
}
