//------------------------------------------------------------------------------
// Laminae Cooperative Task System
//
// Zero-kernel-overhead cooperative multitasking for containers.
// Tasks share the same container's address space and cooperatively yield.
//
// Design: Based on spawn_evolution.md Option C (Userland Cooperative Tasks)
//
// Usage:
//   const tasks = @import("liblaminae").tasks;
//
//   fn worker(task: *Task) void {
//       while (true) {
//           doWork();
//           tasks.yield(); // Give other tasks a chance
//       }
//   }
//
//   pub fn main() void {
//       _ = tasks.spawn(worker) catch unreachable;
//       tasks.run(); // Start task scheduler
//   }
//
// Architecture:
//   - Single-threaded cooperative scheduling
//   - Manual yield() calls required
//   - No preemption (bad task can starve others)
//   - No kernel involvement (just register swaps)
//
// Memory:
//   - 8KB stack per task (allocated from heap)
//   - ~80 bytes Task struct overhead
//   - Total: ~8.1KB per task
//------------------------------------------------------------------------------

const heap = @import("../root.zig").heap;

/// Task stack size (8KB, 16-byte aligned)
const TASK_STACK_SIZE: usize = 8192;

/// Task state machine
pub const TaskState = enum {
    ready, // Ready to run
    running, // Currently executing
    blocked, // Waiting for I/O or event
    done, // Completed execution
};

/// Saved CPU context for task switching (ARM64 callee-saved registers)
/// Layout must match assembly offsets in switchContext:
///   sp: offset 0, pc: offset 8, x19-x28: offsets 16-96, x29: offset 96, x30: offset 104
pub const SavedContext = struct {
    sp: u64 = 0,
    pc: u64 = 0,
    x19_x28: [10]u64 = [_]u64{0} ** 10,
    x29: u64 = 0,
    x30: u64 = 0,
};

/// Task control block
pub const Task = struct {
    id: u32,
    stack: []u8,
    context: SavedContext = .{},
    state: TaskState = .ready,
    next: ?*Task = null,
};

// Global state
var current_task: ?*Task = null;
var ready_queue_head: ?*Task = null;
var ready_queue_tail: ?*Task = null;
var next_task_id: u32 = 1;

/// Scheduler context - saved when run() enters first task, restored when all done
var scheduler_context: SavedContext = .{};
var scheduler_running: bool = false;

