# Ecs system, written in Zig.

``` zig
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

    // find the entities that have `Age`.
    var age_iter = try world.query(.{Age});
    defer age_iter.deinit(); // sadly needed for now
    while (age_iter.next()) |res| {
        std.debug.print("👴 age {}.\n", .{res.@"0".age});
    }
}
```
outputs:

```
test "showcase"...
🧔 Person, age 30.
🧔 Person, age 77.
🐿 Squirel, age 2.
👴 age 30.
👴 age 77.
👴 age 2.
OK
```
