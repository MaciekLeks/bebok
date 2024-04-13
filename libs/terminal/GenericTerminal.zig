const fmt = @import("std").fmt;
const Writer = @import("std").io.Writer;
const limine = @import("limine");
//const com = @import("../common/common.zig");
const psf = @import("psf/font.zig");
const std = @import("std");

const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;
const VGA_SIZE = VGA_WIDTH * VGA_HEIGHT;

// The Limine requests can be placed anywhere, but it is important that
// the compiler does not optimise them away, so, usually, they should
// be made volatile or equivalent. In Zig, `export var` is what we use.
pub export var framebuffer_request: limine.FramebufferRequest = .{};

pub const Color = u8;
pub const Alpha = u8;

pub const FontPsf1Lat208 = psf.FontInfo("assets/lat2-08.psf"); //Todo remove underscore
pub const FontPsf1Koi8x14 = psf.FontInfo("assets/koi8-14.psf"); //Todo remove underscore
pub const FontPsf2Tamsyn8x16r = psf.FontInfo("assets/Tamsyn8x16r.psf"); //Todo remove underscore
pub const FontPsf1Lat2Vga16 = psf.FontInfo("assets/Lat2vga16.psf");

pub const TerminalError = error {
    NoFramebuffer,
};

const log = std.log.scoped(.terminal);

//pub fn init(fg: ConsoleColors, bg: ConsoleColors) void {
pub fn GenericTerminal(comptime FontInfo: type) type {
    return struct {
        const Self = @This();
        const font_info = FontInfo.init();
        row: usize,
        column: usize,
        max_row: usize,
        max_column: usize,
        bytes_per_pixel: usize,
        bytes_per_row: usize,
        font_height: usize, //bits
        font_width: usize, //bits
        color: u32,
        fb: *limine.Framebuffer,
        fbi: usize, // index of the current framebuffer
        font_info: FontInfo,
        writer: Writer(*Self, error{}, callback) = undefined,

        pub fn init(red: Color, green: Color, blue: Color, alpha: Alpha) !Self {
            if (framebuffer_request.response) |framebuffer_response| {
                if (framebuffer_response.framebuffer_count < 1) {
                    //com.panic();
                    return TerminalError.NoFramebuffer;
                }

                // Get the first framebuffer's information.
                const fbi = 0; //TODO: this should be a parameter.
                const fb = framebuffer_response.framebuffers()[fbi];
                const max_row = fb.height / font_info.glyph_height;
                const max_column = fb.width / font_info.glyph_width;

                log.info("Framebuffer:  addr:0x{x}   {}x{}x{} @ {}bpp", .{&fb.address[0], fb.width, fb.height, fb.pitch, fb.bpp});

                var self = Self{
                    .row = 0,
                    .column = 0,
                    .max_row = max_row,
                    .max_column = max_column,
                    .bytes_per_row = fb.pitch,
                    .bytes_per_pixel = fb.bpp / 8,
                    .font_height = font_info.glyph_height,
                    .font_width = font_info.glyph_width,
                    .color = pixelColor(red, @truncate(fb.red_mask_shift), green, @truncate(fb.green_mask_shift), blue, @truncate(fb.blue_mask_shift), alpha),
                    .fb = fb,
                    .fbi = fbi, //TOOD: this should be a parameter.
                    .font_info = font_info,
                };
                self.writer = Writer(*Self, error{}, callback){ .context = &self };
                return self;
            }
            unreachable;
        }

        fn putCharAt(self: *Self, sx: usize, sy: usize, codepoint: u21) void {
            var utf8_arr: [4]u8 = [_]u8{0} ** 4;
            const encoded_bytes = std.unicode.utf8Encode(codepoint, utf8_arr[0..]) catch unreachable;
            const glyph_no = self.font_info.glyphNumber(utf8_arr[0..encoded_bytes]) orelse 65; //TODO 65->0
            var iter = self.font_info.iterator(glyph_no);

            const start_offset = sy * self.font_height * self.bytes_per_row + sx * self.font_width * self.bytes_per_pixel; //todo : could be cached in the terminal struct
            const end_offset = start_offset + self.font_height * self.bytes_per_row;
            var scanline: usize = 0;

            for (0..self.font_height) |y| {
                scanline = self.fb.pitch * y; //number of bytes per row multiplied by y
                for (0..self.font_width) |x| {
                    const is_glyph_bit_on = iter.next() orelse break;
                    if (is_glyph_bit_on) {
                        const pixel_offset = start_offset + scanline + x * self.bytes_per_pixel;
                        if (pixel_offset > end_offset) {
                           unreachable("pixel_offset > fb_offset_end");
                        }
                        @as(*u32, @ptrCast(@alignCast(self.fb.address + pixel_offset))).* = self.color;
                    }
                }
            }
        }

        fn setColor(self: *Self, red: Color, green: Color, blue: Color) void {
            self.color = pixelColor(red, @truncate(self.fb.red_mask_shift), green, @truncate(self.fb.green_mask_shift), blue, @truncate(self.fb.blue_mask_shift), 0xff);
        }

        inline fn pixelColor(red: Color, red_mask_shift: u5, green: Color, green_mask_shift: u5, blue: Color, blue_mask_shift: u5, alpha: u8) u32 {
            return @as(u32, @as(u32, red) << red_mask_shift | @as(u32, green) << green_mask_shift | @as(u32, blue) << blue_mask_shift | alpha);
        }

        fn putChar(self: *Self, codepoint: u21) void {
            if (codepoint == 0xa) { // '\n'
                self.row += 1;
                self.column = 0;
                return;
            }

            self.putCharAt(self.column, self.row, codepoint);
            self.column += 1;
            if (self.column == self.max_column) {
                self.column = 0;
                self.row += 1;
                if (self.row == self.max_row)
                    self.row = 0;
            }
        }

        /// Write a string to the terminal and return the number of characters written.
        fn puts(self: *Self, str: []const u8) void {
            var utf8_view = std.unicode.Utf8View.init(str) catch unreachable;
            var iter = utf8_view.iterator();
            while (iter.nextCodepoint()) |codepoint| {
                self.putChar(codepoint);
            }
        }

        fn callback(self: *Self, str: []const u8) error{}!usize {
            self.puts(str);
            return str.len;
        }

        pub fn printf(self: Self, comptime format: []const u8, args: anytype) void {
            fmt.format(self.writer, format, args) catch unreachable;
        }
    };
}
