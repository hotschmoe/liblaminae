//------------------------------------------------------------------------------
// QEMU fw_cfg Helper - DMA-only access
//
// Hides selector constants, the DmaAccess struct layout, the big-endian
// byteswap dance, and the staging-page / control-bit construction from
// every consumer.
//
// Why DMA-only: bytewise access via the FW_CFG_DATA register is broken on
// QEMU 11+ for some selectors (write-side returns silently with no data
// transferred). DMA always works; the helper hides the choice so drivers
// cannot accidentally pick the broken path.
//
// Mirrors lib/man/virtio.zig's EL0-only style:
//   - uses sys_map_device + sys_alloc_dma, never kernel MMIO directly
//   - zero std library dependencies
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// MMIO + DMA primitives only (sys_map_device / sys_alloc_dma). No peer ICC.
pub const tier: u8 = 1;

//------------------------------------------------------------------------------
// Register offsets within the fw_cfg MMIO window
//------------------------------------------------------------------------------

// FW_CFG_DATA    = +0x00  (u8 read/write, bytewise -- not used here)
// FW_CFG_SEL     = +0x08  (u16 BE write)
// FW_CFG_DMA     = +0x10  (u64 BE write -- GPA of DmaAccess struct)

const REG_SELECTOR: u32 = 0x08;
const REG_DMA: u32 = 0x10;

//------------------------------------------------------------------------------
// DMA control bits (packed into DmaAccess.control, big-endian on the wire)
//------------------------------------------------------------------------------

// Bit 0: device sets this if the operation failed
const DMA_CTL_ERROR: u32 = 0x01;
// Bit 1: read -- device copies fw_cfg file data into guest memory
const DMA_CTL_READ: u32 = 0x02;
// Bit 3: selector value in upper 16 bits is valid; device latches it
const DMA_CTL_SELECT: u32 = 0x08;
// Bit 4: write -- guest copies data into the fw_cfg file's backing buffer
const DMA_CTL_WRITE: u32 = 0x10;

//------------------------------------------------------------------------------
// Public types
//------------------------------------------------------------------------------

/// Well-known fw_cfg selector values for the QEMU virt machine.
/// The enum is non-exhaustive (`_`) so callers can pass dynamic selectors
/// returned by findFile() without casting.
pub const Selector = enum(u16) {
    signature = 0x0000,
    id = 0x0001,
    uuid = 0x0002,
    ram_size = 0x0003,
    nographic = 0x0004,
    nb_cpus = 0x0005,
    machine_id = 0x0006,
    kernel_addr = 0x0007,
    cmdline = 0x0008,
    initrd_addr = 0x000A,
    e820_table = 0x000D,
    file_dir = 0x0019,
    _,
};

/// fw_cfg DMA transfer descriptor.
///
/// Layout (24 bytes, all fields big-endian on the wire):
///
///   offset  0 : control u32   -- op flags | (selector << 16)
///   offset  4 : length  u32   -- byte count of the transfer
///   offset  8 : address u64   -- guest physical address of the data buffer
///
/// The struct must reside in a DMA-capable buffer (page-aligned, obtained via
/// sys_alloc_dma). After the caller writes the struct's GPA to REG_DMA, QEMU
/// executes the transfer synchronously and clears control to 0 on success, or
/// sets bit 0 (DMA_CTL_ERROR) on failure.
pub const DmaAccess = extern struct {
    control: u32 align(1),
    length: u32 align(1),
    address: u64 align(1),
};

/// File-directory entry returned by fw_cfg selector 0x0019.
/// All multi-byte fields are big-endian on the wire.
pub const FileEntry = extern struct {
    size: u32 align(1),
    select: u16 align(1),
    reserved: u16 align(1),
    name: [56]u8,
};

pub const Error = error{
    DeviceMappingFailed,
    DmaAllocFailed,
    DmaTransferFailed,
    FileNotFound,
};

//------------------------------------------------------------------------------
// Internal helpers
//------------------------------------------------------------------------------

inline fn selReg(va_base: u64) *volatile u16 {
    return @ptrFromInt(va_base + REG_SELECTOR);
}

inline fn dmaReg(va_base: u64) *volatile u64 {
    return @ptrFromInt(va_base + REG_DMA);
}

/// Latch `sel` into the fw_cfg selector register. The register is big-endian.
fn select(va_base: u64, sel: u16) void {
    selReg(va_base).* = @byteSwap(sel);
}

/// Read `len` bytes sequentially from the data register (offset 0x00).
/// Used only for the file-dir count header, which has no DMA shortcut.
fn readBytewise(va_base: u64, buf: [*]u8, len: usize) void {
    const data: *volatile u8 = @ptrFromInt(va_base);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = data.*;
    }
}

/// Submit `access` (whose GPA is `access_pa`) to the DMA register and verify
/// completion. `access_va` is the CPU-accessible mirror of the same page so we
/// can spin-read the control field after submission.
fn submitAndCheck(
    va_base: u64,
    access_va: u64,
    access_pa: u64,
) Error!void {
    // Trigger: write the GPA of the DmaAccess struct (big-endian u64) to REG_DMA.
    // QEMU consumes the struct synchronously in this store.
    dmaReg(va_base).* = @byteSwap(access_pa);

    // QEMU completes DMA synchronously on MMIO store return; read back to confirm.
    const ctl_after = @byteSwap(@as(*volatile u32, @ptrFromInt(access_va)).*);
    if ((ctl_after & DMA_CTL_ERROR) != 0) {
        return Error.DmaTransferFailed;
    }
}

