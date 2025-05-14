const std = @import("std");
const my_simd = @import("simd");
const simd = std.simd;

const dprint = std.debug.print;

const builtin = @import("builtin");
const dbg = builtin.mode == .Debug;

pub fn GetVec2(T: type) type {
    return extern struct {
        x: T,
        y: T,
    };
}

const page_alloc = std.heap.page_allocator;

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var timer = std.time.Timer.start() catch unreachable;

    const T = f64;
    const List = std.ArrayListAligned(T, std.mem.Alignment.@"64");
    const lengths = [_]usize {
        256,
        128 * 300,
        128 * 1024 * 2,
        128 * 1024 * 7,
        128 * 1024 * 128,
    };
    const scl_len = 2;
    const pass_amount = 100;
    dprint("\tPerformance test of\n\t\tb[] = a[] + [(A, B), (A, B), ...]\n\twith {} as individual element\n\t(simd_heler vs llvm vectoried loop)\n\n", .{T});

    dprint("Pass amount: {}\n\n", .{pass_amount});

    for (lengths) |arr_len| {
        const mib_size = @as(f64, @floatFromInt(@bitSizeOf(T) / 8 * arr_len)) / 1024 / 1024;
        dprint("Array length: {}\tMiB size: {d:.3}\n", .{arr_len, mib_size});
        var llvm_avg: usize = 0;
        var my_avg: usize = 0;
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

        for (0..arr_len) |_| {
            r_val = rand.float(T);
            a.append(r_val) catch unreachable;
            b1.append(@floatFromInt(0)) catch unreachable;
            b2.append(@floatFromInt(0)) catch unreachable;
        }
        for (0..scl_len) |_| {
            r_val = rand.float(T);
            s.append(r_val) catch unreachable;
        }

        for (0..pass_amount) |_| {
            if (rand.boolean()) {
                timer.reset();
                my_simd.arrayMultielemScalarOp(
                    scl_len, T,
                    a.items, .add, s.items[0..scl_len].*,
                    b2.items, .non_temporal,
                );
                my_avg += timer.read();

                timer.reset();
                var i: usize = 0;
                while (i + scl_len <= a.items.len) : (i += scl_len) {
                    inline for (0..scl_len) |j| {
                        b1.items[i + j] = a.items[i + j] + s.items[j];
                    }
                }
                llvm_avg += timer.read();
            } else {
                timer.reset();
                var i: usize = 0;
                while (i + scl_len <= a.items.len) : (i += scl_len) {
                    inline for (0..scl_len) |j| {
                        b1.items[i + j] = a.items[i + j] + s.items[j];
                    }
                }
                llvm_avg += timer.read();

                timer.reset();
                my_simd.arrayMultielemScalarOp(
                    scl_len, T,
                    a.items, .add, s.items[0..scl_len].*,
                    b2.items, .non_temporal
                );
                my_avg += timer.read();
            }

            correctness = correctness and std.mem.eql(T, b1.items, b2.items);
        }

        llvm_avg /= pass_amount;
        my_avg /= pass_amount;
        const speedup = 1 / (@as(f64, @floatFromInt(my_avg)) / @as(f64, @floatFromInt(llvm_avg)));

        dprint("llvm_avg: {} ns\nhlpr_avg: {} ns\ncorrectness: {}\nspeedup: {d}\n\n",
            .{llvm_avg, my_avg, correctness, speedup});
    }
}

