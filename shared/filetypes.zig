//------------------------------------------------------------------------------
// File Type Table - Single Source of Truth for File Format Detection
//------------------------------------------------------------------------------
// Table-driven file type detection using magic bytes and file extensions.
// Magic bytes take priority over extensions (a renamed file is still what
// its header says it is).
//
// Detection precedence:
//   1. Magic bytes (first 4 bytes of file)  ->  definitive match
//   2. File extension                        ->  best guess
//   3. ASCII heuristic                       ->  text vs binary fallback
//
// Usage:
//   const filetypes = @import("shared/filetypes.zig");  // or via liblaminae
//   const tag = filetypes.detectFromMagic(magic_bytes);
//   const tag = filetypes.detectFromExtension("hello.wasm");
//   const tag = filetypes.detect(magic_bytes, "hello.wasm");
//
// To add a new file type:
//   1. Add a variant to the Tag enum
//   2. Add a row to the table array
//   3. Done - detection functions iterate the table automatically
//------------------------------------------------------------------------------

const std = @import("std");

//------------------------------------------------------------------------------
// Tag Enum
//------------------------------------------------------------------------------

pub const Tag = enum {
    elf,
    wasm,
    zig_src,
    txt,
    bin,
    unknown,

    pub fn label(self: Tag) []const u8 {
        return switch (self) {
            .elf => "elf",
            .wasm => "wasm",
            .zig_src => "zig",
            .txt => "txt",
            .bin => "bin",
            .unknown => "",
        };
    }
};

//------------------------------------------------------------------------------
// File Type Entry
//------------------------------------------------------------------------------

pub const FileTypeEntry = struct {
    tag: Tag,

    /// Magic bytes at offset 0 (null = no magic signature for this type)
    magic: ?[4]u8 = null,

    /// File extensions associated with this type (including the dot)
    extensions: []const []const u8 = &.{},
};

//------------------------------------------------------------------------------
// File Type Table
//------------------------------------------------------------------------------

pub const table = [_]FileTypeEntry{
    // Types with magic bytes (definitive detection)
    .{
        .tag = .elf,
        .magic = .{ 0x7f, 'E', 'L', 'F' },
        .extensions = &.{".elf"},
    },
    .{
        .tag = .wasm,
        .magic = .{ 0x00, 'a', 's', 'm' },
        .extensions = &.{".wasm"},
    },

    // Types without magic bytes (extension-only detection)
    .{
        .tag = .zig_src,
        .extensions = &.{".zig"},
    },
    .{
        .tag = .txt,
        .extensions = &.{ ".txt", ".md", ".log" },
    },
    .{
        .tag = .bin,
        .extensions = &.{".bin"},
    },
};

//------------------------------------------------------------------------------
// Accessors
//------------------------------------------------------------------------------

/// Slice view of the table (for iteration)
pub fn all() []const FileTypeEntry {
    return &table;
}

//------------------------------------------------------------------------------
// Detection Functions
//------------------------------------------------------------------------------

/// Detect file type from magic bytes (first 4 bytes of file).
/// Returns null if no magic signature matches.
pub fn detectFromMagic(magic: [4]u8) ?Tag {
    for (table) |entry| {
        if (entry.magic) |m| {
            if (std.mem.eql(u8, &m, &magic)) return entry.tag;
        }
    }
    return null;
}

/// Detect file type from file name/extension.
/// Returns null if no extension matches.
pub fn detectFromExtension(name: []const u8) ?Tag {
    for (table) |entry| {
        for (entry.extensions) |ext| {
            if (endsWith(name, ext)) return entry.tag;
        }
    }
    return null;
}

/// Full detection with precedence: magic -> extension -> ASCII heuristic.
/// Pass null for magic when file contents are unavailable.
pub fn detect(magic: ?[4]u8, name: []const u8) Tag {
    if (magic) |m| {
        if (detectFromMagic(m)) |tag| return tag;
    }
    if (detectFromExtension(name)) |tag| return tag;
    if (magic) |m| {
        return if (isTextBytes(&m)) .txt else .bin;
    }
    return .unknown;
}

//------------------------------------------------------------------------------
// Helpers
//------------------------------------------------------------------------------

/// Check if all bytes look like printable ASCII / common whitespace.
pub fn isTextBytes(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b < 0x09 or (b > 0x0d and b < 0x20) or b >= 0x7f) return false;
    }
    return true;
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

//------------------------------------------------------------------------------
// Comptime Validation
//------------------------------------------------------------------------------

comptime {
    for (table, 0..) |entry, i| {
        for (table[i + 1 ..]) |other| {
            // No duplicate tags
            if (entry.tag == other.tag) {
                @compileError("Duplicate file type tag: " ++ entry.tag.label());
            }

            // No duplicate magic signatures
            if (entry.magic) |m| {
                if (other.magic) |om| {
                    if (std.mem.eql(u8, &m, &om)) {
                        @compileError("Duplicate magic bytes for: " ++ entry.tag.label());
                    }
                }
            }

            // No duplicate extensions across entries
            for (entry.extensions) |ext| {
                for (other.extensions) |oext| {
                    if (std.mem.eql(u8, ext, oext)) {
                        @compileError("Duplicate extension '" ++ ext ++ "' in: " ++ other.tag.label());
                    }
                }
            }
        }
    }
}
