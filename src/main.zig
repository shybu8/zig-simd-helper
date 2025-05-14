const std = @import("std");
const my_simd = @import("simd");
const simd = std.simd;

const dprint = std.debug.print;
const assert = std.debug.assert;

const builtin = @import("builtin");
const dbg = builtin.mode == .Debug;

const page_alloc = std.heap.page_allocator;

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: usize = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var timer = std.time.Timer.start() catch unreachable;

    const T = f32;
    const scl_len = 3;
    const List = std.ArrayListAligned(T, std.mem.Alignment.@"64");
    const lengths = [_]usize {
        scl_len * 1024,
        // scl_len * 64 * 300,
        // scl_len * 64 * 1024 * 2,
        // scl_len * 64 * 1024 * 10,
        // scl_len * 64 * 1024 * 25,
    };
    const pass_amount = 50;
    // const pass_amount = 1;
    dprint("\tPerformance test\n\tAdding {}-dimensional vector to array of vectors\n\twith {} as individual element\n\t(simd_heler vs llvm vectoried loop)\n\n", .{scl_len, T});

    dprint("Pass amount: {}\n\n", .{pass_amount});

    for (lengths) |arr_len| {
        const mib_size = @as(f64, @floatFromInt(@bitSizeOf(T) / 8 * arr_len)) / 1024 / 1024;
        dprint("Array length: {}\tMiB size: {d:.3}\n", .{arr_len, mib_size});
        var llvm_avg: u64 = 0;
        var my_avg: u64 = 0;
        var correctness: bool = true;

        var a = List.init(page_alloc);
        var b1 = List.init(page_alloc);
        var b2 = List.init(page_alloc);
        var s = List.init(page_alloc);
        defer {
            a.deinit();
            b1.deinit();
            b2.deinit();
            s.deinit();
        }
        var r_val: T = 0;

        const zero = switch (@typeInfo(T)) {
            .float => 0.0,
            .int => 0,
            else => @compileError("Unsupported type"),
        };

        for (0..arr_len) |_| {
            r_val = switch(@typeInfo(T)) {
                .float => rand.float(T),
                .int => rand.int(T),
                else => @compileError("Unsupported type"),
            };
            a.append(r_val) catch unreachable;
            b1.append(zero) catch unreachable;
            b2.append(zero) catch unreachable;
        }
        for (0..scl_len) |_| {
            r_val = switch(@typeInfo(T)) {
                .float => rand.float(T),
                .int => rand.int(T),
                else => @compileError("Unsupported type"),
            };
            s.append(r_val) catch unreachable;
        }

        for (0..pass_amount) |_| {
            if (rand.boolean()) {
                timer.reset();
                my_simd.arrayWideScalarOp(
                    scl_len, T,
                    a.items, .add, s.items[0..scl_len].*,
                    b2.items, .usual_store,
                );
                my_avg += timer.read();

                timer.reset();
                var i: usize = 0;
                while (i < a.items.len) : (i += scl_len) {
                    inline for (0..scl_len) |j| {
                        b1.items[i + j] = a.items[i + j] + s.items[j];
                    }
                }
                llvm_avg += timer.read();
            } else {
                timer.reset();
                var i: usize = 0;
                while (i < a.items.len) : (i += scl_len) {
                    inline for (0..scl_len) |j| {
                        b1.items[i + j] = a.items[i + j] + s.items[j];
                    }
                }
                llvm_avg += timer.read();

                timer.reset();
                my_simd.arrayWideScalarOp(
                    scl_len, T,
                    a.items, .add, s.items[0..scl_len].*,
                    b2.items, .usual_store
                );
                my_avg += timer.read();
            }

            correctness = correctness and std.mem.eql(T, b1.items, b2.items);
            // printArrOTO(T, b1.items, b2.items);
        }

        llvm_avg /= pass_amount;
        my_avg /= pass_amount;
        const speedup = 1 / (@as(f64, @floatFromInt(my_avg)) / @as(f64, @floatFromInt(llvm_avg)));
        const gflops = @as(f64, @floatFromInt(arr_len)) * (1_000_000_000 / @as(f64, @floatFromInt(my_avg))) / 1_000_000_000;

        dprint("llvm_avg: {} ns\nhlpr_avg: {} ns\ncorrectness: {}\nspeedup: {d}\tTotal GFLOPS: {d:.3}\n\n",
            .{llvm_avg, my_avg, correctness, speedup, gflops});
    }
}

fn printArrOTO(
    comptime T: type,
    a: []T,
    b: []T,
) void {
    assert(a.len == b.len);
    for (0..a.len) |i| {
        dprint("{}:\t{}\t{}\n", .{i, a[i], b[i]});
    }
}