//------------------------------------------------------------------------------
// Public API
//------------------------------------------------------------------------------

/// Write `buf` into fw_cfg selector `sel` via DMA.
///
/// `va_base` is the user-space VA returned by sys_map_device for the fw_cfg
/// MMIO region (QEMU virt: 0x09020000, size 0x1000).
///
/// A single staging page is allocated per call via sys_alloc_dma. The page
/// holds both the payload copy and the DmaAccess descriptor:
///
///   offset   0 .. len-1  : copy of buf
///   offset  64 .. 87     : DmaAccess struct (24 bytes)
///
/// The 64-byte gap between payload and DmaAccess is a natural separator;
/// the two must not overlap (DmaAccess.address points at offset 0).
pub fn write(va_base: u64, sel: Selector, buf: []const u8) Error!void {
    // One page holds the payload + DmaAccess with room to spare.
    // Caller must keep buf.len <= 4072 (0x1000 - 24) to fit in one page.
    const dma_r = sys.alloc_dma(0x1000);
    if (@as(i64, @bitCast(dma_r)) < 0) return Error.DmaAllocFailed;

    const bus = sys.DmaResult.busAddr(dma_r);
    const va = sys.DmaResult.va(dma_r);

    const PAYLOAD_OFF: u64 = 0;
    const ACCESS_OFF: u64 = 64;

    const dst: [*]u8 = @ptrFromInt(va + PAYLOAD_OFF);
    @memcpy(dst[0..buf.len], buf);

    const sel_raw: u16 = @intFromEnum(sel);
    const ctl: u32 = (@as(u32, sel_raw) << 16) | DMA_CTL_SELECT | DMA_CTL_WRITE;
    const access: *DmaAccess = @ptrFromInt(va + ACCESS_OFF);
    access.* = .{
        .control = @byteSwap(ctl),
        .length = @byteSwap(@as(u32, @intCast(buf.len))),
        .address = @byteSwap(bus + PAYLOAD_OFF),
    };

    try submitAndCheck(va_base, va + ACCESS_OFF, bus + ACCESS_OFF);
}

/// Read from fw_cfg selector `sel` into `buf` via DMA.
///
/// `va_base` is the user-space VA returned by sys_map_device for the fw_cfg
/// MMIO region.
///
/// A staging page is allocated; QEMU DMAs data from the fw_cfg file into it,
/// then the helper copies from staging into `buf`. This round-trip is required
/// because QEMU writes to the bus address -- which may differ from the VA --
/// and the copy ensures buf is populated correctly regardless of DMA mapping.
pub fn read(va_base: u64, sel: Selector, buf: []u8) Error!void {
    const dma_r = sys.alloc_dma(0x1000);
    if (@as(i64, @bitCast(dma_r)) < 0) return Error.DmaAllocFailed;

    const bus = sys.DmaResult.busAddr(dma_r);
    const va = sys.DmaResult.va(dma_r);

    const PAYLOAD_OFF: u64 = 0;
    const ACCESS_OFF: u64 = 64;

    const sel_raw: u16 = @intFromEnum(sel);
    // READ | SELECT: device copies fw_cfg file bytes into our staging page.
    const ctl: u32 = (@as(u32, sel_raw) << 16) | DMA_CTL_SELECT | DMA_CTL_READ;
    const access: *DmaAccess = @ptrFromInt(va + ACCESS_OFF);
    access.* = .{
        .control = @byteSwap(ctl),
        .length = @byteSwap(@as(u32, @intCast(buf.len))),
        .address = @byteSwap(bus + PAYLOAD_OFF),
    };

    try submitAndCheck(va_base, va + ACCESS_OFF, bus + ACCESS_OFF);

    const src: [*]const u8 = @ptrFromInt(va + PAYLOAD_OFF);
    @memcpy(buf, src[0..buf.len]);
}

/// Walk the fw_cfg file directory (selector 0x0019) looking for `name`.
/// Returns the selector value for the entry if found, null otherwise.
///
/// `name` is compared against the null-padded 56-byte name field; both
/// null-terminated and exact-length matches are accepted.
///
/// Note: the file-dir count header is read bytewise (4 bytes). This is the
/// one place where bytewise access is safe: the count is written before any
/// file entries, and QEMU does not use a write callback for selector 0x0019.
/// The entries themselves are read bytewise for the same reason -- this is a
/// read-only metadata selector, not a writable file, so DMA READ would
/// require a staging page per entry; bytewise is simpler and correct here.
pub fn findFile(va_base: u64, name: []const u8) Error!?u16 {
    select(va_base, @intFromEnum(Selector.file_dir));

    // First 4 bytes: entry count, big-endian.
    var count_buf: [4]u8 = undefined;
    readBytewise(va_base, &count_buf, 4);
    const count = @byteSwap(@as(u32, @bitCast(count_buf)));

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var entry: FileEntry = undefined;
        readBytewise(va_base, @ptrCast(&entry), @sizeOf(FileEntry));
        if (nameMatches(entry.name, name)) {
            return @byteSwap(entry.select);
        }
    }
    return null;
}

/// Compare the null-padded 56-byte fw_cfg name buffer against `target`.
fn nameMatches(name: [56]u8, target: []const u8) bool {
    if (target.len > 56) return false;
    var i: usize = 0;
    while (i < target.len) : (i += 1) {
        if (name[i] != target[i]) return false;
    }
    if (target.len < 56 and name[target.len] != 0) return false;
    return true;
}
