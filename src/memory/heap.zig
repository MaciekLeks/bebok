const std = @import("std");

var heap_size: usize = undefined;
var heap_address: usize = undefined; // Adres, pod którym alokator ma być umieszczony

// Utwórz wskaźnik do buforu pod określonym adresem
var heap_buffer: []align (4096) u8 = undefined;

// Inicjalizuj FixedBufferAllocator używając tego buforu
var heap_fba: std.heap.FixedBufferAllocator = undefined;
var heap_allocator: std.mem.Allocator = undefined;

pub fn init(size: usize, address: usize) void {
    heap_size = size;
    heap_address = address;

    heap_buffer = @as([*]align(4096) u8, @ptrFromInt(heap_address))[0..heap_size];
    heap_fba = std.heap.FixedBufferAllocator.init(heap_buffer);
    heap_allocator = heap_fba.allocator();
}

pub fn allocator() *std.mem.Allocator {
    return &heap_allocator;
}
