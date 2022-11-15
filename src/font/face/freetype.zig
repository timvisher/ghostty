//! Face represents a single font face. A single font face has a single set
//! of properties associated with it such as style, weight, etc.
//!
//! A Face isn't typically meant to be used directly. It is usually used
//! via a Family in order to store it in an Atlas.

const std = @import("std");
const builtin = @import("builtin");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");
const resize = @import("stb_image_resize");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Atlas = @import("../../Atlas.zig");
const font = @import("../main.zig");
const Glyph = font.Glyph;
const Library = font.Library;
const Presentation = font.Presentation;
const convert = @import("freetype_convert.zig");
const fastmem = @import("../../fastmem.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// Our font face.
    face: freetype.Face,

    /// Harfbuzz font corresponding to this face.
    hb_font: harfbuzz.Font,

    /// The presentation for this font. This is a heuristic since fonts don't have
    /// a way to declare this. We just assume a font with color is an emoji font.
    presentation: Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,

    /// Initialize a new font face with the given source in-memory.
    pub fn initFile(lib: Library, path: [:0]const u8, index: i32, size: font.face.DesiredSize) !Face {
        const face = try lib.lib.initFace(path, index);
        errdefer face.deinit();
        return try initFace(face, size);
    }

    /// Initialize a new font face with the given source in-memory.
    pub fn init(lib: Library, source: [:0]const u8, size: font.face.DesiredSize) !Face {
        const face = try lib.lib.initMemoryFace(source, 0);
        errdefer face.deinit();
        return try initFace(face, size);
    }

    fn initFace(face: freetype.Face, size: font.face.DesiredSize) !Face {
        try face.selectCharmap(.unicode);
        try setSize_(face, size);

        const hb_font = try harfbuzz.freetype.createFont(face.handle);
        errdefer hb_font.destroy();

        return Face{
            .face = face,
            .hb_font = hb_font,
            .presentation = if (face.hasColor()) .emoji else .text,
            .metrics = calcMetrics(face),
        };
    }

    pub fn deinit(self: *Face) void {
        self.face.deinit();
        self.hb_font.destroy();
        self.* = undefined;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, size: font.face.DesiredSize) !void {
        try setSize_(self.face, size);
        self.metrics = calcMetrics(self.face);
    }

    fn setSize_(face: freetype.Face, size: font.face.DesiredSize) !void {
        // If we have fixed sizes, we just have to try to pick the one closest
        // to what the user requested. Otherwise, we can choose an arbitrary
        // pixel size.
        if (face.isScalable()) {
            const size_26dot6 = @intCast(i32, size.points << 6); // mult by 64
            try face.setCharSize(0, size_26dot6, size.xdpi, size.ydpi);
        } else try selectSizeNearest(face, size.pixels());
    }

    /// Selects the fixed size in the loaded face that is closest to the
    /// requested pixel size.
    fn selectSizeNearest(face: freetype.Face, size: u32) !void {
        var i: i32 = 0;
        var best_i: i32 = 0;
        var best_diff: i32 = 0;
        while (i < face.handle.*.num_fixed_sizes) : (i += 1) {
            const width = face.handle.*.available_sizes[@intCast(usize, i)].width;
            const diff = @intCast(i32, size) - @intCast(i32, width);
            if (i == 0 or diff < best_diff) {
                best_diff = diff;
                best_i = i;
            }
        }

        try face.selectSize(best_i);
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        return self.face.getCharIndex(cp);
    }

    /// Returns true if this font is colored. This can be used by callers to
    /// determine what kind of atlas to pass in.
    pub fn hasColor(self: Face) bool {
        return self.face.hasColor();
    }

    /// Render a glyph using the glyph index. The rendered glyph is stored in the
    /// given texture atlas.
    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *Atlas,
        glyph_index: u32,
        max_height: ?u16,
    ) !Glyph {
        // If our glyph has color, we want to render the color
        try self.face.loadGlyph(glyph_index, .{
            .render = true,
            .color = self.face.hasColor(),
        });

        const glyph = self.face.handle.*.glyph;
        const bitmap_ft = glyph.*.bitmap;

        // This bitmap is blank. I've seen it happen in a font, I don't know why.
        // If it is empty, we just return a valid glyph struct that does nothing.
        if (bitmap_ft.rows == 0) return Glyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .advance_x = 0,
        };

        // Ensure we know how to work with the font format. And assure that
        // or color depth is as expected on the texture atlas. If format is null
        // it means there is no native color format for our Atlas and we must try
        // conversion.
        const format: ?Atlas.Format = switch (bitmap_ft.pixel_mode) {
            freetype.c.FT_PIXEL_MODE_MONO => null,
            freetype.c.FT_PIXEL_MODE_GRAY => .greyscale,
            freetype.c.FT_PIXEL_MODE_BGRA => .rgba,
            else => {
                log.warn("glyph={} pixel mode={}", .{ glyph_index, bitmap_ft.pixel_mode });
                @panic("unsupported pixel mode");
            },
        };

        // If our atlas format doesn't match, look for conversions if possible.
        const bitmap_converted = if (format == null or atlas.format != format.?) blk: {
            const func = convert.map[bitmap_ft.pixel_mode].get(atlas.format) orelse {
                log.warn("glyph={} pixel mode={}", .{ glyph_index, bitmap_ft.pixel_mode });
                return error.UnsupportedPixelMode;
            };

            log.warn("converting from pixel_mode={} to atlas_format={}", .{
                bitmap_ft.pixel_mode,
                atlas.format,
            });
            break :blk try func(alloc, bitmap_ft);
        } else null;
        defer if (bitmap_converted) |bm| {
            const len = @intCast(usize, bm.pitch) * @intCast(usize, bm.rows);
            alloc.free(bm.buffer[0..len]);
        };

        // Now we need to see if we need to resize this bitmap. This can happen
        // in scenarios where we have fixed size glyphs. For example, emoji
        // can be quite large (i.e. 128x128) when we have a cell width of 24!
        // The issue with large bitmaps is they take a huge amount of space in
        // the atlas and force resizes quite frequently. We pay some CPU cost
        // up front to resize the glyph to avoid significant CPU cost to resize
        // and copy the atlas.
        const bitmap_resized: ?freetype.c.struct_FT_Bitmap_ = resized: {
            const max = max_height orelse break :resized null;
            const bm = bitmap_converted orelse bitmap_ft;
            if (bm.rows <= max) break :resized null;

            var result = bm;
            result.rows = max;
            result.width = (result.rows * bm.width) / bm.rows;
            result.pitch = @intCast(c_int, result.width) * atlas.format.depth();

            const buf = try alloc.alloc(
                u8,
                @intCast(usize, result.pitch) * @intCast(usize, result.rows),
            );
            result.buffer = buf.ptr;
            errdefer alloc.free(buf);

            if (resize.stbir_resize_uint8(
                bm.buffer,
                @intCast(c_int, bm.width),
                @intCast(c_int, bm.rows),
                bm.pitch,
                result.buffer,
                @intCast(c_int, result.width),
                @intCast(c_int, result.rows),
                result.pitch,
                atlas.format.depth(),
            ) == 0) {
                // This should never fail because this is a fairly straightforward
                // in-memory operation...
                return error.GlyphResizeFailed;
            }

            break :resized result;
        };
        defer if (bitmap_resized) |bm| {
            const len = @intCast(usize, bm.pitch) * @intCast(usize, bm.rows);
            alloc.free(bm.buffer[0..len]);
        };

        const bitmap = bitmap_resized orelse (bitmap_converted orelse bitmap_ft);
        const tgt_w = bitmap.width;
        const tgt_h = bitmap.rows;

        const region = try atlas.reserve(alloc, tgt_w, tgt_h);

        // If we have data, copy it into the atlas
        if (region.width > 0 and region.height > 0) {
            const depth = atlas.format.depth();

            // We can avoid a buffer copy if our atlas width and bitmap
            // width match and the bitmap pitch is just the width (meaning
            // the data is tightly packed).
            const needs_copy = !(tgt_w == bitmap.width and (bitmap.width * depth) == bitmap.pitch);

            // If we need to copy the data, we copy it into a temporary buffer.
            const buffer = if (needs_copy) buffer: {
                var temp = try alloc.alloc(u8, tgt_w * tgt_h * depth);
                var dst_ptr = temp;
                var src_ptr = bitmap.buffer;
                var i: usize = 0;
                while (i < bitmap.rows) : (i += 1) {
                    fastmem.copy(u8, dst_ptr, src_ptr[0 .. bitmap.width * depth]);
                    dst_ptr = dst_ptr[tgt_w * depth ..];
                    src_ptr += @intCast(usize, bitmap.pitch);
                }
                break :buffer temp;
            } else bitmap.buffer[0..(tgt_w * tgt_h * depth)];
            defer if (buffer.ptr != bitmap.buffer) alloc.free(buffer);

            // Write the glyph information into the atlas
            assert(region.width == tgt_w);
            assert(region.height == tgt_h);
            atlas.set(region, buffer);
        }

        const offset_y = offset_y: {
            // For non-scalable colorized fonts, we assume they are pictographic
            // and just center the glyph. So far this has only applied to emoji
            // fonts. Emoji fonts don't always report a correct ascender/descender
            // (mainly Apple Emoji) so we just center them. Also, since emoji font
            // aren't scalable, cell_baseline is incorrect anyways.
            //
            // NOTE(mitchellh): I don't know if this is right, this doesn't
            // _feel_ right, but it makes all my limited test cases work.
            if (self.face.hasColor() and !self.face.isScalable()) {
                break :offset_y @intCast(c_int, tgt_h);
            }

            // The Y offset is the offset of the top of our bitmap PLUS our
            // baseline calculation. The baseline calculation is so that everything
            // is properly centered when we render it out into a monospace grid.
            // Note: we add here because our X/Y is actually reversed, adding goes UP.
            break :offset_y glyph.*.bitmap_top + @floatToInt(c_int, self.metrics.cell_baseline);
        };

        // Store glyph metadata
        return Glyph{
            .width = tgt_w,
            .height = tgt_h,
            .offset_x = glyph.*.bitmap_left,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
            .advance_x = f26dot6ToFloat(glyph.*.advance.x),
        };
    }

    /// Convert 16.6 pixel format to pixels based on the scale factor of the
    /// current font size.
    fn unitsToPxY(self: Face, units: i32) i32 {
        return @intCast(i32, freetype.mulFix(
            units,
            @intCast(i32, self.face.handle.*.size.*.metrics.y_scale),
        ) >> 6);
    }

    /// Convert 26.6 pixel format to f32
    fn f26dot6ToFloat(v: freetype.c.FT_F26Dot6) f32 {
        return @intToFloat(f32, v >> 6);
    }

    /// Calculate the metrics associated with a face. This is not public because
    /// the metrics are calculated for every face and cached since they're
    /// frequently required for renderers and take up next to little memory space
    /// in the grand scheme of things.
    ///
    /// An aside: the proper way to limit memory usage due to faces is to limit
    /// the faces with DeferredFaces and reload on demand. A Face can't be converted
    /// into a DeferredFace but a Face that comes from a DeferredFace can be
    /// deinitialized anytime and reloaded with the deferred face.
    fn calcMetrics(face: freetype.Face) font.face.Metrics {
        const size_metrics = face.handle.*.size.*.metrics;

        // Cell width is calculated by preferring to use 'M' as the width of a
        // cell since 'M' is generally the widest ASCII character. If loading 'M'
        // fails then we use the max advance of the font face size metrics.
        const cell_width: f32 = cell_width: {
            if (face.getCharIndex('M')) |glyph_index| {
                if (face.loadGlyph(glyph_index, .{ .render = true })) {
                    break :cell_width f26dot6ToFloat(face.handle.*.glyph.*.advance.x);
                } else |_| {
                    // Ignore the error since we just fall back to max_advance below
                }
            }

            break :cell_width f26dot6ToFloat(size_metrics.max_advance);
        };

        // Cell height is calculated as the maximum of multiple things in order
        // to handle edge cases in fonts: (1) the height as reported in metadata
        // by the font designer (2) the maximum glyph height as measured in the
        // font and (3) the height from the ascender to an underscore.
        const cell_height: f32 = cell_height: {
            // The height as reported by the font designer.
            const face_height = f26dot6ToFloat(size_metrics.height);

            // The maximum height a glyph can take in the font
            const max_glyph_height = f26dot6ToFloat(size_metrics.ascender) -
                f26dot6ToFloat(size_metrics.descender);

            // The height of the underscore character
            const underscore_height = underscore: {
                if (face.getCharIndex('_')) |glyph_index| {
                    if (face.loadGlyph(glyph_index, .{ .render = true })) {
                        var res: f32 = f26dot6ToFloat(size_metrics.ascender);
                        res -= @intToFloat(f32, face.handle.*.glyph.*.bitmap_top);
                        res += @intToFloat(f32, face.handle.*.glyph.*.bitmap.rows);
                        break :underscore res;
                    } else |_| {
                        // Ignore the error since we just fall back below
                    }
                }

                break :underscore 0;
            };

            break :cell_height @max(
                face_height,
                @max(max_glyph_height, underscore_height),
            );
        };

        // The baseline is the descender amount for the font. This is the maximum
        // that a font may go down. We switch signs because our coordinate system
        // is reversed.
        const cell_baseline = -1 * f26dot6ToFloat(size_metrics.descender);

        // The underline position. This is a value from the top where the
        // underline should go.
        const underline_position = underline_pos: {
            // The ascender is already scaled for scalable fonts, but the
            // underline position is not.
            const ascender_px = @intCast(i32, size_metrics.ascender) >> 6;
            const declared_px = freetype.mulFix(
                face.handle.*.underline_position,
                @intCast(i32, face.handle.*.size.*.metrics.y_scale),
            ) >> 6;

            // We use the declared underline position if its available
            const declared = ascender_px - declared_px;
            if (declared > 0)
                break :underline_pos @intToFloat(f32, declared);

            // If we have no declared underline position, we go slightly under the
            // cell height (mainly: non-scalable fonts, i.e. emoji)
            break :underline_pos cell_height - 1;
        };
        const underline_thickness = @max(1, fontUnitsToPxY(
            face,
            face.handle.*.underline_thickness,
        ));

        // The strikethrough position. We use the position provided by the
        // font if it exists otherwise we calculate a best guess.
        const strikethrough: struct {
            pos: f32,
            thickness: f32,
        } = if (face.getSfntTable(.os2)) |os2| .{
            .pos = pos: {
                // Ascender is scaled, strikeout pos is not
                const ascender_px = @intCast(i32, size_metrics.ascender) >> 6;
                const declared_px = freetype.mulFix(
                    os2.yStrikeoutPosition,
                    @intCast(i32, face.handle.*.size.*.metrics.y_scale),
                ) >> 6;

                break :pos @intToFloat(f32, ascender_px - declared_px);
            },
            .thickness = @max(1, fontUnitsToPxY(face, os2.yStrikeoutSize)),
        } else .{
            .pos = cell_baseline * 0.6,
            .thickness = underline_thickness,
        };

        // log.warn("METRICS={} width={d} height={d} baseline={d} underline_pos={d} underline_thickness={d} strikethrough={}", .{
        //     size_metrics,
        //     cell_width,
        //     cell_height,
        //     cell_height - cell_baseline,
        //     underline_position,
        //     underline_thickness,
        //     strikethrough,
        // });

        return .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .cell_baseline = cell_baseline,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .strikethrough_position = strikethrough.pos,
            .strikethrough_thickness = strikethrough.thickness,
        };
    }

    /// Convert freetype "font units" to pixels using the Y scale.
    fn fontUnitsToPxY(face: freetype.Face, x: i32) f32 {
        const mul = freetype.mulFix(x, @intCast(i32, face.handle.*.size.*.metrics.y_scale));
        const div = @intToFloat(f32, mul) / 64;
        return @ceil(div);
    }
};

