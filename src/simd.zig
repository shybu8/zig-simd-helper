const std = @import("std");
const builtin = @import("builtin");

const simd = std.simd;
const assert = std.debug.assert;

pub const VecOperation = enum {
    add,
    sub,
    mul,
    div,
};

pub const NonTemporalOption = enum {
    non_temporal,
    usual,
};

inline fn vecOp(
    comptime N: usize,
    comptime T: type,
    lhs: @Vector(N, T),
    comptime op: VecOperation,
    rhs: @Vector(N, T),
    dest: *align(1) @Vector(N, T),
    comptime nt: NonTemporalOption,
) void {
    const res = switch (op) {
        .add => lhs + rhs,
        .sub => lhs - rhs,
        .mul => lhs * rhs,
        .div => lhs / rhs,
    };
    if (nt == .non_temporal and builtin.cpu.arch == .x86_64) {
        switch (@typeInfo(T)) {
            .float => switch (@sizeOf(T)) {
                4 => asm volatile (
                    \\ vmovntps %[vec], (%[ptr])
                    :
                    : [ptr] "r"(dest), [vec] "v"(res)
                    : "memory"
                ),
                8 => asm volatile (
                    \\ vmovntpd %[vec], (%[ptr])
                    :
                    : [ptr] "r"(dest), [vec] "v"(res)
                    : "memory"
                ),
                else => @compileError("unsupported float width"),
            },
            .int => asm volatile (
                \\ vmovntdq %[vec], (%[ptr])
                :
                : [ptr] "r"(dest), [vec] "v"(res)
                : "memory"
            ),
            else => @compileError("unsupported element type for vecOp"),
        }
    } else {
        dest.* = res;
    }
}

inline fn vecOpFlush() void {
    if (builtin.cpu.arch == .x86_64)
        asm volatile ("sfence" ::: "memory");
}

inline fn tailOp(
    comptime T: type,
    lhs: []T,
    comptime op: VecOperation,
    rhs: []T,
    dest: []T,
    i: usize,
) void {
    switch (op) {
        .add => dest[i] = lhs[i] + rhs[i],
        .sub => dest[i] = lhs[i] - rhs[i],
        .mul => dest[i] = lhs[i] * rhs[i],
        .div => dest[i] = lhs[i] / rhs[i],
    }
}

pub fn arraysOp(
    comptime T: type,
    lhs: []T,
    comptime op: VecOperation,
    rhs: []T,
    dest: []T
) void {
    assert(lhs.len == rhs.len and lhs.len == dest.len);
    @compileLog(simd.suggestVectorLength(T));
    const N = simd.suggestVectorLength(T) orelse 1;

    var i: usize = 0;

    while (i + N <= lhs.len) : (i += N) {
        const a = @as(
            *align(1) const @Vector(N, T), 
            @ptrCast(lhs[i..i + N])
        );
        const b = @as(
            *align(1) const @Vector(N, T),
            @ptrCast(rhs[i..i + N])
        );
        const d = @as(
            *align(1) @Vector(N, T),
            @ptrCast(dest[i..i + N])
        );
        vecOp(N, T, a.*, op, b.*, d, .non_temporal);
    }

    while (i < lhs.len) : (i += 1) {
        tailOp(T, lhs, op, rhs, dest, i);
    }
    vecOpFlush();
}

pub fn arraysCopy(
    comptime T: type,
    src: []T,
    dst: []T,
) void {
    assert(src.len == dst.len);
    const N = simd.suggestVectorLength(T) orelse 1;
    var i: usize = 0;

    while (i + N <= src.len) : (i += N) {
        const s = @as(
            *align(1) const @Vector(N, T), 
            @ptrCast(src[i..i + N])
        );
        const d = @as(
            *align(1) @Vector(N, T),
            @ptrCast(dst[i..i + N])
        );
        d.* = s.*;
    }

    while (i < src.len) : (i += 1) {
        dst[i] = src[i];
    }
}

pub fn arrayMultielemScalarOp(
    comptime L: usize,
    comptime T: type,
    arr: []T,
    comptime op: VecOperation,
    scalar: [L]T,
    dst: []T,
    comptime nt: NonTemporalOption,
) void {
    assert(
        arr.len == dst.len and
        arr.len % L == 0
    );
    const N = simd.suggestVectorLength(T) orelse 1;
    const _window_mul = N / L;
    // TODO: Asynmetric/wide window vectors on L > N
    const window_mul = if (_window_mul == 0) 1 else _window_mul;
    const window = window_mul * L;

    const rhs = simd.repeat(window, scalar);

    var i: usize = 0;
    while (i + window <= arr.len) : (i += window) {
        const lhs = @as(
            *align(1) const @Vector(window, T),
            @ptrCast(&arr[i])
        );
        const d = @as(
            *align(1) @Vector(window, T),
            @ptrCast(&dst[i])
        );
        vecOp(window, T, lhs.*, op, rhs, d, nt);
    }
    if (window_mul != 1) {
        // Tail
        const t_rhs = @as(@Vector(L, T), @bitCast(scalar));
        while (i < arr.len) : (i += L) {
            const t_lhs = @as(
                *align(1) const @Vector(L, T),
                @ptrCast(&arr[i])
            );
            const t_d = @as(
                *align(1) @Vector(L, T),
                @ptrCast(&dst[i])
            );
            vecOp(L, T, t_lhs.*, op, t_rhs, t_d, .usual);
        }
    }
    if (nt == .non_temporal)
        vecOpFlush();
}

