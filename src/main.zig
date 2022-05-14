const std = @import("std");
const testing = std.testing;

const Entity = u64;
const ComponentId = Entity;

const World = struct {
    allocator: std.mem.Allocator,
    archetypes: std.ArrayList(Archetype),
    entities: std.AutoHashMap(Entity, std.ArrayList(ComponentId)),
    next_entity: Entity,

    fn init(allocator: std.mem.Allocator) World {
        return World{
            .allocator = allocator,
            .archetypes = std.ArrayList(Archetype).init(allocator),
            .entities = std.AutoHashMap(Entity, std.ArrayList(ComponentId)).init(allocator),
            .next_entity = 0,
        };
    }

    fn findArchetype(world: *World, component_ids: std.ArrayList(ComponentId)) ?*Archetype {
        for (world.archetypes.items) |*archetype| {
            var found = true;
            for (archetype.*.component_ids.items) |component_id, i| {
                if (component_id != component_ids.items[i]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return archetype;
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

        var archetype_name = std.ArrayList(u8).init(world.allocator);

        var hashes = std.ArrayList(u64).init(world.allocator);

        //@setEvalBranchQuota(2000000);
        inline for (components_type_info.Struct.fields) |struct_field, field_idx| {
            const field = @field(components, struct_field.name);
            const FieldType = @TypeOf(field);
            const field_type_info = @typeInfo(FieldType);

            if (field_type_info != .Struct) {
                @compileError("Expected " ++ struct_field.name ++ " to be a Type, found " ++ @typeName(struct_field.field_type));
            }

            if (field_idx > 0) {
                try archetype_name.append('-');
            }

            const component_name = @typeName(FieldType);

            var hash = std.hash.Wyhash.hash(0, component_name[0..]);

            var i: usize = 0;
            while (true) : (i += 1) {
                if (i >= hashes.items.len) {
                    try hashes.append(hash);
                    break;
                }

                if (hash < hashes.items[i]) {
                    try hashes.insert(i, hash);
                    break;
                }
            }

            std.debug.print(" component: {s}, hash: {}\n", .{component_name, hash});

            try archetype_name.appendSlice(component_name[0..]);
        }

        var archetype_hash: u64 = 0;
        for (hashes.items) |hash| {
            var h: [*]const u8 = @ptrCast([*]const u8, &hash);
            archetype_hash = std.hash.Wyhash.hash(archetype_hash, h[0..4]);
        }

        std.debug.print("archetype: {s}, archetype_hash: {}\n", .{archetype_name.items[0..], archetype_hash});

        if (world.findArchetype(hashes)) |archetype| {
            defer hashes.deinit();
            defer archetype_name.deinit();

            std.debug.print("found existing archetype: {s}\n", .{archetype.name.items});
        } else {
            var archetype = try world.archetypes.addOne();
            archetype.component_ids = hashes;
            archetype.components = std.ArrayList(ComponentHolder).init(world.allocator);
            archetype.id = archetype_hash;
            archetype.name = archetype_name;
        }

        // TODO cgustafsson: otherwise add a new one
    }
};

/// An archetype is a set of components.
///
/// # How to query for a component
///
/// Archetype Components
/// --------------------
/// X         A, B, C
/// Y         A, B
/// Z         A, C
///
/// Query(.{A})    -> .{X, Y, Z}
/// Query(.{A, B}) -> .{X, Y}
/// Query(.{A, C}) -> .{X, Z}
///
///
/// entity components archetype
///
/// X      A, B       1
/// Y      A, B, C    2
///
/// Query(.{A, B}) -> .{1, 2}
///
///

const Archetype = struct {
    component_ids: std.ArrayList(ComponentId), //< Sorted list of component ids.
    components: std.ArrayList(ComponentHolder), //< List of component lists.

    // entities: std.ArrrayList(Entity), // TODO cgustafsson: can this be used for anything?
    id: ComponentId, // TODO cgustafsson: not used for anything? :(
    name: std.ArrayList(u8), // TODO cgustafsson: debug only?
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
