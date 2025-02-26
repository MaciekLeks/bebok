pub const BuddyAllocator = @import("buddy_allocator/buddy_allocator.zig").BuddyAllocator;

test {
    _ = @import("buddy_allocator/bbtree.zig");
    _ = @import("buddy_allocator/buddy_allocator.zig");
}