test {
    const testFont = @import("../test.zig").fontRegular;
    const alloc = testing.allocator;

    var lib = try Library.init();
    defer lib.deinit();

    var atlas = try Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(lib, testFont, .{ .points = 12 });
    defer ft_font.deinit();

    try testing.expectEqual(Presentation.text, ft_font.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        _ = try ft_font.renderGlyph(alloc, &atlas, ft_font.glyphIndex(i).?, null);
    }

    // Test resizing
    {
        const g1 = try ft_font.renderGlyph(alloc, &atlas, ft_font.glyphIndex('A').?, null);
        try testing.expectEqual(@as(u32, 11), g1.height);

        try ft_font.setSize(.{ .points = 24 });
        const g2 = try ft_font.renderGlyph(alloc, &atlas, ft_font.glyphIndex('A').?, null);
        try testing.expectEqual(@as(u32, 21), g2.height);
    }
}

test "color emoji" {
    const alloc = testing.allocator;
    const testFont = @import("../test.zig").fontEmoji;

    var lib = try Library.init();
    defer lib.deinit();

    var atlas = try Atlas.init(alloc, 512, .rgba);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(lib, testFont, .{ .points = 12 });
    defer ft_font.deinit();

    try testing.expectEqual(Presentation.emoji, ft_font.presentation);

    _ = try ft_font.renderGlyph(alloc, &atlas, ft_font.glyphIndex('🥸').?, null);

    // resize
    {
        const glyph = try ft_font.renderGlyph(alloc, &atlas, ft_font.glyphIndex('🥸').?, 24);
        try testing.expectEqual(@as(u32, 24), glyph.height);
    }
}

