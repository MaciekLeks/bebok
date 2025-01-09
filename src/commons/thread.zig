pub const DummyMutex = struct {
    locked: bool = false,

    pub fn lock(self: *DummyMutex) void {
        while (@atomicRmw(bool, &self.locked, .Xchg, true, .Acquire)) {
            // Aktywne czekanie
            asm volatile ("pause");
        }
    }

    pub fn unlock(self: *DummyMutex) void {
        @atomicStore(bool, &self.locked, false, .Release);
    }
};
