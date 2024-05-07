const std = @import("std");

// src: https://www.win.tue.nl/~aeb/linux/kbd/font-formats-1.html
//src: https://accidental.cc/notes/2022/psf-zig/
const psf1_magic: [2]u8 = .{ 0x36, 0x04 };
const psf2_magic: [4]u8 = .{ 0x72, 0xb5, 0x4a, 0x86 };

const psf1_mode_has256 = 0x00; //256 glyphs
const psf1_mode_has512 = 0x01;
const psf1_mode_hastab = 0x02;
const psf1_mode_hasseq = 0x04;
const psf2_has_unicode_table = 0x01;

const ct_max_branches = 100000;
const ct_max_codepoints = 1000;

const GlyphNumber = u32;

/// build an iterator that can walk over the pixel data in a given PSFFont
/// iterates over single bits, aligning forward a bite when hitting the glyph
/// width.
///
/// user assumes responsibility for coordinating iteration in screen coordinates (sx, sy),
/// at the row pitch level, no signal for "end of row" is provided.
fn PixelIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        font: *const T,
        glyph: u32,

        index: usize = 0, // the current index into the glyph byte array
        bitcount: u8 = 0, // the number of bits we've read out of the working glyph
        workglyph: u8 = undefined, // the byte we're currently destructing to get bits
        max_shift: u32 = 0, // maximum number of bits to shift left in the current byte

        pub fn init(self: *Self) void {
            if (self.max_shift == 0) {
                self.max_shift = @min(8, self.font.glyph_width);
            }
            self.reset();
        }

        /// Resets the iterator to the initial state.
        pub fn reset(self: *Self) void {
            self.resetIndex(0);
        }

        /// aligns to the next byte
        pub fn alignForward(self: *Self) void {
            if (self.bitcount > 0) {
                self.resetIndex(self.index + 1);
            }
        }

        /// Returns whether the next pixel is set or not,
        /// or null if we've read all pixels for the glyph
        pub fn next(self: *Self) ?bool {
            if (self.index >= self.font.glyph_size)
                return null;

            defer {
                self.bitcount += 1;
                // todo: memorize the min? this happens on every iteration
                if (self.bitcount >= self.max_shift) {
                    self.resetIndex(self.index + 1);
                }
            }

            const res_with_overflow = @shlWithOverflow(self.workglyph, 1);
            self.workglyph = res_with_overflow[0];
            return res_with_overflow[1] == 1;
            // return @shlWithOverflow(u8, self.workglyph, 1, &self.workglyph);
        }

        // reset to the given index
        // used for full resets and byte-to-byte transitions
        fn resetIndex(self: *Self, index: usize) void {
            self.index = index;
            self.bitcount = 0;

            // if we're about to roll out of the glyph, don't
            // otherwise, the last iteration (which would return null) panics for out-of-bounds
            if (index < self.font.glyph_size) {
                self.workglyph = self.font.glyphs[self.glyph][index];
            }
        }
    };
}

// options for the common PSF struct generator
const HeaderInfo = struct {
    file: []const u8,
    header_size: u32,
    glyph_count: u32,
    glyph_size: u32,
    glyph_width: u32,
    glyph_height: u32,
    unicode_table_offset: ?u32,
    unicode_count: u32,
};

// comptime known header info plus utf8 map if current font has unicode table
fn HeaderDataInfo(comptime h_info: HeaderInfo, comptime UTF8Map: ?type) type {
    return struct {
        const header_info = h_info;
        const Map = UTF8Map;
    };
}

// given font metrics, generate a struct type which can read font glyphs at compile time
fn GenericInfo(comptime Settings: type) type {
    return struct {
        const Self = @This();
        const Iterator = PixelIterator(Self);

        // explicitly sized per the header file
        pub const Glyph = [Settings.header_info.glyph_size]u8;
        pub const GlyphSet = [Settings.header_info.glyph_count]Glyph;

        glyphs: GlyphSet,

        glyph_count: u32,
        glyph_width: u32,
        glyph_height: u32,
        glyph_size: u32,
        unicode_table_offset: ?u32, //TOOD remove
        unicode_count: u32,

        const Map = Settings.Map;

        pub fn init() Self {

            //@compileLog("glyph size:", Settings.header_info.glyph_size);

            // get a stream over the embedded file and skip the header
            var glyph_stream = std.io.fixedBufferStream(Settings.header_info.file);
            glyph_stream.seekTo(Settings.header_info.header_size) catch unreachable;

            comptime var index = 0;
            comptime var data: GlyphSet = undefined;

            // then read every glyph out of the file into the struct
            // without the eval branch quota, compiler freaks out in read for backtracking
            @setEvalBranchQuota(ct_max_branches);
            inline while (index < Settings.header_info.glyph_count) : (index += 1) {
                _ = glyph_stream.read(data[index][0..Settings.header_info.glyph_size]) catch unreachable;
            }

            return Self{
                .glyphs = data,
                .glyph_count = Settings.header_info.glyph_count,
                .glyph_width = Settings.header_info.glyph_width,
                .glyph_height = Settings.header_info.glyph_height,
                .glyph_size = Settings.header_info.glyph_size,
                .unicode_table_offset = Settings.header_info.unicode_table_offset,
                .unicode_count = Settings.header_info.unicode_count,
            };
        }

        pub fn glyphNumber(_: Self, utf8_slice: []const u8) ?u32 {
            if (Map) |map| {
                return map.get(utf8_slice);
            } else {
                return utf8_slice[0];
            }
        }

        //pub fn iterator(self: *const Self, glyph: u32) Iterator {
        pub fn iterator(self: *const Self, glyph: u32) Iterator {
            var iter = Iterator{ .font = self, .glyph = glyph };
            iter.init();

            return iter;
        }
    };
}

