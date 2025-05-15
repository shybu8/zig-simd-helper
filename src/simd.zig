const std = @import("std");
const builtin = @import("builtin");

const simd = std.simd;
const assert = std.debug.assert;

pub const Operation = enum {
    add,
    sub,
    mul,
    div,
};

inline fn doVecOp(
    comptime len: usize,
    comptime T: type,
    lhs: *align(1) const @Vector(len, T),
    comptime op: Operation,
    rhs: *align(1) const @Vector(len, T)
) @Vector(len, T) {
    return switch (op) {
        .add => lhs.* + rhs.*,
        .sub => lhs.* - rhs.*,
        .mul => lhs.* * rhs.*,
        .div => lhs.* / rhs.*,
    };
}

pub const NonTemporalStoreOption = enum {
    usual_store,
    nt_store,
};

fn is_capable_to_nts(comptime T: type) bool {
    return simd.suggestVectorLength(T) != null and
        builtin.cpu.arch == .x86_64;
}

inline fn nts_flush() void {
    asm volatile ("sfence" ::: "memory");
}

inline fn lcm(a: usize, b: usize) usize {
    var m: usize = @max(a, b);
    inline while (m % a != 0 or m % b != 0) {
        m += @max(a, b);
    }
    return m;
}

pub fn arrayWideScalarOp(
    comptime scalar_len: usize,
    comptime T: type,
    arr: []const T,
    comptime op: Operation,
    scalar: [scalar_len]T,
    dst: []T,
    comptime nts: NonTemporalStoreOption,
) void {
    // Prelude
    const simd_len = simd.suggestVectorLength(T) orelse 1;
    const do_nts = nts == .nt_store and comptime is_capable_to_nts(T);
    if (do_nts) {
        const bytes = simd_len * @sizeOf(T) - 1;
        assert(@intFromPtr(dst.ptr) & bytes == 0);
    }

    // Window setup
    const scl_window_len = comptime lcm(simd_len, scalar_len);
    const scl_window = @as(
        [scl_window_len]T,
        @bitCast(simd.repeat(
            scl_window_len,
            scalar
        ))
    );

    // Body processing
    var i: usize = 0;
    while (i + scl_window_len <= arr.len) : (i += scl_window_len) {
        const arr_window = @as(
            *const [scl_window_len]T,
            @ptrCast(&arr[i])
        );
        const dst_window = @as(
            *[scl_window_len]T,
            @ptrCast(&dst[i])
        );
        wideWindowsOp(
            scl_window_len, T,
            arr_window, op, &scl_window,
            dst_window, do_nts
        );
    }

    // Tail processing
    while (i < arr.len) : (i += simd_len) {
        const arr_tail = @as(
            *align(1) const @Vector(simd_len, T),
            @ptrCast(&arr[i])
        );
        const scl_ind = i % scl_window_len;
        const scl_tail = @as(
            *align(1) const @Vector(simd_len, T),
            @ptrCast(&scl_window[scl_ind])
        );
        const dst_tail = @as(
            *align(1) @Vector(simd_len, T),
            @ptrCast(&dst[i])
        );
        const res = doVecOp(
            simd_len, T,
            arr_tail, op, scl_tail
        );
        if (do_nts) {
            desired_asm_nts(
                simd_len, T,
                res, dst_tail
            );           
        } else
            dst_tail.* = res;
    }
    if (do_nts)
        nts_flush();
}

inline fn makeVecPtrTable(
    comptime N : usize,
    comptime M : usize,
    comptime T : type,
    base : *const [N]T,
) [N / M]*align(1) @Vector(M,T) {
    comptime assert(N % M == 0);
    const scalars = @as(*[N]T, @constCast(base));

    var table : [N / M]*align(1) @Vector(M,T) = undefined;
    inline for (0 .. N / M) |i| {
        table[i] = @as(
            *align(1) @Vector(M,T),
            @ptrCast(&scalars.*[i * M])
        );
    }
    return table;
}

inline fn wideWindowsOp(
    comptime window_len: usize,
    comptime T: type,
    lhs: *const [window_len]T,
    comptime op: Operation,
    rhs: *const [window_len]T,
    dst: *[window_len]T,
    comptime do_nts: bool,
) void {
    // window_len is guaranteed multiple of simd_len
    const simd_len = simd.suggestVectorLength(T) orelse 1;
    comptime assert(window_len % simd_len == 0);
    const lhs_subs = makeVecPtrTable(
        window_len, simd_len,
        T, lhs
    );
    const rhs_subs = makeVecPtrTable(
        window_len, simd_len,
        T, rhs
    );
    const dst_subs = makeVecPtrTable(
        window_len, simd_len,
        T, dst
    );
    inline for (0..window_len / simd_len) |i| {
        const dst_p = dst_subs[i];
        const res = doVecOp(
            simd_len, T,
            lhs_subs[i],
            op,
            rhs_subs[i],
        );
        if (do_nts) {
            desired_asm_nts(
                simd_len, T,
                res, dst_p
            );
        } else 
            dst_p.* = res;
    }
}

inline fn desired_asm_nts(
    comptime len: usize,
    comptime T: type,
    vec: @Vector(len, T),
    ptr: anytype,
) void {
    switch (@typeInfo(T)) {
        .float => switch(@sizeOf(T)) {
            4 => asm volatile (
                \\ vmovntps %[vec], (%[ptr])
                :
                : [ptr] "r"(ptr), [vec] "v"(vec)
                : "memory"
            ),
            8 => asm volatile (
                \\ vmovntpd %[vec], (%[ptr])
                :
                : [ptr] "r"(ptr), [vec] "v"(vec)
                : "memory"
            ),
            else => @compileError("Not implemented size"),
        },
        .int => asm volatile (
            \\ vmovntdq %[vec], (%[ptr])
            :
            : [ptr] "r"(ptr), [vec] "v"(vec)
            : "memory"
        ),
        else => @compileError("Not implemented"),
    }
}
