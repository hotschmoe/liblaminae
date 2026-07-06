//------------------------------------------------------------------------------
// fbcon - framebuffer text console
//
// A scrolling character-grid console rendered on top of lib/man/font.zig.
// Turns a linear framebuffer into a putChar/puts surface: a fixed cell grid,
// a block cursor, line wrap, and scroll-on-overflow. Pure T1 vocabulary --
// glyph blits into a caller-supplied framebuffer, no syscalls, no allocation,
// no peer ICC.
//
// FbConsole is generic over the grid dimensions so the cell backing store is
// a comptime-sized array the caller owns (typically in BSS). For an 800x600
// XRGB8888 surface with the 8x16 font that is FbConsole(100, 37).
//
// A minimal CSI (ESC '[') parser honors the three sequences the Laminae shell
// emits for in-place line editing -- cursor-left (D), cursor-right (C), and
// erase-to-end-of-line (K). Any other escape is consumed silently so it never
// lands on screen as glyph garbage.
//
// Rendering cost: a printable byte is one glyph blit (plus a cursor erase/draw
// pair); a scroll is a full grid redraw. Both are sub-frame under KVM at
// 800x600 -- see docs/roadmap/06_DISPLAY_DRIVER.md.
//------------------------------------------------------------------------------

// Shared with the kernel framebuffer console -- one font, one blitter.
const font = @import("../shared/font.zig");

pub const tier: u8 = 1;

/// Cell advance matches the font's fixed 8x16 glyph box.
pub const CELL_W: u32 = font.GLYPH_W;
pub const CELL_H: u32 = font.GLYPH_H;

/// Escape-sequence parser state. `normal` renders bytes; `esc`/`csi` accumulate
/// an ESC '[' ... sequence without touching the screen.
const EscState = enum { normal, esc, csi };

