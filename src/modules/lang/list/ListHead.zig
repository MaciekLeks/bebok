pub const ListHead = @This();

next: *ListHead,
prev: *ListHead,

// Creates an empty circular list
pub fn init() ListHead {
    var head: ListHead = undefined;
    head.next = &head;
    head.prev = &head;
    return head;
}

// Add a new element after the head of the list
pub fn addAfter(self: *ListHead, new: *ListHead) void {
    new.next = self.next;
    new.prev = self;
    self.next.prev = new;
    self.next = new;
}

// Remove the element from the list
pub fn remove(self: *ListHead) void {
    self.prev.next = self.next;
    self.next.prev = self.prev;
}

// Check if the list is empty
pub fn isEmpty(self: *ListHead) bool {
    return self.next == self;
}
