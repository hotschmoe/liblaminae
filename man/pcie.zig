//------------------------------------------------------------------------------
// PCIe User-Space Library (ECAM transport)
//
// Config-space access, bus enumeration, BAR sizing/assignment, and bridge
// setup for driver containers on ECAM-based PCIe host controllers.
//
// Target: MS-R1 (CIX CP8180 "sky1"). Its five root complexes expose plain
// ECAM config windows (verified against the vendor kernel on device1; see
// docs/roadmap/ms_r1_deployment/findings.md "Device1 NIC + USB survey").
// Nothing here is sky1-specific except the assumption that config space is
// memory-mapped ECAM -- QEMU virt's gpex host bridge satisfies the same
// contract, so the library is testable under QEMU with PCI devices.
//
// Design (mirrors lib/man/virtio.zig):
// - Zero std library dependencies (freestanding)
// - Works on caller-mapped regions: the driver maps the ECAM window (or the
//   1 MB per-bus slice it needs) via sys_map_device and hands the VA here
// - No allocation; enumeration reports functions through a caller callback
//------------------------------------------------------------------------------

const barriers = @import("../shared/arch/barriers_el0.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// PCIe ECAM vocabulary -- works on caller-mapped config/BAR windows.
/// No syscalls, no peer ICC.
pub const tier: u8 = 1;

//==============================================================================
// Configuration Space Layout (PCI 3.0 / PCIe base spec)
//==============================================================================

pub const Config = struct {
    pub const VENDOR_ID: u32 = 0x00; // u16
    pub const DEVICE_ID: u32 = 0x02; // u16
    pub const COMMAND: u32 = 0x04; // u16
    pub const STATUS: u32 = 0x06; // u16
    pub const REVISION: u32 = 0x08; // u8
    pub const CLASS_CODE: u32 = 0x09; // u24: prog-if, subclass, class
    pub const CACHE_LINE: u32 = 0x0C; // u8
    pub const HEADER_TYPE: u32 = 0x0E; // u8 (bit 7 = multifunction)
    pub const BAR0: u32 = 0x10;
    pub const CAP_PTR: u32 = 0x34; // u8
    pub const INT_LINE: u32 = 0x3C; // u8
    pub const INT_PIN: u32 = 0x3D; // u8 (1=INTA..4=INTD, 0=none)

    // Type 1 (bridge) header
    pub const PRIMARY_BUS: u32 = 0x18; // u8
    pub const SECONDARY_BUS: u32 = 0x19; // u8
    pub const SUBORDINATE_BUS: u32 = 0x1A; // u8
    pub const MEM_BASE: u32 = 0x20; // u16 (upper 12 bits of 32-bit base)
    pub const MEM_LIMIT: u32 = 0x22; // u16
    pub const PREF_MEM_BASE: u32 = 0x24; // u16
    pub const PREF_MEM_LIMIT: u32 = 0x26; // u16
    pub const BRIDGE_CONTROL: u32 = 0x3E; // u16
};

pub const Command = struct {
    pub const IO_ENABLE: u16 = 1 << 0;
    pub const MEM_ENABLE: u16 = 1 << 1;
    pub const BUS_MASTER: u16 = 1 << 2;
    pub const INTX_DISABLE: u16 = 1 << 10;
};

pub const HeaderType = struct {
    pub const ENDPOINT: u8 = 0x00;
    pub const BRIDGE: u8 = 0x01;
    pub const MULTIFUNCTION: u8 = 0x80;
};

pub const CapId = struct {
    pub const POWER_MGMT: u8 = 0x01;
    pub const MSI: u8 = 0x05;
    pub const PCIE: u8 = 0x10;
    pub const MSIX: u8 = 0x11;
};

/// (class, subclass, prog-if) triples we care about.
pub const ClassCode = struct {
    pub const ETHERNET: u24 = 0x020000;
    pub const NVME: u24 = 0x010802;
    pub const USB_XHCI: u24 = 0x0C0330;
    pub const PCI_BRIDGE: u24 = 0x060400;
};

pub const INVALID_VENDOR: u16 = 0xFFFF;

//==============================================================================
// ECAM Accessor
//==============================================================================

/// One ECAM window: a caller-mapped VA covering config space for buses
/// [bus_start, bus_start + num_buses). ECAM offset within the window:
/// (bus - bus_start) << 20 | dev << 15 | fn << 12 | reg.
pub const Ecam = struct {
    va_base: u64,
    bus_start: u8,
    num_buses: u16,

    pub fn init(va_base: u64, bus_start: u8, num_buses: u16) Ecam {
        return .{ .va_base = va_base, .bus_start = bus_start, .num_buses = num_buses };
    }

    pub fn contains(self: *const Ecam, bus: u8) bool {
        return bus >= self.bus_start and
            (@as(u16, bus) - self.bus_start) < self.num_buses;
    }

    fn fnBase(self: *const Ecam, bus: u8, dev: u5, func: u3) u64 {
        const bus_off: u64 = @as(u64, bus - self.bus_start) << 20;
        return self.va_base + bus_off + (@as(u64, dev) << 15) + (@as(u64, func) << 12);
    }

    pub fn read32(self: *const Ecam, bus: u8, dev: u5, func: u3, reg: u32) u32 {
        const ptr: *volatile u32 = @ptrFromInt(self.fnBase(bus, dev, func) + (reg & ~@as(u32, 3)));
        return ptr.*;
    }

    pub fn write32(self: *const Ecam, bus: u8, dev: u5, func: u3, reg: u32, value: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(self.fnBase(bus, dev, func) + (reg & ~@as(u32, 3)));
        ptr.* = value;
    }

    /// Sub-word reads go through aligned 32-bit accesses: some root
    /// complexes (and KVM-emulated MMIO paths) reject narrow config reads.
    /// Same lesson as netd's virtio config-space quirk.
    pub fn read16(self: *const Ecam, bus: u8, dev: u5, func: u3, reg: u32) u16 {
        const word = self.read32(bus, dev, func, reg);
        return @truncate(word >> @intCast((reg & 2) * 8));
    }

    pub fn read8(self: *const Ecam, bus: u8, dev: u5, func: u3, reg: u32) u8 {
        const word = self.read32(bus, dev, func, reg);
        return @truncate(word >> @intCast((reg & 3) * 8));
    }

    pub fn write16(self: *const Ecam, bus: u8, dev: u5, func: u3, reg: u32, value: u16) void {
        const shift: u5 = @intCast((reg & 2) * 8);
        const mask = @as(u32, 0xFFFF) << shift;
        const word = self.read32(bus, dev, func, reg);
        self.write32(bus, dev, func, reg, (word & ~mask) | (@as(u32, value) << shift));
    }

    pub fn write8(self: *const Ecam, bus: u8, dev: u5, func: u3, reg: u32, value: u8) void {
        const shift: u5 = @intCast((reg & 3) * 8);
        const mask = @as(u32, 0xFF) << shift;
        const word = self.read32(bus, dev, func, reg);
        self.write32(bus, dev, func, reg, (word & ~mask) | (@as(u32, value) << shift));
    }
};

//==============================================================================
// Function Handle
//==============================================================================

/// A discovered PCI function. Thin handle: all state lives in config space.
pub const Function = struct {
    ecam: *const Ecam,
    bus: u8,
    dev: u5,
    func: u3,

    pub fn vendorId(self: *const Function) u16 {
        return self.ecam.read16(self.bus, self.dev, self.func, Config.VENDOR_ID);
    }

    pub fn deviceId(self: *const Function) u16 {
        return self.ecam.read16(self.bus, self.dev, self.func, Config.DEVICE_ID);
    }

    /// (class << 16) | (subclass << 8) | prog_if
    pub fn classCode(self: *const Function) u24 {
        return @truncate(self.ecam.read32(self.bus, self.dev, self.func, Config.REVISION) >> 8);
    }

    pub fn headerType(self: *const Function) u8 {
        return self.ecam.read8(self.bus, self.dev, self.func, Config.HEADER_TYPE) & 0x7F;
    }

    pub fn isBridge(self: *const Function) bool {
        return self.headerType() == HeaderType.BRIDGE;
    }

    pub fn readCommand(self: *const Function) u16 {
        return self.ecam.read16(self.bus, self.dev, self.func, Config.COMMAND);
    }

    pub fn writeCommand(self: *const Function, value: u16) void {
        self.ecam.write16(self.bus, self.dev, self.func, Config.COMMAND, value);
    }

    /// Enable memory decode + bus mastering (DMA). Call after BARs are set.
    pub fn enable(self: *const Function) void {
        self.writeCommand(self.readCommand() | Command.MEM_ENABLE | Command.BUS_MASTER);
        barriers.dataMemoryBarrier();
    }

    /// INT_PIN: 0 = no legacy interrupt, 1..4 = INTA..INTD.
    pub fn interruptPin(self: *const Function) u8 {
        return self.ecam.read8(self.bus, self.dev, self.func, Config.INT_PIN);
    }

    //--------------------------------------------------------------------------
    // BARs
    //--------------------------------------------------------------------------

    pub const Bar = struct {
        /// BAR slot index (0..5); 64-bit BARs consume this slot and the next
        index: u8,
        /// Current programmed bus address (0 if unassigned)
        addr: u64,
        /// Decoded size in bytes (0 if BAR unimplemented)
        size: u64,
        is_io: bool,
        is_64bit: bool,
        is_prefetchable: bool,
    };

    /// Read and size one BAR. Sizing writes all-ones then restores the
    /// original value; do this before enabling memory decode.
    /// Returns .size = 0 for unimplemented BARs.
    pub fn readBar(self: *const Function, index: u8) Bar {
        const reg = Config.BAR0 + @as(u32, index) * 4;
        const orig = self.ecam.read32(self.bus, self.dev, self.func, reg);

        const is_io = (orig & 1) != 0;
        const is_64bit = !is_io and ((orig >> 1) & 3) == 2;
        const is_pref = !is_io and (orig & 8) != 0;
        const addr_mask: u32 = if (is_io) ~@as(u32, 3) else ~@as(u32, 15);

        self.ecam.write32(self.bus, self.dev, self.func, reg, 0xFFFF_FFFF);
        const sized_lo = self.ecam.read32(self.bus, self.dev, self.func, reg);
        self.ecam.write32(self.bus, self.dev, self.func, reg, orig);

        var addr: u64 = orig & addr_mask;
        var size_mask: u64 = sized_lo & addr_mask;

        if (is_64bit) {
            const reg_hi = reg + 4;
            const orig_hi = self.ecam.read32(self.bus, self.dev, self.func, reg_hi);
            self.ecam.write32(self.bus, self.dev, self.func, reg_hi, 0xFFFF_FFFF);
            const sized_hi = self.ecam.read32(self.bus, self.dev, self.func, reg_hi);
            self.ecam.write32(self.bus, self.dev, self.func, reg_hi, orig_hi);
            addr |= @as(u64, orig_hi) << 32;
            size_mask |= @as(u64, sized_hi) << 32;
        } else if (size_mask != 0) {
            // 32-bit BAR: unwritten high bits read back as 0; treat the
            // mask as sign-extended within 32 bits only.
            size_mask |= @as(u64, 0xFFFF_FFFF) << 32;
        }

        return .{
            .index = index,
            .addr = addr,
            .size = if (size_mask == 0) 0 else (~size_mask) + 1,
            .is_io = is_io,
            .is_64bit = is_64bit,
            .is_prefetchable = is_pref,
        };
    }

    /// Program a BAR with a bus address. Caller owns address allocation.
    pub fn writeBar(self: *const Function, index: u8, addr: u64) void {
        const reg = Config.BAR0 + @as(u32, index) * 4;
        const orig = self.ecam.read32(self.bus, self.dev, self.func, reg);
        const low_flags: u32 = if ((orig & 1) != 0) orig & 3 else orig & 15;
        self.ecam.write32(self.bus, self.dev, self.func, reg, @as(u32, @truncate(addr)) | low_flags);
        if ((orig & 1) == 0 and ((orig >> 1) & 3) == 2) {
            self.ecam.write32(self.bus, self.dev, self.func, reg + 4, @truncate(addr >> 32));
        }
    }

    //--------------------------------------------------------------------------
    // Capabilities
    //--------------------------------------------------------------------------

    /// Find a capability by ID; returns its config-space offset or 0.
    pub fn findCapability(self: *const Function, cap_id: u8) u32 {
        const status = self.ecam.read16(self.bus, self.dev, self.func, Config.STATUS);
        if ((status & 0x10) == 0) return 0; // no capability list

        var offset: u32 = self.ecam.read8(self.bus, self.dev, self.func, Config.CAP_PTR);
        var guard: u32 = 0;
        while (offset >= 0x40 and guard < 48) : (guard += 1) {
            offset &= ~@as(u32, 3);
            const id = self.ecam.read8(self.bus, self.dev, self.func, offset);
            if (id == cap_id) return offset;
            offset = self.ecam.read8(self.bus, self.dev, self.func, offset + 1);
        }
        return 0;
    }
};

//==============================================================================
// Bridge Setup
//==============================================================================

/// Program a type-1 bridge's bus numbers and 32-bit memory forwarding
/// window, then enable it. mem_base/mem_limit are bus addresses; both are
/// 1 MB-aligned per spec (limit is inclusive: last byte of the window).
pub fn setupBridge(
    bridge: *const Function,
    secondary_bus: u8,
    subordinate_bus: u8,
    mem_base: u32,
    mem_limit: u32,
) void {
    const e = bridge.ecam;
    e.write8(bridge.bus, bridge.dev, bridge.func, Config.PRIMARY_BUS, bridge.bus);
    e.write8(bridge.bus, bridge.dev, bridge.func, Config.SECONDARY_BUS, secondary_bus);
    e.write8(bridge.bus, bridge.dev, bridge.func, Config.SUBORDINATE_BUS, subordinate_bus);

    e.write16(bridge.bus, bridge.dev, bridge.func, Config.MEM_BASE, @truncate(mem_base >> 16));
    e.write16(bridge.bus, bridge.dev, bridge.func, Config.MEM_LIMIT, @truncate(mem_limit >> 16));

    // Close the prefetchable window (base > limit) -- we allocate
    // everything from the non-prefetchable 32-bit window for now.
    e.write16(bridge.bus, bridge.dev, bridge.func, Config.PREF_MEM_BASE, 0xFFF0);
    e.write16(bridge.bus, bridge.dev, bridge.func, Config.PREF_MEM_LIMIT, 0x0000);

    bridge.writeCommand(bridge.readCommand() | Command.MEM_ENABLE | Command.BUS_MASTER);
    barriers.dataMemoryBarrier();
}

//==============================================================================
// Enumeration
//==============================================================================

/// Depth-first scan of one ECAM window. Assumes bus numbers behind bridges
/// are already programmed (by firmware, or by the caller via setupBridge);
/// this walks whatever config space currently exposes and reports every
/// live function through `visit`. Return false from `visit` to stop early.
pub fn enumerate(
    ecam: *const Ecam,
    context: anytype,
    comptime visit: fn (@TypeOf(context), Function) bool,
) void {
    var bus_i: u16 = 0;
    while (bus_i < ecam.num_buses) : (bus_i += 1) {
        const bus: u8 = @intCast(ecam.bus_start + bus_i);
        var dev: u6 = 0;
        while (dev < 32) : (dev += 1) {
            const d: u5 = @intCast(dev);
            if (ecam.read16(bus, d, 0, Config.VENDOR_ID) == INVALID_VENDOR) continue;

            const multifunction =
                (ecam.read8(bus, d, 0, Config.HEADER_TYPE) & HeaderType.MULTIFUNCTION) != 0;
            const max_func: u8 = if (multifunction) 8 else 1;

            var func: u8 = 0;
            while (func < max_func) : (func += 1) {
                const f: u3 = @intCast(func);
                if (ecam.read16(bus, d, f, Config.VENDOR_ID) == INVALID_VENDOR) continue;
                const handle = Function{ .ecam = ecam, .bus = bus, .dev = d, .func = f };
                if (!visit(context, handle)) return;
            }
        }
    }
}
