const std = @import("std");
const testing = std.testing;

/// Turn on for internal debug messages for all functions.
const debug_print: bool = true;

const Entity = u64;

// todo
//
// EntityId -> Type

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

    /// Make a new entity, with the given `components`, in the `world`.
    fn make(world: *World, components: anytype) !void {
        defer world.next_entity += 1;

        if (debug_print) std.debug.print("Make entity {}, with\n", .{world.next_entity});

        const component_names = fieldTypesToStringsSorted(components);

        if (world.findArchetypeExact(component_names)) |archetype| {
            if (debug_print) std.debug.print("  Found existing archetype: ", .{});
            if (debug_print) archetype.dump();
            if (debug_print) std.debug.print("\n", .{});

            inline for (std.meta.fields(@TypeOf(components))) |struct_field| {
                const field = @field(components, struct_field.name);
                const FieldType = @TypeOf(field);
                if (debug_print) std.debug.print("  Appending to existing component, {any}\n", .{field});
                if (archetype.find(@typeName(FieldType))) |component_holder| {
                    var typed_component_list = @ptrCast(*std.ArrayList(FieldType), &component_holder.type_erased_list);
                    try typed_component_list.append(field);
                } else {
                    // Should be compiler error here, but ICE.
                    // todo in future zig version
                    //std.debug.panic("Could not find the correct component holder, but the component name was found?", .{});
                }
            }
        } else {
            var archetype = try world.archetypes.addOne();
            archetype.component_names = component_names;
            archetype.components = std.ArrayList(ComponentHolder).init(world.allocator);

            if (debug_print) std.debug.print("  Creating archetype: ", .{});
            if (debug_print) archetype.dump();
            if (debug_print) std.debug.print("\n", .{});

            inline for (std.meta.fields(@TypeOf(components))) |struct_field, struct_i| {
                const field = @field(components, struct_field.name);
                const FieldType = @TypeOf(field);
                const component_name = @typeName(FieldType);

                // NOTE: For loop needed for when component_names are sorted.
                for (component_names) |inner_component_name, name_i| {
                    // Make sure to insert components in same order as the `component_names` (sorted).

                    if (std.mem.eql(u8, inner_component_name, component_name)) {
                        if (debug_print) std.debug.print("  New component {any} @{}. In archetype: {{name: {s}, name_i: {}}}\n", .{field, struct_i, inner_component_name, name_i});
                        var new_component_list = std.ArrayList(FieldType).init(world.allocator);
                        try new_component_list.append(field);

                        // Cannot declare the closure here, compiler will fail to run it.
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
                    }
                }
            }
        }
    }

    /// world.query(.{A, B, C}) -> .{[]A, []B, []C}
    ///
    /// Example
    /// ```
    /// var iter = world.query(.{A, B});
    /// while (iter.next()) |res}| {
    ///   std.debug.print("{}, {}", .{res.@"0".value, res.@"1".value});
    /// }
    /// ```
    fn query(world: *World, components: anytype) !Iterator(components) {
        return Iterator(components).init(world);
    }

    fn remove(world: *World) void {
        _ = world;
    }

    /// Find the archetype that has the exact `component_names`.
    fn findArchetypeExact(world: *World, component_names: []const []const u8) ?*Archetype {
        for (world.archetypes.items) |*archetype| {
            if (archetype.*.component_names.len == component_names.len) {
                for (archetype.*.component_names) |inner_component_name| {
                    var found = false;
                    for (component_names) |component_name| {
                        if (std.mem.eql(u8, inner_component_name, component_name)) {
                            found = true;
                            break;
                        }
                    }

                    if (!found) return null;
                }

                return archetype;
            }
        }

        return null;
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

/// Helper generic function to generate the deinit function for an `ArrayList(Component)`.
fn deinitComponent(comptime Component: type) type {
    return struct {
        fn deinit(list: std.ArrayList(ComponentHolder.Dummy)) void {
            var typed_list = @ptrCast(*const std.ArrayList(Component), &list).*;
            typed_list.deinit();
        }
    };
}

/// Iterate over `components` in a `world`.
///
/// Calling `next` will seamlessly iterate over multiplie archetypes as needed.
///
/// Unfortunately, has to allocate memory since we don't know how many archetypes the `components` will be contained in.
fn Iterator(components: anytype) type {
    return struct {
        const Self = @This();
        //const ComponentTypes = GetTupleTypes(components);
        const ComponentSlices = StructOfTypesToStructOfPointers(components, .Slice);
        const Entry: type = StructOfTypesToStructOfPointers(components, .One);

        component_slices: std.ArrayList(ComponentSlices),
        archetype_i: u32 = 0,
        slice_i: u32 = 0,

        fn init(world: *World) !Self {
            var iter = Self{.component_slices = std.ArrayList(ComponentSlices).init(world.allocator)};

            // find all the archetypes that contain `components`,
            // then makes slices and put it in our list
            //world.

            const component_names = fieldTypesToStrings(components);

            for (world.archetypes.items) |archetype| {
                var slices = try iter.component_slices.addOne();
                var matches: u32 = 0;

                // reuse the componets tuple, to grab the field name and use for slices
                inline for (std.meta.fields(@TypeOf(components))) |field| {
                    var slice = &@field(slices, field.name);
                    const ComponentType = @field(components, field.name);
                    if (archetype.find(@typeName(ComponentType))) |component_holder| {
                        var typed_component = @ptrCast(*std.ArrayList(ComponentType), &component_holder.type_erased_list);
                        slice.* = typed_component.items[0..];
                        matches += 1;
                    }
                }

                if (matches != component_names.len) {
                    _ = iter.component_slices.pop();
                }
            }

            return iter;
        }

        fn deinit(iter: Self) void {
            iter.component_slices.deinit();
        }

        fn next(iter: *Self) ?Entry {
            if (iter.archetype_i < iter.component_slices.items.len) {
                var slices = &iter.component_slices.items[iter.archetype_i];

                iter.slice_i += 1;
                if (iter.slice_i <= slices.@"0".len) {
                    var entry: Entry = undefined;
                    inline for (std.meta.fields(Entry)) |field| {
                        //const Type = @field(Entry, field.name);
                        var entry_field = &@field(entry, field.name);
                        var slice = &@field(slices, field.name)[iter.slice_i-1];
                        entry_field.* = slice;
                    }
                    return entry;
                } else {
                    iter.archetype_i += 1;
                    iter.slice_i = 0;
                    return next(iter);
                }
            }

            return null;
        }
    };
}

/// fieldTypesToStrings(.{A, C, B}) -> ["A", "C", "B"]
fn fieldTypesToStrings(tuple: anytype) []const []const u8 {
    comptime {
        var out: [std.meta.fields(@TypeOf(tuple)).len][]const u8 = undefined;

        inline for (std.meta.fields(@TypeOf(tuple))) |field, i| {
            if (std.meta.trait.is(.Type)(field.field_type)) {
                const f = @field(tuple, field.name);
                out[i] = @typeName(f);
            } else {
                out[i] = @typeName(field.field_type);
            }
        }

        return out[0..];
    }
}

test "tuple types to string array happy path" {
    const res = fieldTypesToStrings(.{A, C, B});

    try std.testing.expectEqualStrings("A", res[0]);
    try std.testing.expectEqualStrings("C", res[1]);
    try std.testing.expectEqualStrings("B", res[2]);
}

/// fieldTypesToStringsSorted(.{A, C, B}) -> ["A", "B", "C"]
fn fieldTypesToStringsSorted(tuple: anytype) []const []const u8 {
    comptime {
        var out: [std.meta.fields(@TypeOf(tuple)).len][]const u8 = undefined;

        inline for (std.meta.fields(@TypeOf(tuple))) |field| {
            // NOTE: Sadly dont seem to be able to break out this `getName` to a function.
            var name: []const u8 = undefined;
            if (std.meta.trait.is(.Type)(field.field_type)) {
                const f = @field(tuple, field.name);
                name = @typeName(f);
            } else {
                name = @typeName(field.field_type);
            }

            var pos: u32 = 0;
            inline for(std.meta.fields(@TypeOf(tuple))) |inner_field| {
                var inner_name: []const u8 = undefined;
                if (std.meta.trait.is(.Type)(inner_field.field_type)) {
                    const f = @field(tuple, inner_field.name);
                    inner_name = @typeName(f);
                } else {
                    inner_name = @typeName(inner_field.field_type);
                }

                const order = std.mem.order(u8, name, inner_name);
                if (order == std.math.Order.gt) {
                    pos += 1;
                }
            }

            out[pos] = name;
        }

        return out[0..];
    }
}

test "tuple types to sorted string array happy path" {
    const res = fieldTypesToStringsSorted(.{A, C, B});

    try std.testing.expectEqualStrings("A", res[0]);
    try std.testing.expectEqualStrings("B", res[1]);
    try std.testing.expectEqualStrings("C", res[2]);
}

/// Given some types A, B and C, in a struct. Return a type like so:
///
/// with `pointer_size`.One:
///   .{A, B, C} -> .{*A, *B, *C}
///
/// with `pointer_size` .Slice:
/// .{A, B, C} -> .{[]A, []B, []C}
///
fn StructOfTypesToStructOfPointers(t: anytype, pointer_size: std.builtin.Type.Pointer.Size) type {
    comptime {
        const Type = @TypeOf(t);
        const fields = std.meta.fields(Type);

        var fields_out: [fields.len]std.builtin.Type.StructField = undefined;

        inline for (fields) |field, i| {
            const f = @field(t, field.name);
            fields_out[i] = .{
                .name = field.name,
                .field_type = @Type(.{
                    .Pointer = .{
                        .size = pointer_size,
                        .is_const = false,
                        .is_volatile = false,
                        .alignment = 0,
                        .address_space = .generic,
                        .child = f,
                        .is_allowzero = false,
                        .sentinel = null,
                    }
                }),
                .default_value = null,
                .is_comptime = false,
                .alignment = field.alignment,
            };
        }

        const OutType = @Type(.{
            .Struct = .{
                .layout = .Auto,
                .fields = fields_out[0..],
                .decls = &.{},
                .is_tuple = false,
            }
        });

        return OutType;
    }
}

test "convert struct of types to struct of pointers happy path" {
    const Struct_ = .{A, B};
    const StructOfPointers = StructOfTypesToStructOfPointers(Struct_, .One);

    // cannot use StructOfPointers directly for some reason, use this...
    var a = A{};
    var b = B{.b=5};
    const dummy = StructOfPointers{.@"0" = &a, .@"1" = &b};

    try std.testing.expectEqual(Struct_.@"0", @TypeOf(dummy.@"0".*));
    try std.testing.expectEqual(Struct_.@"1", @TypeOf(dummy.@"1".*));
}

test "convert struct of types to struct of slices happy path" {
    const Struct_ = .{A, B};
    const StructOfSlices = StructOfTypesToStructOfPointers(Struct_, .Slice);

    // cannot use StructOfSlices directly for some reason, use this...
    var a = [_]A{A{}, A{}};
    var b = [_]B{B{.b=5}};
    const dummy = StructOfSlices{.@"0" = a[0..], .@"1" = b[0..]};

    try std.testing.expectEqual(Struct_.@"0", @TypeOf(dummy.@"0"[0]));
    try std.testing.expectEqual(Struct_.@"1", @TypeOf(dummy.@"1"[0]));
}

/// An archetype is a set of components.
///
/// // TODO cgustafsson: old comment
/// # Query for a component
///
/// entity components archetype
/// ---------------------------
/// 1      A, B       X
/// 2      A, B, C    Y
/// 3      B, C       Z
///
/// Query(.{A})    -> .{X, Y, Z}
/// Query(.{A, B}) -> .{X, Y}
/// Query(.{B, C}) -> .{Y, Z}
///
const Archetype = struct {
    component_names: []const []const u8,
    components: std.ArrayList(ComponentHolder),

    fn deinit(archetype: *Archetype) void {
        for (archetype.components.items) |*component_holder| {
            component_holder.deinit();
        }
        archetype.components.deinit();
    }

    /// Find the ComponentHolder for a `component_name` in this `archetype`.
    /// archetype{A, B, C}.find("B") -> *component_holder{B}
    /// archetype{A, B, C}.find("W") -> null
    fn find(archetype: Archetype, component_name: []const u8) ?*ComponentHolder {
        for (archetype.component_names) |archetype_component_name, i| {
            if (std.mem.eql(u8, archetype_component_name, component_name)) {
                return &archetype.components.items[i];
            }
        }

        return null;
    }

    fn dump(archetype: Archetype) void {
        for (archetype.component_names) |name, i| {
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

test "showcase" {
    // make the world
    var allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    // these are our components
    const Person = struct {};
    const Age = struct {age: u32,};
    const Squirel = struct {};

    // make some entities
    try world.make(.{Person{}, Age{.age = 30,}});
    try world.make(.{Person{}, Age{.age = 77,}});
    try world.make(.{Squirel{}, Age{.age = 2}});

    // find the entities that are `Person` and `Age`.
    var person_iter = try world.query(.{Person, Age});
    defer person_iter.deinit(); // sadly needed for now
    while (person_iter.next()) |res| {
        std.debug.print("🧔 Person, age {}.\n", .{res.@"1".age});
    }

    // find the entities that are `Squirel` and `Age`.
    var squirel_iter = try world.query(.{Squirel, Age});
    defer squirel_iter.deinit(); // sadly needed for now
    while (squirel_iter.next()) |res| {
        std.debug.print("🐿 Squirel, age {}.\n", .{res.@"1".age});
    }
}

test "complex world" {
    std.debug.print("\n", .{});

    var allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const Person = struct {};

    const Age = struct {
        age: u32,
    };

    const Chair = struct {};

    const DammsugarNjutare = struct {};

    const KaffeBeroende = struct {};

    const Name = struct { name: []const u8 };

    try world.make(.{
        Person{},
        Age{ .age = 30 },
    });

    world.dump();

    try world.make(.{
        Chair{},
    });

    //world.dump();

    try world.make(.{
        Age{ .age = 20 },
        Person{},
    });

    world.dump();

    try world.make(.{
        Person{},
        Age{ .age = 45 },
        DammsugarNjutare{},
        KaffeBeroende{},
        Name{ .name = "Danny" },
    });

    world.dump();

    var iter = try world.query(.{Age, Person});
    defer iter.deinit();

    if (iter.next()) |t| {
        try std.testing.expectEqual(t.@"0".*, Age{.age = 30});
        try std.testing.expectEqual(t.@"1".*, Person{});
    } else {
        try std.testing.expect(false);
    }

    if (iter.next()) |t| {
        try std.testing.expectEqual(t.@"0".*, Age{.age = 20});
        try std.testing.expectEqual(t.@"1".*, Person{});
    } else {
        try std.testing.expect(false);
    }

    if (iter.next()) |t| {
        try std.testing.expectEqual(t.@"0".*, Age{.age = 45});
        try std.testing.expectEqual(t.@"1".*, Person{});
    } else {
        try std.testing.expect(false);
    }

    //std.debug.print("\nworld.query(.{any}) ->\n", .{.{Age, Person}});
    //while (iter.next()) |t| {
    //    std.debug.print("  {any}, {any}\n", .{t.@"0", t.@"1"});
    //}
}

///////////////////////////////////////////////////////////////////////////////

// used for testing
const A = struct { };
const B = struct { b: u32, };
const C = struct { c: f32, };
