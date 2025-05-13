const std = @import("std");
const builtin = @import("builtin");
const FieldEnum = std.meta.FieldEnum;
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

pub fn SoA(comptime T: type) type {
    const align64 = Alignment.fromByteUnits(64);

    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            const source_fields = s.fields;
            var container_fields: [source_fields.len]builtin.Type.StructField = undefined;
            for (source_fields, 0..) |s_field, i| {
                container_fields[i] = .{
                    .name = s_field.name,
                    .type = std.ArrayListAlignedUnmanaged(s_field.@"type", align64),
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(s_field.type),
                };
            }
            const Container = @Type(.{
                .@"struct" = .{
                    .layout = .@"extern",
                    .fields = &container_fields,
                    .decls = [_]builtin.Type.Declaration{},
                    .is_tuple = false,
                },
            });
            return struct {
                data: Container,
                
                pub fn as_vec(self: @This(), comptime field: FieldEnum(T)) @Vector
            };
        },
        else => @compileError("Not supported"),
    }
}