/// return a PSF2 font struct,
fn Version2Info(comptime file: []const u8) type {
    var stream = std.io.fixedBufferStream(file);
    var reader = stream.reader();

    _ = try reader.readInt(u32, .little); // magic (already validated)
    _ = try reader.readInt(u32, .little); // version
    const header_size = try reader.readInt(u32, .little);
    const flags = try reader.readInt(u32, .little); // flags (1 if unicode table)
    const glyph_count = try reader.readInt(u32, .little);
    const glyph_size = try reader.readInt(u32, .little);
    const glyph_height = try reader.readInt(u32, .little);
    const glyph_width = try reader.readInt(u32, .little);

    const uc_table_offset: ?u32 = if (flags & psf2_has_unicode_table != 0) header_size + glyph_count * glyph_height else null;

    // comptime var utf8_slice: []u8 = undefined;
    // jump to the unicode table and determine the number of unicode codes
    comptime var uc_codes: u32 = 0;

    var h_info: HeaderInfo = .{
        .file = file,
        .header_size = header_size, // 8 u32 fields, = 32 bytes
        .glyph_count = glyph_count,
        .glyph_size = glyph_size,
        .glyph_width = glyph_width,
        .glyph_height = glyph_height,
        .unicode_table_offset = uc_table_offset,
        .unicode_count = uc_codes, // will be updated later if needed
    };

    if (uc_table_offset != null) {
        comptime {
            reader.skipBytes(uc_table_offset.? - header_size, .{}) catch {
                @compileError("failed to skip glyph data to read unicode table");
            };

            var utf8_bytes: [4]u8 align(@alignOf(u32)) = [_]u8{0} ** 4;
            var glyph_no: u32 = 0;
            // temporary array to store utf8 bytes and glyph number before putting them into the hashmap
            var utf8_glyph_arr: [ct_max_codepoints]struct { []const u8, GlyphNumber } = undefined;
            @setEvalBranchQuota(ct_max_branches);
            while (reader.readByte()) |byte| {
                switch (byte) {
                    0xFF => glyph_no += 1,
                    else => {
                        utf8_bytes[0] = byte;
                        if (byte & 0b1000_0000 != 0) {
                            if (byte & 0b10_0000 == 0) { //UTF-2 2-bytes
                                utf8_bytes[1] = try reader.readByte();
                                var key_arr: [2]u8 = undefined;
                                @memcpy(&key_arr, utf8_bytes[0..2]); //we need to copy while utf8_byte is being muted by the next read
                                const key_arr_c = key_arr;
                                utf8_glyph_arr[uc_codes] = .{ &key_arr_c, glyph_no };
                            } else if (byte & 0b1_0000 == 0) { //UTF-8 3-bytes
                                //utf8_bytes[1] = try reader.readByte();
                                //utf8_bytes[2] = try reader.readByte();
                                try reader.readNoEof(utf8_bytes[1..]); //the same as the above
                                var key_arr: [3]u8 = undefined;
                                @memcpy(&key_arr, utf8_bytes[0..3]); //we need to copy while utf8_byte is being muted by the next read
                                const key_arr_c = key_arr;
                                utf8_glyph_arr[uc_codes] = .{ &key_arr_c, glyph_no };
                            } else if (byte & 0b1000 == 0) { //UTF-8 4-bytes
                                //utf8_bytes[1] = try reader.readByte();
                                //utf8_bytes[2] = try reader.readByte();
                                //utf8_bytes[3] = try reader.readByte();
                                try reader.readNoEof(utf8_bytes[1..]); //the same as the above
                                var key_arr: [4]u8 = undefined;
                                @memcpy(&key_arr, utf8_bytes[0..4]); //we need to copy while utf8_byte is being muted by the next read
                                const key_arr_c = key_arr;
                                utf8_glyph_arr[uc_codes] = .{ &key_arr_c, glyph_no };
                            }
                        } else {
                            var key_arr: [1]u8 = undefined;
                            @memcpy(&key_arr, utf8_bytes[0..1]); //we need to copy while utf8_byte is being muted by the next read
                            const key_arr_c = key_arr;
                            utf8_glyph_arr[uc_codes] = .{ &key_arr_c, glyph_no };
                        }
                        uc_codes += 1;
                        @memset(&utf8_bytes, 0); //reset utf8_bytes
                    },
                }
            } else |err| {
                if (err != error.EndOfStream) @compileError("failed to read unicode table");
            }

            //update unicode count
            h_info.unicode_count = uc_codes;
            return GenericInfo(HeaderDataInfo(h_info, std.ComptimeStringMap(GlyphNumber, utf8_glyph_arr[0..uc_codes])));
        }
    }

    return GenericInfo(HeaderDataInfo(h_info, null));
}