/// Switch CPU context from one task to another
fn switchContext(from: *SavedContext, to: *SavedContext) void {
    asm volatile (
    // Save current context to 'from'
    // x9 is scratch register (caller-saved, safe to use)
        \\mov x9, sp
        \\str x9, [%[from], #0]           // Save SP
        \\adr x9, 1f
        \\str x9, [%[from], #8]           // Save PC (return address)
        \\stp x19, x20, [%[from], #16]    // Save x19-x20
        \\stp x21, x22, [%[from], #32]    // Save x21-x22
        \\stp x23, x24, [%[from], #48]    // Save x23-x24
        \\stp x25, x26, [%[from], #64]    // Save x25-x26
        \\stp x27, x28, [%[from], #80]    // Save x27-x28
        \\str x29, [%[from], #96]         // Save x29 (frame pointer)
        \\str x30, [%[from], #104]        // Save x30 (link register)

        // Load new context from 'to'
        \\ldr x9, [%[to], #0]             // Load SP
        \\mov sp, x9
        \\ldp x19, x20, [%[to], #16]      // Load x19-x20
        \\ldp x21, x22, [%[to], #32]      // Load x21-x22
        \\ldp x23, x24, [%[to], #48]      // Load x23-x24
        \\ldp x25, x26, [%[to], #64]      // Load x25-x26
        \\ldp x27, x28, [%[to], #80]      // Load x27-x28
        \\ldr x29, [%[to], #96]           // Load x29 (frame pointer)
        \\ldr x30, [%[to], #104]          // Load x30 (link register)
        \\ldr x9, [%[to], #8]             // Load PC
        \\br x9                            // Branch to new task
        \\1:
        :
        : [from] "r" (from),
          [to] "r" (to),
        : .{ .x9 = true, .memory = true }
    );
}

/// Task entry wrapper - calls user entry function then marks task as done
fn taskWrapper() noreturn {
    // On entry: x19 = entry function pointer, x20 = task pointer
    const entry_ptr: usize = asm volatile ("mov %[out], x19"
        : [out] "=r" (-> usize),
    );
    const task_ptr: usize = asm volatile ("mov %[out], x20"
        : [out] "=r" (-> usize),
    );

    const entry: *const fn (*Task) void = @ptrFromInt(entry_ptr);
    const task: *Task = @ptrFromInt(task_ptr);

    entry(task);

    // Task returned - mark as done and yield to next task
    if (current_task) |t| {
        t.state = .done;
    }
    yield();
    unreachable;
}

/// Spawn a new task with the given entry function
pub fn spawn(comptime entry: fn (*Task) void) !*Task {
    const stack_ptr = heap.alignedAlloc(TASK_STACK_SIZE, 16) orelse return error.OutOfMemory;
    const stack: []u8 = stack_ptr[0..TASK_STACK_SIZE];

    const task_ptr = heap.alloc(@sizeOf(Task)) orelse return error.OutOfMemory;
    const task: *Task = @ptrCast(@alignCast(task_ptr));

    const id = next_task_id;
    next_task_id += 1;

    // Stack grows downward, SP starts at top
    const stack_top = @intFromPtr(stack.ptr) + stack.len;

    task.* = .{
        .id = id,
        .stack = stack,
        .context = .{
            .sp = stack_top,
            .pc = @intFromPtr(&taskWrapper),
            .x19_x28 = blk: {
                var regs = [_]u64{0} ** 10;
                regs[0] = @intFromPtr(&entry); // x19 = entry function
                regs[1] = @intFromPtr(task); // x20 = task pointer
                break :blk regs;
            },
        },
    };

    enqueue(task);
    return task;
}

/// Yield to the next ready task
pub fn yield() void {
    if (current_task) |prev| {
        const next = dequeue();

        if (next) |next_task| {
            // Have another task to switch to
            if (prev.state == .running) {
                prev.state = .ready;
                enqueue(prev);
            }

            next_task.state = .running;
            current_task = next_task;
            switchContext(&prev.context, &next_task.context);
        } else {
            // No other tasks in queue
            if (prev.state == .done and scheduler_running) {
                // Task is done, return to scheduler
                switchContext(&prev.context, &scheduler_context);
            }
            // Otherwise: task not done, continue running it
        }
    }
}

/// Exit current task and switch to next
pub fn exit() void {
    if (current_task) |task| {
        task.state = .done;
        yield();
    }
}

/// Start the task scheduler (runs until all tasks are done)
pub fn run() void {
    scheduler_running = true;

    // Start the first task if any
    while (ready_queue_head != null) {
        const first_task = dequeue().?;
        first_task.state = .running;
        current_task = first_task;

        // Switch to the task (saves scheduler context, returns when all done)
        switchContext(&scheduler_context, &first_task.context);

        // When we return here, either all tasks are done or we need to check again
        current_task = null;
    }

    scheduler_running = false;
}

// Queue management (simple FIFO linked list)

fn enqueue(task: *Task) void {
    task.next = null;
    if (ready_queue_tail) |tail| {
        tail.next = task;
        ready_queue_tail = task;
    } else {
        ready_queue_head = task;
        ready_queue_tail = task;
    }
}

fn dequeue() ?*Task {
    const task = ready_queue_head orelse return null;
    ready_queue_head = task.next;
    if (ready_queue_head == null) {
        ready_queue_tail = null;
    }
    task.next = null;
    return task;
}

/// Get current task (useful for task-local state)
pub fn current() ?*Task {
    return current_task;
}

/// Get number of ready tasks
pub fn readyCount() usize {
    var count: usize = 0;
    var task = ready_queue_head;
    while (task) |t| : (task = t.next) {
        count += 1;
    }
    return count;
}
