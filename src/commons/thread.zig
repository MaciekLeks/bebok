pub const DummyMutex = struct {
    locked: bool = false,

    pub fn lock(self: *DummyMutex) void {
        // while (@atomicRmw(bool, &self.locked, .Xchg, true, .Acquire)) {
        //     asm volatile ("pause");
        // }
        while (true) {
            if (!self.locked) {
                self.locked = true;
                break;
            }
            asm volatile ("pause");
        }
    }

    pub fn unlock(self: *DummyMutex) void {
        // @atomicStore(bool, &self.locked, false, .Release);
        self.locked = false;
    }
};