/// A scrolling text console over a `cols` x `rows` character grid.
pub fn FbConsole(comptime cols: u32, comptime rows: u32) type {
    comptime {
        if (cols == 0 or rows == 0) @compileError("FbConsole grid must be non-empty");
    }
    return struct {
        const Self = @This();
        pub const COLS = cols;
        pub const ROWS = rows;

        fb: [*]volatile u32,
        stride_px: u32,
        fg: u32,
        bg: u32,

        /// Cell contents, row-major. Each cell holds one printable byte
        /// (0x20..0x7E); blank cells hold ' '.
        cells: [rows][cols]u8 = [_][cols]u8{[_]u8{' '} ** cols} ** rows,

        cur_col: u32 = 0,
        cur_row: u32 = 0,

        esc: EscState = .normal,
        esc_num: u32 = 0,
        esc_has_num: bool = false,

        /// Construct a console over `fb`. The grid is blank; the framebuffer is
        /// not touched until the first write or an explicit `clear()`.
        pub fn init(fb: [*]volatile u32, stride_px: u32, fg: u32, bg: u32) Self {
            return .{ .fb = fb, .stride_px = stride_px, .fg = fg, .bg = bg };
        }

        //----------------------------------------------------------------------
        // Rendering primitives
        //----------------------------------------------------------------------

        /// Blit one grid cell. `invert` swaps fg/bg, which is how the cursor
        /// cell is drawn (a blank inverted cell reads as a solid block).
        fn renderCell(self: *Self, col: u32, row: u32, invert: bool) void {
            const ch = self.cells[row][col];
            const fg = if (invert) self.bg else self.fg;
            const bg = if (invert) self.fg else self.bg;
            font.drawChar(self.fb, self.stride_px, col * CELL_W, row * CELL_H, ch, fg, bg);
        }

        fn showCursor(self: *Self) void {
            self.renderCell(self.cur_col, self.cur_row, true);
        }

        fn hideCursor(self: *Self) void {
            self.renderCell(self.cur_col, self.cur_row, false);
        }

        /// Redraw every cell (no cursor). Used after a scroll or `clear()`.
        fn redraw(self: *Self) void {
            var r: u32 = 0;
            while (r < rows) : (r += 1) {
                var c: u32 = 0;
                while (c < cols) : (c += 1) self.renderCell(c, r, false);
            }
        }

        /// Blank the grid, home the cursor, and repaint the surface.
        pub fn clear(self: *Self) void {
            self.cells = [_][cols]u8{[_]u8{' '} ** cols} ** rows;
            self.cur_col = 0;
            self.cur_row = 0;
            self.esc = .normal;
            self.redraw();
            self.showCursor();
        }

        //----------------------------------------------------------------------
        // Grid motion
        //----------------------------------------------------------------------

        /// Shift every row up by one, blank the last row, and repaint.
        fn scroll(self: *Self) void {
            var r: u32 = 1;
            while (r < rows) : (r += 1) self.cells[r - 1] = self.cells[r];
            self.cells[rows - 1] = [_]u8{' '} ** cols;
            self.redraw();
        }

        /// Move to the next line, scrolling if already on the last row.
        fn lineFeed(self: *Self) void {
            if (self.cur_row + 1 >= rows) {
                self.scroll();
            } else {
                self.cur_row += 1;
            }
        }

        //----------------------------------------------------------------------
        // Byte feed
        //----------------------------------------------------------------------

        /// Feed one byte through the parser + grid. The cursor invariant
        /// (current cell drawn inverted, all others normal) is preserved
        /// across every call.
        pub fn putChar(self: *Self, c: u8) void {
            switch (self.esc) {
                .normal => {
                    self.hideCursor();
                    self.feedNormal(c);
                    self.showCursor();
                },
                .esc => {
                    if (c == '[') {
                        self.esc = .csi;
                        self.esc_num = 0;
                        self.esc_has_num = false;
                    } else {
                        // Unsupported two-byte escape -- consumed, not drawn.
                        self.esc = .normal;
                    }
                },
                .csi => {
                    if (c >= '0' and c <= '9') {
                        self.esc_num = self.esc_num *% 10 +% (c - '0');
                        self.esc_has_num = true;
                    } else {
                        self.hideCursor();
                        self.finishCsi(c);
                        self.showCursor();
                        self.esc = .normal;
                    }
                },
            }
        }

        /// Feed a byte slice.
        pub fn puts(self: *Self, s: []const u8) void {
            for (s) |c| self.putChar(c);
        }

        /// Handle one byte in the normal (non-escape) state.
        fn feedNormal(self: *Self, c: u8) void {
            switch (c) {
                '\n' => {
                    self.cur_col = 0;
                    self.lineFeed();
                },
                '\r' => self.cur_col = 0,
                0x08 => self.cur_col -|= 1, // backspace
                '\t' => {
                    self.cur_col = (self.cur_col / 8 + 1) * 8;
                    if (self.cur_col >= cols) {
                        self.cur_col = 0;
                        self.lineFeed();
                    }
                },
                0x20...0x7E => {
                    self.cells[self.cur_row][self.cur_col] = c;
                    self.renderCell(self.cur_col, self.cur_row, false);
                    self.cur_col += 1;
                    if (self.cur_col >= cols) {
                        self.cur_col = 0;
                        self.lineFeed();
                    }
                },
                else => {}, // other control bytes are ignored
            }
        }

        /// Apply a completed CSI sequence. `final` is the terminating letter;
        /// `esc_num` holds the (optional) numeric parameter.
        fn finishCsi(self: *Self, final: u8) void {
            const n: u32 = if (self.esc_has_num and self.esc_num > 0) self.esc_num else 1;
            switch (final) {
                'D' => self.cur_col -|= n, // cursor left (saturating)
                'C' => {
                    self.cur_col += n;
                    if (self.cur_col >= cols) self.cur_col = cols - 1;
                },
                'K' => {
                    // Erase from the cursor to the end of the line.
                    var c = self.cur_col;
                    while (c < cols) : (c += 1) {
                        self.cells[self.cur_row][c] = ' ';
                        self.renderCell(c, self.cur_row, false);
                    }
                },
                else => {}, // unsupported CSI -- consumed, not rendered
            }
        }
    };
}