test "metrics" {
    const testFont = @import("../test.zig").fontRegular;
    const alloc = testing.allocator;

    var lib = try Library.init();
    defer lib.deinit();

    var atlas = try Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(lib, testFont, .{ .points = 12 });
    defer ft_font.deinit();

    try testing.expectEqual(font.face.Metrics{
        .cell_width = 8,
        .cell_height = 1.8e1,
        .cell_baseline = 4,
        .underline_position = 18,
        .underline_thickness = 1,
        .strikethrough_position = 10,
        .strikethrough_thickness = 1,
    }, ft_font.metrics);

    // Resize should change metrics
    try ft_font.setSize(.{ .points = 24 });
    try testing.expectEqual(font.face.Metrics{
        .cell_width = 16,
        .cell_height = 35,
        .cell_baseline = 7,
        .underline_position = 36,
        .underline_thickness = 2,
        .strikethrough_position = 20,
        .strikethrough_thickness = 2,
    }, ft_font.metrics);
}

test "mono to rgba" {
    const alloc = testing.allocator;
    const testFont = @import("../test.zig").fontEmoji;

    var lib = try Library.init();
    defer lib.deinit();

    var atlas = try Atlas.init(alloc, 512, .rgba);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(lib, testFont, .{ .points = 12 });
    defer ft_font.deinit();

    // glyph 3 is mono in Noto
    _ = try ft_font.renderGlyph(alloc, &atlas, 3, null);
}
