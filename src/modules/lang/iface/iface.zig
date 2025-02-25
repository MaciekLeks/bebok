///! Fat Pointer Interface auxiliary functions to generate sherable VTable with strong static typing
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn Fn(comptime tuple_args: anytype, comptime RetType: type) type {
    const TupleArgsLiteral = @TypeOf(tuple_args); //elements are comptime types
    const tuple_literal_ti = @typeInfo(TupleArgsLiteral);
    if (tuple_literal_ti != .@"struct" or !tuple_literal_ti.@"struct".is_tuple) @compileError("Only tuple type is supported in the M() first argument");

    //we use tuple in the input .{i32} but we need Tuple type: struct {i32}
    const args: [tuple_args.len]type = tuple_args; //src: https://ziglang.org/documentation/master/#Type-Coercion-Tuples-to-Arrays
    const TupleArgs = std.meta.Tuple(&args);

    return *const fn (*anyopaque, TupleArgs) RetType;
}

pub fn gen(comptime ImplPtr: type, comptime IfaceVTable: type) *const IfaceVTable {
    const vtable_ti = @typeInfo(IfaceVTable);
    if (vtable_ti != .@"struct") @compileError("Only struct type is supported in the Iface argument");

    const impl_ptr_ti = @typeInfo(ImplPtr);
    if (impl_ptr_ti != .pointer) @compileError("Only pointer type is supported in the ImplPtr argument");
    const Impl = impl_ptr_ti.pointer.child;
    if (@typeInfo(Impl) != .@"struct") @compileError("Only a struct is valid");

    const vtable_fields = vtable_ti.@"struct".fields;
    comptime var vtable: IfaceVTable = undefined; //comptime and coerse to const makes it comptime constant

    inline for (vtable_fields) |field| {
        const impl_fn_ptr = @field(Impl, field.name); //raw pointer to the function
        //@compileLog("impl_fn_field:", impl_fn_field); //@as(*const [14:0]u8, "impl_fn_field:"), @as(fn (*main.main.SomeImpl, i32) i32, (function 'add'))
        const FnType = field.type;

        const fn_ptr_ti = @typeInfo(FnType);
        const fn_ti = @typeInfo(fn_ptr_ti.pointer.child);

        if (fn_ti != .@"fn") @compileError("Vtable fields must be pointers to functions");
        if (fn_ti.@"fn".params.len != 2) @compileError("Only functions with one tuple argument are supported");

        const fn_meta = fn_ti.@"fn"; //Fn type

        const TupleArgs = fn_meta.params[1].type.?;
        const RetType = fn_meta.return_type.?;

        @field(vtable, field.name) = &struct {
            fn wrapper(ctx: *anyopaque, args: TupleArgs) RetType {
                const self: *Impl = @ptrCast(@alignCast(ctx));
                return @call(.auto, impl_fn_ptr, .{self} ++ args);
            }
        }.wrapper;
    }
    const final_vtable = vtable; //copy comptime var struct to make it const
    return &final_vtable;
}

pub fn as(comptime TargetImplPtr: type, vtable: anytype, ctx: *anyopaque) !TargetImplPtr {
    const VTablePtrType = @TypeOf(vtable);
    const vtable_ti = @typeInfo(VTablePtrType);
    if (vtable_ti != .pointer) @compileError("Only a struct pointer is valid");
    if (@typeInfo(vtable_ti.pointer.child) != .@"struct") @compileError("Only a struct is valid");

    return if (gen(TargetImplPtr, vtable_ti.pointer.child) == vtable) @alignCast(@ptrCast(ctx)) else error.CastError;
}

test "interface implementation with vtable sharing and type casting" {
    const Interface = struct {
        ctx: *anyopaque,
        vtable: *const Vtable,

        pub const Vtable = struct {
            add: Fn(.{i32}, i32),
        };

        pub fn add(self: @This(), val: i32) i32 {
            return self.vtable.add(self.ctx, .{val});
        }

        pub fn try_as(self: @This(), comptime ImplPtr: type) !ImplPtr {
            return try as(ImplPtr, self.vtable, self.ctx);
        }

        pub fn init(ctx: anytype) @This() {
            const T = @TypeOf(ctx);
            return .{
                .ctx = ctx,
                .vtable = gen(T, Vtable),
            };
        }
    };

    const SomeImpl = struct {
        pub fn add(_: *@This(), val: i32) i32 {
            return val * 2;
        }
    };

    const SomeImpl2 = struct {
        pub fn add(_: *@This(), val: i32) i32 {
            return val * 3;
        }
    };

    var impl1 = SomeImpl{};
    var impl1b = SomeImpl{};
    var impl2 = SomeImpl2{};

    const iface1 = Interface.init(&impl1);
    const iface1b = Interface.init(&impl1b);
    const iface2 = Interface.init(&impl2);

    // Test functionality
    try testing.expectEqual(@as(i32, 2), iface1.add(1));
    try testing.expectEqual(@as(i32, 2), iface1b.add(1));
    try testing.expectEqual(@as(i32, 3), iface2.add(1));

    // Test vtable sharing
    try testing.expectEqual(iface1.vtable, iface1b.vtable);
    try testing.expect(iface1.vtable != iface2.vtable);

    // Test type casting
    _ = try iface1.try_as(*SomeImpl);
    try testing.expectError(error.CastError, iface1.try_as(*SomeImpl2));
    _ = try iface2.try_as(*SomeImpl2);
}
