const std = @import("std");
const testing = std.testing;

pub fn main() !void {
    std.debug.print("actual main\n", .{});

    var allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();
    _ = world;

    const Person = struct {};

    const Age = struct {
        age: u32,
    };

    try world.make(.{
        Person{},
        Age{ .age = 30},
    });

    try world.make(.{
        Age{ .age = 30 },
        Person{},
    });

    world.dump();
}

///////////////////////////////////////////////////////////////////////////////

const Entity = u64;

const World = struct {
    allocator: std.mem.Allocator,
    archetypes: std.ArrayList(Archetype),
    next_entity: Entity,

    fn init(allocator: std.mem.Allocator) World {
        return World{
            .allocator = allocator,
            .archetypes = std.ArrayList(Archetype).init(allocator),
            .next_entity = 0,
        };
    }

    fn deinit(world: *World) void {
        for (world.archetypes.items) |*archetype| {
            archetype.deinit();
        }
        world.archetypes.deinit();
    }

    /// Strict find, archetype's component names must be same as `component_names`.
    fn findArchetype(world: *World, component_names: std.ArrayList([]const u8)) ?*Archetype {
        for (world.archetypes.items) |*archetype| {
            if (archetype.*.component_names.items.len == component_names.items.len) {
                var found = true;
                for (archetype.*.component_names.items) |component_name, i| {
                    if (!std.mem.eql(u8, component_name, component_names.items[i])) {
                        found = false;
                        break;
                    }
                }
                if (found) {
                    return archetype;
                }
            }
        }

        return null;
    }

    /// Make a new entity, with the given `components`, and add it to the `world`.
    fn make(world: *World, components: anytype) !void {
        defer world.next_entity += 1;

        std.debug.print("Make entity {}, with\n", .{world.next_entity});

        var component_names = std.ArrayList([]const u8).init(world.allocator);
        try makeComponentNames(&component_names, components);

        if (world.findArchetype(component_names)) |archetype| {
            defer component_names.deinit();

            std.debug.print("  Found existing archetype: ", .{});
            for (archetype.component_names.items) |name, i| {
                if (i != 0) {
                    std.debug.print("-", .{});
                }
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n", .{});

            inline for (@typeInfo(@TypeOf(components)).Struct.fields) |struct_field| {
                const field = @field(components, struct_field.name);
                const FieldType = @TypeOf(field);
                const component_name = @typeName(FieldType);
                std.debug.print("  Appending to existing component, {any}\n", .{field});
                if (archetype.componentNameToComponentHolder(component_name)) |component_holder| {
                    var typed_component_list = @ptrCast(*std.ArrayList(FieldType), &component_holder.type_erased_list);
                    try typed_component_list.append(field);
                } else {
                    // logic error
                    // compiler returns with code 5 if I add a panic here... ?
                    //std.debug.panic("Could not find the correct component holder, but the component name was found?", .{});
                }
            }
        } else {
            var archetype = try world.archetypes.addOne();
            archetype.component_names = component_names;
            archetype.components = std.ArrayList(ComponentHolder).init(world.allocator);

            std.debug.print("  Creating archetype: ", .{});
            for (component_names.items) |name, i| {
                if (i != 0) {
                    std.debug.print("-", .{});
                }
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n", .{});

            inline for (std.meta.fields(@TypeOf(components))) |struct_field, struct_i| {
                const field = @field(components, struct_field.name);
                const FieldType = @TypeOf(field);
                const component_name = @typeName(FieldType);

                for (archetype.component_names.items) |archetype_component_name, name_i| {
                    // Make sure to insert components in same order as the names (sorted).

                    if (std.mem.eql(u8, archetype_component_name, component_name)) {
                        std.debug.print("  New component {any} @{}. In archetype: {{name: {s}, name_i: {}}}\n", .{field, struct_i, archetype_component_name, name_i});
                        var new_component_list = std.ArrayList(FieldType).init(world.allocator);
                        try new_component_list.append(field);

                        const Closure = deinitComponent(FieldType);

                        if (name_i < archetype.components.items.len) {
                            // ok to insert
                            try archetype.components.insert(name_i, .{
                                .type_erased_list = @ptrCast(*std.ArrayList(ComponentHolder.Dummy), &new_component_list).*,
                                .deinit_ = Closure.deinit,
                            });
                        } else {
                            // have to append
                            try archetype.components.append(.{
                                .type_erased_list = @ptrCast(*std.ArrayList(ComponentHolder.Dummy), &new_component_list).*,
                                .deinit_ = Closure.deinit,
                            });
                        }
                        break;
                    } else {
                        // compiler returns with code 5 if I add a panic here... ?
                        //std.debug.panic("Same component [{s}] found twice, that is illegal.", .{component_name});
                        //@compileError("Same component found twice, that is illegal: " ++ component_name);
                    }
                }
            }
        }
    }

    /// Extract the names of the components.
    ///
    /// makeComponentNames(out, .{
    ///     Age{...},
    ///     Name{...},
    /// }) -> {"Age", "Name"}
    ///
    fn makeComponentNames(component_names: *std.ArrayList([]const u8), components: anytype) !void {
        const ComponentsType = @TypeOf(components);
        const components_type_info = @typeInfo(ComponentsType);
        if (components_type_info != .Struct) {
            @compileError("Expected tuple or struct argument, found " ++ @typeName(ComponentsType));
        }

        //@setEvalBranchQuota(2000000);
        inline for (components_type_info.Struct.fields) |struct_field| {
            const field = @field(components, struct_field.name);
            const FieldType = @TypeOf(field);
            //const field_type_info = @typeInfo(FieldType);

            // TODO cgustafsson: remove?
            //if (field_type_info != .Struct) {
            //    @compileError("Expected " ++ struct_field.name ++ " to be a Struct, found " ++ @typeName(struct_field.field_type));
            //}

            const component_name = @typeName(FieldType);

            var len_before = component_names.items.len;
            for (component_names.items) |existing_component_name, list_i| {
                if (std.mem.indexOfDiff(u8, component_name, existing_component_name)) |i| {
                    if (component_name[i] < existing_component_name[i]) {
                        try component_names.insert(list_i, component_name);
                        break;
                    }
                } else {
                    //std.debug.panic("Same component [{s}] found twice, that is illegal.", .{component_name});
                    //@compileError("Same component found twice, that is illegal: " ++ component_name);
                }
            }
            if (len_before == component_names.items.len) {
                try component_names.append(component_name);
            }

            std.debug.print(" component: {s}\n", .{component_name});
        }
    }

    fn dump(world: World) void {
        std.debug.print("~~~ Archtype Dump ~~~\n", .{});
        for (world.archetypes.items) |archetype| {
            std.debug.print(" ", .{});
            archetype.dump();
            std.debug.print("\n", .{});
        }
        std.debug.print("~~~~~~~~~~~~~~~~~~~~~\n", .{});
    }
};

fn deinitComponent(comptime Component: type) type {
    return struct {
        fn deinit(list: std.ArrayList(ComponentHolder.Dummy)) void {
            var typed_list = @ptrCast(*const std.ArrayList(Component), &list).*;
            std.debug.print(" deinit component {s} with {} entities\n", .{@typeName(Component), typed_list.items.len});
            typed_list.deinit();
        }
    };
}

/// An archetype is a set of components.
///
/// # How to query for a component
///
/// entity components archetype
///
/// 1      A, B       X
/// 2      A, B, C    Y
/// 3      B, C       Z
///
/// Query(.{A})    -> .{X, Y, Z}
/// Query(.{A, B}) -> .{X, Y}
/// Query(.{B, C}) -> .{Y, Z}
///
const Archetype = struct {
    component_names: std.ArrayList([]const u8), //< Sorted list of component names.
    components: std.ArrayList(ComponentHolder), //< List of component lists.

    fn deinit(archetype: *Archetype) void {
        std.debug.print("deinit archetype ", .{});
        archetype.dump();
        std.debug.print("\n", .{});
        for (archetype.components.items) |*component_holder| {
            component_holder.deinit();
        }
        archetype.component_names.deinit();
        archetype.components.deinit();
    }

    /// Does this `archetype` contain all the `component_names`.
    fn contains(archetype: Archetype, component_names: std.ArrayList([]const u8)) bool {
        var match: u32 = 0;
        for (archetype.component_names.items) |archetype_component_name, i| {
            if (i >= component_names.items.len) {
                break;
            }
            if (std.mem.eql(u8, archetype_component_name, component_names.items[i])) {
                match += 1;
            }
        }

        return match == component_names.items.len;
    }

    fn componentNameToComponentHolder(archetype: *Archetype, component_name: []const u8) ?*ComponentHolder {
        for (archetype.component_names.items) |archetype_component_name, i| {
            if (std.mem.eql(u8, archetype_component_name, component_name)) {
                return &archetype.components.items[i];
            }
        }

        return null;
    }

    fn dump(archetype: Archetype) void {
        for (archetype.component_names.items) |name, i| {
            if (i != 0) {
                std.debug.print("-", .{});
            }
            std.debug.print("{s}", .{name});
        }
    }
};

const ComponentHolder = struct {
    const Dummy = struct {
        dummy: usize = 0,
    };

    type_erased_list: std.ArrayList(Dummy),
    deinit_: fn (std.ArrayList(Dummy)) void,

    fn deinit(component_holder: ComponentHolder) void {
        component_holder.deinit_(component_holder.type_erased_list);
    }
};

///////////////////////////////////////////////////////////////////////////////
// test
//

test "complex world" {
    std.debug.print("\n", .{});

    var allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();
    _ = world;

    const Person = struct {};

    const Age = struct {
        age: u32,
    };

    const Chair = struct {};

    try world.make(.{
        Person{},
        Age{ .age = 30 },
    });

    world.dump();

    try world.make(.{
        Chair{},
    });

    world.dump();

    try world.make(.{
        Age{ .age = 20 },
        Person{},
    });

    const DammsugarNjutare = struct {};

    const KaffeBeroende = struct {};

    const Name = struct { name: []const u8 };

    try world.make(.{
        Person{},
        Age{ .age = 45 },
        DammsugarNjutare{},
        KaffeBeroende{},
        Name{ .name = "Danny" },
    });

    world.dump();

    //var iter = try world.query(.{
    //    Age{.age = 13},
    //});
    //std.debug.print("/////////////////////\n", .{});
    //while (iter.next()) |t| {
    //    std.debug.print("{any}\n", .{t});
    //    //std.debug.print("{}, ", .{t.@"0".age});
    //}
    //std.debug.print("\n", .{});
}

///////////////////////////////////////////////////////////////////////////////

const A = struct { a: u8, };
const B = struct { b: u32, };

test "return comptime struct with runtime values" {

    const Closure = struct {
        fn query(t: anytype) @TypeOf(t) {
            const Type = @TypeOf(t);
            var out = Type{undefined};

            // fake runtime data
            var aa = std.ArrayList(A).init(std.testing.allocator);
            defer aa.deinit();
            aa.append(.{.a = 'a'}) catch {};
            var bb = std.ArrayList(B).init(std.testing.allocator);
            defer bb.deinit();
            bb.append(.{.b = 1337}) catch {};

            inline for (@typeInfo(Type).Struct.fields) |field| {
                var field_value = &@field(out, field.name);
                if (field.field_type == A) {
                    field_value.* = aa.items[0];
                } else if (field.field_type == B) {
                    field_value.* = bb.items[0];
                }
            }

            return out;
        }
    };

    var res = Closure.query(.{
        A{.a = 0},
        B{.b = 0},
    });

    std.debug.print("res: {any}\n", .{res});

    try std.testing.expectEqual(res.@"0", A{.a = 'a'});
    try std.testing.expectEqual(res.@"1", B{.b = 1337});
}

///////////////////////////////////////////////////////////////////////////////