pub const Operation = enum {
    add,
    sub,
    mul,
    div,
};

fn doVecOp(
    comptime len: usize,
    comptime T: type,
    lhs: @Vector(len, T),
    comptime op: Operation,
    rhs: @Vector(len, T)
) @Vector(len, T) {
    return switch (op) {
        .add => lhs + rhs,
        .sub => lhs - rhs,
        .mul => lhs * rhs,
        .div => lhs / rhs,
    };
}

pub const NonTemporalStoreOption = enum {
    usual_store,
    nt_store,
};

inline fn nt_flush() void {
    if (builtin.cpu.arch == .x86_64)
        asm volatile ("sfence" ::: "memory");
}

fn lcm(a: comptime_int, b: comptime_int) comptime_int {
    var m = @max(a, b);
    while (m % a != 0 or m % b != 0) {
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
    comptime nt: NonTemporalStoreOption,
) void {
    const simd_len = simd.suggestVectorLength(T) orelse 1;
    const scl_window_len = lcm(simd_len, scalar_len);
    const scl_window = @as(
        [scl_window_len]T,
        @bitCast(simd.repeat(
            scl_window_len,
            scalar
        ))
    );
    var i: usize = 0;
    while (i + scl_window_len <= arr.len) : (i += scl_window_len) {
        const arr_window = @as(
            *align(1) const @Vector(scl_window_len, T),
            @ptrCast(&arr[i])
        );
        const dst_window = @as(
            *align(1) @Vector(scl_window_len, T),
            @ptrCast(&dst[i])
        );
        wideWindowsOp(
            scl_window_len, T,
            arr_window.*, op, scl_window,
            dst_window, nt
        );
    }
    while (i + simd_len <= arr.len) : (i += simd_len) {
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
        // Without nt
        dst_tail.* = arr_tail.* + scl_tail.*;
    }
    if (nt == .nt_store)
        nt_flush();
}

inline fn divideVec(
    comptime len: usize,
    comptime T: type,
    src: *align(1) @Vector(len, T),
    comptime sublen: usize
) [len / sublen]*align(1) @Vector(sublen, T) {
    const as_ptr = @as(*align(1) [len]T, @ptrCast(src));
    var res: [len / sublen]*align(1) @Vector(sublen, T) = undefined;
    for (0..len / sublen) |i| {
        const start = sublen * i;
        res[i] = @as(
            *align(1) @Vector(sublen, T),
            @ptrCast(&as_ptr[start])
        );
    }
    return res;
}

inline fn wideWindowsOp(
    comptime window_len: usize,
    comptime T: type,
    lhs: @Vector(window_len, T),
    comptime op: Operation,
    rhs: @Vector(window_len, T),
    dst: *align(1) @Vector(window_len, T),
    comptime nt: NonTemporalStoreOption,
) void {
    // window_len is guaranteed multiple of simd_len
    const simd_len = simd.suggestVectorLength(T) orelse 1;
    const lhs_portions = divideVec(
        window_len, T,
        @constCast(&lhs), simd_len
    );
    const rhs_portions = divideVec(
        window_len, T,
        @constCast(&rhs), simd_len
    );
    const dst_portions = divideVec(
        window_len, T,
        dst, simd_len
    );
    inline for (0..window_len / simd_len) |i| {
        const res = doVecOp(
            simd_len, T,
            lhs_portions[i].*,
            op,
            rhs_portions[i].*,
        );
        if (nt == .usual_store or builtin.cpu.arch != .x86_64) {
            dst_portions[i].* = res;
        } else switch (@typeInfo(T)) {
            .float => switch(@sizeOf(T)) {
                4 => asm volatile (
                    \\ vmovntps %[vec], (%[ptr])
                    :
                    : [ptr] "r"(dst_portions[i]), [vec] "v"(res)
                    : "memory"
                ),
                8 => asm volatile (
                    \\ vmovntpd %[vec], (%[ptr])
                    :
                    : [ptr] "r"(dst_portions[i]), [vec] "v"(res)
                    : "memory"
                ),
                else => @compileError("Not implemented size"),
            },
            else => @compileError("Not implemented"),
        }
    }
}
