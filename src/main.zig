const std = @import("std");
const testing = std.testing;

const Entity = u64;
//const ComponentId = Entity;

const World = struct {
    allocator: std.mem.Allocator,
    archetypes: std.ArrayList(Archetype),
    //entities: std.AutoHashMap(Entity, std.ArrayList(ComponentId)),
    next_entity: Entity,

    fn init(allocator: std.mem.Allocator) World {
        return World{
            .allocator = allocator,
            .archetypes = std.ArrayList(Archetype).init(allocator),
            //.entities = std.AutoHashMap(Entity, std.ArrayList(ComponentId)).init(allocator),
            .next_entity = 0,
        };
    }

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

    fn make(world: *World, components: anytype) !void {
        const ComponentsType = @TypeOf(components);
        const components_type_info = @typeInfo(ComponentsType);
        if (components_type_info != .Struct) {
            @compileError("Expected tuple or struct argument, found " ++ @typeName(ComponentsType));
        }

        defer world.next_entity += 1;

        std.debug.print("Make entity {}, with\n", .{world.next_entity});

        var component_names = std.ArrayList([]const u8).init(world.allocator);

        //@setEvalBranchQuota(2000000);
        inline for (components_type_info.Struct.fields) |struct_field| {
            const field = @field(components, struct_field.name);
            const FieldType = @TypeOf(field);
            const field_type_info = @typeInfo(FieldType);

            if (field_type_info != .Struct) {
                @compileError("Expected " ++ struct_field.name ++ " to be a Type, found " ++ @typeName(struct_field.field_type));
            }

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

        if (world.findArchetype(component_names)) |archetype| {
            defer component_names.deinit();

            std.debug.print(" Found existing archetype: ", .{});
            for (archetype.component_names.items) |name, i| {
                if (i != 0) {
                    std.debug.print("-", .{});
                }
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n", .{});
        } else {
            var archetype = try world.archetypes.addOne();
            archetype.component_names = component_names;
            archetype.components = std.ArrayList(ComponentHolder).init(world.allocator);

            std.debug.print(" Creating archetype: ", .{});
            for (component_names.items) |name, i| {
                if (i != 0) {
                    std.debug.print("-", .{});
                }
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n", .{});
        }
    }
};

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
};

const ComponentHolder = struct {
    type_erased_list: *anyopaque, // *std.ArrayList(Componenet)
};

///////////////////////////////////////////////////////////////////////////////
// test
//

test "abc" {
    std.debug.print("\n", .{});

    var allocator = std.testing.allocator;
    var world = World.init(allocator);
    //defer world.deinit();
    _ = world;

    const Person = struct {
    };

    const Age = struct {
        age: u32,
    };

    const Chair = struct {
    };

    try world.make(.{
        Person{},
        Age{.age = 30},
    });

    try world.make(.{
        Chair{},
    });

    try world.make(.{
        Age{.age = 20},
        Person{},
    });

    const DammsugarNjutare = struct {
    };

    const KaffeBeroende = struct {
    };

    const Name = struct {
        name: []const u8
    };

    try world.make(.{
        Person{},
        Age{.age = 45},
        DammsugarNjutare{},
        KaffeBeroende{},
        Name{.name = "Danny"},
    });
}

///////////////////////////////////////////////////////////////////////////////

//export fn add(a: i32, b: i32) i32 {
//    return a + b;
//}

//test "basic add functionality" {
    //try testing.expect(add(3, 7) == 10);
//}
