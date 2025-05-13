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

inline fn vecOp(
    comptime N: usize,
    comptime T: type,
    lhs: @Vector(N, T),
    comptime op: VecOperation,
    rhs: @Vector(N, T),
    dest: *align(1) @Vector(N, T),
) void {
    switch (op) {
        .add => dest.* = lhs + rhs,
        .sub => dest.* = lhs - rhs,
        .mul => dest.* = lhs * rhs,
        .div => dest.* = lhs / rhs,
    }
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
        vecOp(N, T, a.*, op, b.*, d);
    }

    while (i < lhs.len) : (i += 1) {
        tailOp(T, lhs, op, rhs, dest, i);
    }
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
) void {
    assert(
        arr.len == dst.len and
        arr.len % L == 0
    );
    const N = simd.suggestVectorLength(T) orelse 1;
    const _window_mul = N / L;
    // TODO: Asynmetric vectors on L > N
    const window_mul = if (_window_mul == 0) 1 else _window_mul;
    const window = window_mul * L;

    const rhs = simd.repeat(window, scalar);

    var i: usize = 0;
    while (i + window <= arr.len) : (i += window) {
        const lhs = @as(
            *align(1) const @Vector(window, T),
            @ptrCast(arr[i..i + window])
        );
        const d = @as(
            *align(1) @Vector(window, T),
            @ptrCast(dst[i..i + window])
        );
        vecOp(window, T, lhs.*, op, rhs, d);
    }
    if (window_mul != 1) {
        // Tail
        const t_rhs = @as(@Vector(L, T), @bitCast(scalar));
        while (i < arr.len) : (i += L) {
            const t_lhs = @as(
                *align(1) const @Vector(L, T),
                @ptrCast(arr[i..i + L])
            );
            const t_d = @as(
                *align(1) @Vector(L, T),
                @ptrCast(dst[i..i + L])
            );
            vecOp(L, T, t_lhs.*, op, t_rhs, t_d);
        }
    }
}

// pub fn arraysMultielemTimelocalOps(
//     comptime L: usize,
//     comntime T: type,
//     comptime C: usize,
//     srcs: [C][]T,
//     comptime func: fn ([C]@Vector(