fn Version1Info(comptime file: []const u8) type {
    var stream = std.io.fixedBufferStream(file);
    var reader = stream.reader();

    const header_size: u32 = 4;
    _ = try reader.readInt(u16, .little); // magic (already validated)
    const font_mode = try reader.readInt(u8, .little); //256 or 512 glyphs, has unicode table, has unicode sequence
    const glyph_height = try reader.readInt(u8, .little); //character height from charsize since with is always 8
    const glyph_count: u32 = if (font_mode & psf1_mode_has256 == 0) 256 else 512;
    const uc_table_offset: ?u32 = if (font_mode & psf1_mode_hastab != 0 or font_mode & psf1_mode_hasseq != 0) header_size + glyph_count * glyph_height else null;

    // jump to the unicode table and determine the number of unicode codes
    comptime var uc_codes: u32 = 0;
    var h_info: HeaderInfo = .{
        .file = file,
        .header_size = header_size, // 4 u8 fields, = 4 bytes
        .glyph_count = glyph_count,
        .glyph_size = glyph_height,
        .glyph_width = 8,
        .glyph_height = glyph_height,
        .unicode_table_offset = uc_table_offset,
        .unicode_count = uc_codes,
    };

    if (uc_table_offset != null) {
        comptime {
            reader.skipBytes(uc_table_offset.? - header_size, .{}) catch {
                @compileError("failed to skip glyph data to read unicode table");
            };

            var codepoint_glyph_arr: [ct_max_codepoints]struct { []const u8, GlyphNumber } = undefined;
            var glyph_no: GlyphNumber = 0;
            @setEvalBranchQuota(ct_max_branches);
            while (reader.readInt(u16, .little)) |codepoint| {
                const bytes_count: u3 = std.unicode.utf8CodepointSequenceLength(codepoint) catch @compileError("invalid codepoint");
                switch (codepoint) {
                    0xFFFF => glyph_no += 1, // there is no standard 0xfffe in psf1, see the spec https://www.win.tue.nl/~aeb/linux/kbd/font-formats-1.html
                    else => {
                        //TODO can't use std.unicode.utf8Encode because it does not work in comptime, we need here comptime known arrays
                        switch (bytes_count) {
                            1 => {
                                var codepoint_bytes: [1]u8 = undefined;
                                codepoint_bytes[0] = codepoint;
                                const codepoint_bytes_c = codepoint_bytes;
                                codepoint_glyph_arr[uc_codes] = .{ &codepoint_bytes_c, glyph_no };
                            },
                            2 => {
                                var codepoint_bytes: [2]u8 = undefined;
                                codepoint_bytes[0] = 0xC0 | (codepoint >> 6);
                                codepoint_bytes[1] = 0x80 | (codepoint & 0x3F);
                                const codepoint_bytes_c = codepoint_bytes;

                                codepoint_glyph_arr[uc_codes] = .{ &codepoint_bytes_c, glyph_no };
                            },
                            3 => {
                                var codepoint_bytes: [3]u8 = undefined;
                                codepoint_bytes[0] = 0xE0 | (codepoint >> 12);
                                codepoint_bytes[1] = 0x80 | ((codepoint >> 6) & 0x3F);
                                codepoint_bytes[2] = 0x80 | (codepoint & 0x3F);
                                const codepoint_bytes_c = codepoint_bytes;
                                codepoint_glyph_arr[uc_codes] = .{ &codepoint_bytes_c, glyph_no };
                            },
                            else => @compileError("invalid codepoint length"),
                        }

                        uc_codes += 1;
                    },
                }
            } else |err| {
                if (err != error.EndOfStream) @compileError("failed to read unicode table");
            }

            //update unicode count
            h_info.unicode_count = uc_codes;
            return GenericInfo(HeaderDataInfo(h_info, std.ComptimeStringMap(GlyphNumber, codepoint_glyph_arr[0..uc_codes])));
        }
    }

    return GenericInfo(HeaderDataInfo(h_info, null));
}

/// build FontInfo struct from the given file
/// will cause a compile error if the file is not parsable as a PSF v1 or v2
pub fn FontInfo(comptime path: []const u8) type {
    const file = @embedFile(path);

    if (std.mem.eql(u8, file[0..2], psf1_magic[0..2])) {
        return Version1Info(file);
    }

    if (std.mem.eql(u8, file[0..4], psf2_magic[0..4])) {
        return Version2Info(file);
    }

    @compileError("file isn't PSF (no matching magic)");
}
