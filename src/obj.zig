// zig fmt: off
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const StringHashMap = std.StringHashMap;
const Chunk = @import("./chunk.zig").Chunk;
const VM = @import("./vm.zig").VM;
const Compiler = @import("./compiler.zig").Compiler;
const _memory = @import("./memory.zig");
const _value = @import("./value.zig");
const Token = @import("./token.zig").Token;
const Config = @import("./config.zig").Config;

const Value = _value.Value;
const HashableValue = _value.HashableValue;
const ValueType = _value.ValueType;
const valueToHashable = _value.valueToHashable;
const hashableToValue = _value.hashableToValue;
const valueToString = _value.valueToString;
const valueEql = _value.valueEql;
const allocate = _memory.allocate;
const allocateMany = _memory.allocateMany;
const free = _memory.free;
const freeMany = _memory.freeMany;
const markObj = _memory.markObj;
const markValue = _memory.markValue;
const collectGarbage = _memory.collectGarbage;

pub const ObjType = enum {
    String,
    Type,
    UpValue,
    Closure,
    Function,
    ObjectInstance,
    Object,
    List,
    Map,
    Enum,
    EnumInstance,
    Bound,
    Native,
    Error,
};

pub fn allocateObject(vm: *VM, comptime T: type, data: T) !*T {
    var before: usize = vm.bytes_allocated;

    var obj: *T = try allocate(vm, T);
    obj.* = data;

    // TODO: How to avoid this?
    var object: *Obj = switch (T) {
        ObjString => ObjString.toObj(obj),
        ObjTypeDef => ObjTypeDef.toObj(obj),
        ObjUpValue => ObjUpValue.toObj(obj),
        ObjClosure => ObjClosure.toObj(obj),
        ObjFunction => ObjFunction.toObj(obj),
        ObjObjectInstance => ObjObjectInstance.toObj(obj),
        ObjObject => ObjObject.toObj(obj),
        ObjList => ObjList.toObj(obj),
        ObjMap => ObjMap.toObj(obj),
        ObjEnum => ObjEnum.toObj(obj),
        ObjEnumInstance => ObjEnumInstance.toObj(obj),
        ObjBoundMethod => ObjBoundMethod.toObj(obj),
        ObjNative => ObjNative.toObj(obj),
        ObjError => ObjError.toObj(obj),
        else => {}
    };

    if (Config.debug_gc) {
        std.debug.warn("allocated {*} {*}\n", .{ obj, object });
        std.debug.warn("(from {}) {} allocated, total {}\n", .{ before, @sizeOf(T), vm.bytes_allocated });
    }

    // Add new object at start of vm.objects linked list
    object.next = vm.objects;
    vm.objects = object;

    return obj;
}

pub fn allocateString(vm: *VM, chars: []const u8) !*ObjString {
    if (vm.strings.get(chars)) |interned| {
        return interned;
    } else {
        var string: *ObjString = try allocateObject(vm, ObjString, ObjString{ .string = chars });

        vm.push(Value { .Obj = string.toObj() });
        try vm.strings.put(chars, string);
        _ = vm.pop();

        return string;
    }
}

pub fn copyString(vm: *VM, chars: []const u8) !*ObjString {
    if (vm.strings.get(chars)) |interned| {
        return interned;
    }

    var copy: []u8 = try allocateMany(vm, u8, chars.len);
    mem.copy(u8, copy, chars);

    return try allocateString(vm, copy);
}

pub fn copyStringRaw(strings: *std.StringHashMap(*ObjString), allocator: *Allocator, chars: []const u8) !*ObjString {
    if (strings.get(chars)) |interned| {
        return interned;
    }

    var copy: []u8 = try allocator.alloc(u8, chars.len);
    mem.copy(u8, copy, chars);

    var obj_string: *ObjString = try allocator.create(ObjString);
    obj_string.* = ObjString {
        .string = copy
    };

    try strings.put(chars, obj_string);

    return obj_string;
}

pub const Obj = struct {
    const Self = @This();

    obj_type: ObjType,
    is_marked: bool = false,
    // If true, will never be collected: useful for compiler functions which are never on the stack
    next: ?*Obj = null,

    pub fn eql(self: *Self, other: *Self) bool {
        if (self.obj_type != other.obj_type) {
            return false;
        }

        switch (self.obj_type) {
            .String => {
                // return mem.eql(u8, ObjString.cast(self).?.string, ObjString.cast(other).?.string);
                
                // since string are interned this should be enough
                return self == other;
            },
            .Type => {
                const self_type: *ObjTypeDef = ObjTypeDef.cast(self).?;
                const other_type: *ObjTypeDef = ObjTypeDef.cast(other).?;

                return self_type.optional == other_type.optional and self_type.eql(other_type);
            },
            .UpValue => {
                const self_upvalue: *ObjUpValue = ObjUpValue.cast(self).?;
                const other_upvalue: *ObjUpValue = ObjUpValue.cast(other).?;

                return valueEql(self_upvalue.closed orelse self_upvalue.location.*, other_upvalue.closed orelse other_upvalue.location.*);
            },
            .Bound,
            .Closure,
            .Function,
            .ObjectInstance,
            .Object,
            .List,
            .Map,
            .Enum,
            .EnumInstance,
            .Native,
            .Error => {
                return self == other;
            },
        }
    }
};

// If returns false, no return value
pub const NativeFn = fn (vm: *VM) bool;

/// Native function
pub const ObjNative = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Native
    },

    native: NativeFn,

    pub fn mark(_: *Self, _: *VM) void {
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Native) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

pub const ObjError = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Error
    },

    message: *ObjString,
    // payload: *ObjObjectInstance // TODO: Instance of `Error`

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.message.toObj());
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Error) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// A String
pub const ObjString = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .String
    },

    /// The actual string
    string: []const u8,

    pub fn mark(_: *Self, _: *VM) void {
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .String) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn concat(self: *Self, vm: *VM, other: *Self) !*Self {
        var new_string: std.ArrayList(u8) = std.ArrayList(u8).init(vm.allocator);
        try new_string.appendSlice(self.string);
        try new_string.appendSlice(other.string);

        return copyString(vm, new_string.items);
    }
};

/// Upvalue
pub const ObjUpValue = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .UpValue
    },

    /// Slot on the stack
    location: *Value,
    closed: ?Value,
    next: ?*ObjUpValue = null,

    pub fn init(slot: *Value) Self {
        return Self {
            .closed = null,
            .location = slot,
            .next = null
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        if (self.closed) |uclosed| {
            try markValue(vm, uclosed);
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .UpValue) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Closure
pub const ObjClosure = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Closure
    },

    function: *ObjFunction,
    catch_closure: ?*ObjClosure = null,
    upvalues: std.ArrayList(*ObjUpValue),

    pub fn init(allocator: *Allocator, function: *ObjFunction) !Self {
        return Self {
            .function = function,
            .upvalues = try std.ArrayList(*ObjUpValue).initCapacity(allocator, function.upvalue_count),
        };
    }
    
    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.function.toObj());
        if (self.catch_closure) |catch_closure| {
            try markObj(vm, catch_closure.toObj());
        }
        for (self.upvalues.items) |upvalue| {
            try markObj(vm, upvalue.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.upvalues.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Closure) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Function
pub const ObjFunction = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Function
    },

    name: *ObjString,
    parameters: std.StringArrayHashMap(*ObjTypeDef),
    return_type: *ObjTypeDef,
    chunk: Chunk,
    upvalue_count: u8 = 0,

    pub fn init(allocator: *Allocator, name: *ObjString, return_type: *ObjTypeDef) !Self {
        return Self {
            .name = name,
            .return_type = return_type,
            .parameters = std.StringArrayHashMap(*ObjTypeDef).init(allocator),
            .chunk = Chunk.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.parameters.deinit();
        self.chunk.deinit();
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.name.toObj());
        
        var it = self.parameters.iterator();
        while (it.next()) |kv| {
            try markObj(vm, kv.value_ptr.*.toObj());
        }
        try markObj(vm, self.return_type.toObj());

        for (self.chunk.constants.items) |constant| {
            try markValue(vm, constant);
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Function) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const FunctionDef = struct {
        name: *ObjString,
        return_type: *ObjTypeDef,
        parameters: std.StringArrayHashMap(*ObjTypeDef),
    };
};

/// Object instance
pub const ObjObjectInstance = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .ObjectInstance
    },

    /// Object
    object: *ObjObject,
    /// Fields value
    fields: StringHashMap(Value),

    pub fn init(allocator: *Allocator, object: *ObjObject) Self {
        return Self {
            .object = object,
            .fields = StringHashMap(Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.object.toObj());
        var it = self.fields.iterator();
        while (it.next()) |kv| {
            try markValue(vm, kv.value_ptr.*);
        }
    }

    pub fn deinit(self: *Self) void {
        self.fields.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .ObjectInstance) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Object
pub const ObjObject = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Object
    },

    /// Object name
    name: *ObjString,
    /// Object methods
    methods: StringHashMap(*ObjClosure),
    /// Object fields default values
    fields: StringHashMap(Value),
    /// Optional super class
    super: ?*ObjObject = null,
    /// If false, can't be inherited from
    inheritable: bool = false,

    pub fn init(allocator: *Allocator, name: *ObjString) Self {
        return Self {
            .name = name,
            .methods = StringHashMap(*ObjClosure).init(allocator),
            .fields = StringHashMap(Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.name.toObj());
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            try markObj(vm, kv.value_ptr.*.toObj());
        }
        var it2 = self.fields.iterator();
        while (it2.next()) |kv| {
            try markValue(vm, kv.value_ptr.*);
        }
        if (self.super) |super| {
            try markObj(vm, super.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.methods.deinit();
        self.fields.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Object) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const ObjectDef = struct {
        const ObjectDefSelf = @This();

        name: *ObjString,
        // TODO: Do i need to have two maps ?
        fields: StringHashMap(*ObjTypeDef),
        methods: StringHashMap(*ObjTypeDef),
        // When we have placeholders we don't know if they are properties or methods
        // That information is available only when the placeholder is resolved
        // It's not an issue since:
        //   - we use OP_GET_PROPERTY for both
        //   - OP_SET_PROPERTY for a method will ultimately fail
        //   - OP_INVOKE on a field will ultimately fail
        placeholders: StringHashMap(*ObjTypeDef),
        super: ?*ObjTypeDef = null,
        inheritable: bool = false,
        

        pub fn init(allocator: *Allocator, name: *ObjString) ObjectDefSelf {
            return ObjectDefSelf {
                .name = name,
                .fields = StringHashMap(*ObjTypeDef).init(allocator),
                .methods = StringHashMap(*ObjTypeDef).init(allocator),
                .placeholders = StringHashMap(*ObjTypeDef).init(allocator),
            };
        }

        pub fn deinit(self: *ObjectDefSelf) void {
            self.fields.deinit();
            self.methods.deinit();
            self.placeholders.deinit();
        }
    };
};

/// List
pub const ObjList = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .List
    },

    /// List items
    items: std.ArrayList(Value),
    // Used when printing the list
    item_type: *ObjTypeDef,

    methods: std.StringHashMap(*ObjNative),

    pub fn init(allocator: *Allocator, item_type: *ObjTypeDef) Self {
        return Self {
            .items = std.ArrayList(Value).init(allocator),
            .item_type = item_type,
            .methods = std.StringHashMap(*ObjNative).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        for (self.items.items) |value| {
            try markValue(vm, value);
        }
        try markObj(vm, self.item_type.toObj());
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            try markObj(vm, kv.value_ptr.*.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit();
        self.methods.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .List) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    // TODO: find a way to return the same ObjNative pointer for the same type of Lists
    pub fn member(self: *Self, vm: *VM, method: []const u8) !?*ObjNative {
        if (self.methods.get(method)) |native| {
            return native;
        }

        var nativeFn: ?NativeFn = null;
        if (mem.eql(u8, method, "append")) {
            nativeFn = append;
        } else if (mem.eql(u8, method, "len")) {
            nativeFn = len;
        }

        if (nativeFn) |unativeFn| {
            var native: *ObjNative = try allocateObject(vm, ObjNative, .{
                .native = unativeFn
            });

            try self.methods.put(method, native);

            return native;
        }

        return null;
    }

    fn append(vm: *VM) bool {
        var list_value: Value = vm.peek(1);
        var list: *ObjList = ObjList.cast(list_value.Obj).?;
        var value: Value = vm.peek(0);

        list.items.append(value) catch {
            vm.runtimeError("Could not append to list", null) catch {
                std.debug.warn("Could not append to list", .{});
                return false;
            };
            return false;
        };

        vm.push(list_value);

        return true;
    }

    fn len(vm: *VM) bool {
        var list: *ObjList = ObjList.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Number = @intToFloat(f64, list.items.items.len) });

        return true;
    }

    pub const ListDef = struct {
        const SelfListDef = @This();

        item_type: *ObjTypeDef,
        methods: std.StringHashMap(*ObjTypeDef),

        pub fn init(allocator: *Allocator, item_type: *ObjTypeDef) SelfListDef {
            return .{
                .item_type = item_type,
                .methods = std.StringHashMap(*ObjTypeDef).init(allocator)
            };
        }

        pub fn deinit(self: *SelfListDef) void {
            self.methods.deinit();
        }
        
        pub fn member(obj_list: *ObjTypeDef, compiler: *Compiler, method: []const u8) !?*ObjTypeDef {
            var self = obj_list.resolved_type.?.List;
            
            if (self.methods.get(method)) |native_def| {
                return native_def;
            }

            if (mem.eql(u8, method, "append")) {
                var parameters = std.StringArrayHashMap(*ObjTypeDef).init(compiler.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the list.

                // `value` arg is of item_type
                try  parameters.put("value", self.item_type);

                var method_def = ObjFunction.FunctionDef{
                    .name = try copyStringRaw(compiler.strings, compiler.allocator, "append"),
                    .parameters = parameters,
                    .return_type = obj_list
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{
                    .Native = method_def
                };

                var native_type = try compiler.getTypeDef(ObjTypeDef{
                    .optional = false,
                    .def_type = .Native,
                    .resolved_type = resolved_type
                });

                try self.methods.put("append", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "len")) {
                var parameters = std.StringArrayHashMap(*ObjTypeDef).init(compiler.allocator);

                var method_def = ObjFunction.FunctionDef{
                    .name = try copyStringRaw(compiler.strings, compiler.allocator, "len"),
                    .parameters = parameters,
                    .return_type = try compiler.getTypeDef(ObjTypeDef{
                        .optional = false,
                        .def_type = .Number,
                    })
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{
                    .Native = method_def
                };

                var native_type = try compiler.getTypeDef(ObjTypeDef{
                    .optional = false,
                    .def_type = .Native,
                    .resolved_type = resolved_type
                });

                try self.methods.put("len", native_type);

                return native_type;
            }

            return null;
        }
    };
};

/// Map
pub const ObjMap = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Map
    },

    map: std.AutoHashMap(HashableValue, Value),
    // Use when printing a map
    key_type: *ObjTypeDef,
    value_type: *ObjTypeDef,

    pub fn init(allocator: *Allocator, key_type: *ObjTypeDef, value_type: *ObjTypeDef) Self {
        return .{
            .key_type = key_type,
            .value_type = value_type,
            .map = std.AutoHashMap(HashableValue, Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            try markValue(vm, hashableToValue(kv.key_ptr.*));
            try markValue(vm, kv.value_ptr.*);
        }
        try markObj(vm, self.key_type.toObj());
        try markObj(vm, self.value_type.toObj());
    }
    
    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Map) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const MapDef = struct {
        key_type: *ObjTypeDef,
        value_type: *ObjTypeDef,
    };
};

/// Enum
pub const ObjEnum = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Enum
    },

    /// Used to allow type checking at runtime
    enum_def: *ObjTypeDef,

    name: *ObjString,
    cases: std.ArrayList(Value),

    pub fn init(allocator: *Allocator, def: *ObjTypeDef) Self {
        return Self {
            .enum_def = def,
            .name = def.resolved_type.?.Enum.name,
            .cases = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.name.toObj());
        try markObj(vm, self.enum_def.toObj());
        try markObj(vm, self.name.toObj());
        for (self.cases.items) |case| {
            try markValue(vm, case);
        } 
    }

    pub fn deinit(self: *Self) void {
        self.cases.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Enum) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const EnumDef = struct {
        const EnumDefSelf = @This();

        name: *ObjString,
        enum_type: *ObjTypeDef,
        cases: std.ArrayList([]const u8),

        pub fn init(allocator: *Allocator, name: *ObjString, enum_type: *ObjTypeDef) EnumDefSelf {
            return EnumDefSelf {
                .name = name,
                .cases = std.ArrayList([]const u8).init(allocator),
                .enum_type = enum_type,
            };
        }

        pub fn deinit(self: *EnumDefSelf) void {
            self.cases.deinit();
        }
    };
};

pub const ObjEnumInstance = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .EnumInstance
    },

    enum_ref: *ObjEnum,
    case: u8,

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.enum_ref.toObj());
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .EnumInstance) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn value(self: *Self) Value {
        return self.enum_ref.cases.items[self.case];
    }
};

/// Bound
pub const ObjBoundMethod = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Bound
    },

    receiver: Value,
    closure: ?*ObjClosure = null,
    native: ?*ObjNative = null,

    pub fn mark(self: *Self, vm: *VM) !void {
        try markValue(vm, self.receiver);
        if (self.closure) |closure| {
            try markObj(vm, closure.toObj());
        }
        if (self.native) |native| {
            try markObj(vm, native.toObj());
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Bound) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Type
pub const ObjTypeDef = struct {
    const Self = @This();

    pub const Type = enum {
        Bool,
        Number,
        String,
        ObjectInstance,
        Object,
        Enum,
        EnumInstance,
        List,
        Map,
        Function,
        Type, // Something that holds a type, not an actual type
        Void,
        Native,

        Placeholder, // Used in first-pass when we refer to a not yet parsed type
    };

    pub const TypeUnion = union(Type) {
        // For those type checking is obvious, the value is a placeholder
        Bool: bool,
        Number: bool,
        String: bool,
        Type: bool,
        Void: bool,

        // For those we check that the value is an instance of, because those are user defined types
        ObjectInstance: *ObjTypeDef,
        EnumInstance: *ObjTypeDef,

        // Those are never equal
        Object: ObjObject.ObjectDef,
        Enum: ObjEnum.EnumDef,

        // For those we compare definitions, so we own those structs, we don't use actual Obj because we don't want the data, only the types
        List: ObjList.ListDef,
        Map: ObjMap.MapDef,
        Function: ObjFunction.FunctionDef,
        Native: ObjFunction.FunctionDef,

        Placeholder: PlaceholderDef,
    };

    obj: Obj = .{
        .obj_type = .Type
    },

    /// True means its an optional (e.g `str?`)
    optional: bool,
    def_type: Type,
    /// Used when the type is not a basic type
    resolved_type: ?TypeUnion = null,

    pub fn deinit(_: *Self) void {
        std.debug.warn("ObjTypeDef.deinit not implemented\n", .{});
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        if (self.resolved_type) |resolved| {
            if (resolved == .ObjectInstance) {
                try markObj(vm, resolved.ObjectInstance.toObj());
            } else if (resolved == .EnumInstance) {
                try markObj(vm, resolved.EnumInstance.toObj());
            }
        }
    }

    /// Beware: allocates a string, caller owns it
    pub fn toString(self: Self, allocator: *Allocator) anyerror![]const u8 {
        var type_str: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);

        switch (self.def_type) {
            .Bool => try type_str.appendSlice("bool"),
            .Number => try type_str.appendSlice("num"),
            .String => try type_str.appendSlice("str"),

            // TODO: Find a key for vm.getTypeDef which is unique for each class even with the same name
            .Object => {
                try type_str.appendSlice("{ObjectDef}");
                try type_str.appendSlice(self.resolved_type.?.Object.name.string);
            },
            .Enum => {
                try type_str.appendSlice("{EnumDef}");
                try type_str.appendSlice(self.resolved_type.?.Enum.name.string);
            },
        
            .ObjectInstance => try type_str.appendSlice(self.resolved_type.?.ObjectInstance.resolved_type.?.Object.name.string),
            .EnumInstance => try type_str.appendSlice(self.resolved_type.?.EnumInstance.resolved_type.?.Enum.name.string),

            .List => {
                var list_type = try self.resolved_type.?.List.item_type.toString(allocator);
                defer allocator.free(list_type);

                try type_str.append('[');
                try type_str.appendSlice(list_type);
                try type_str.append(']');
            },
            .Map => {
                var key_type = try self.resolved_type.?.Map.key_type.toString(allocator);
                defer allocator.free(key_type);
                var value_type = try self.resolved_type.?.Map.value_type.toString(allocator);
                defer allocator.free(value_type);
                
                try type_str.append('{');
                try type_str.appendSlice(key_type);
                try type_str.append(',');
                try type_str.appendSlice(value_type);
                try type_str.append('}');
            },
            .Function => {
                var function_def = self.resolved_type.?.Function;

                try type_str.appendSlice("Function");
                try type_str.appendSlice(function_def.name.string);
                try type_str.appendSlice("(");

                var it = function_def.parameters.iterator();
                while (it.next()) |kv| {
                    var param_type = try kv.value_ptr.*.toString(allocator);
                    defer allocator.free(param_type);

                    try type_str.appendSlice(param_type);
                    try type_str.append(',');
                }

                try type_str.append(')');

                if (function_def.return_type.def_type != Type.Void) {
                    var return_type = try self.resolved_type.?.Function.return_type.toString(allocator);
                    defer allocator.free(return_type);

                    try type_str.appendSlice(") > ");
                    try type_str.appendSlice(return_type);
                }
            },
            .Type => try type_str.appendSlice("type"),
            .Void => try type_str.appendSlice("void"),

            .Placeholder => {
                try type_str.appendSlice("{PlaceholderDef}");
            },
            
            .Native => {
                try type_str.appendSlice("Native(");
                
                var ref: []u8 = try allocator.alloc(u8, 30);
                defer allocator.free(ref);
                ref = try std.fmt.bufPrint(ref, "{x}", .{ @ptrToInt(&self) });

                try type_str.appendSlice(ref);
                try type_str.appendSlice(")");
            }
        }

        if (self.optional) {
            try type_str.append('?');
        }

        return type_str.items;
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Type) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    // Compare two type definitions
    pub fn eqlTypeUnion(a: TypeUnion, b: TypeUnion) bool {
        if (@as(Type, a) != @as(Type, b)) {
            return false;
        }

        return switch (a) {
            .Bool, .Number, .String, .Type, .Void => return true,

            .ObjectInstance => return a.ObjectInstance.eql(b.ObjectInstance),
            .EnumInstance => return a.EnumInstance.eql(b.EnumInstance),

            .Object,
            .Enum => false, // Thore are never equal even if definition is the same

            .List => return a.List.item_type.eql(b.List.item_type),
            .Map => return a.Map.key_type.eql(b.Map.key_type)
                and a.Map.value_type.eql(b.Map.value_type),
            .Function => {
                // Compare return types
                if (a.Function.return_type.eql(b.Function.return_type)) {
                    return false;
                }

                // Compare arity
                if (a.Function.parameters.count() != b.Function.parameters.count()) {
                    return false;
                }

                // Compare parameters
                var it = a.Function.parameters.iterator();
                while (it.next()) |kv| {
                    if (b.Function.parameters.get(kv.key_ptr.*)) |value| {
                        if (!kv.value_ptr.*.eql(value)) {
                            return false;
                        }
                    } else {
                        return false;
                    }
                }

                return true;
            },

            .Placeholder => a.Placeholder.eql(b.Placeholder),
            .Native => {
                // Compare return types
                if (a.Native.return_type.eql(b.Native.return_type)) {
                    return false;
                }

                // Compare arity
                if (a.Native.parameters.count() != b.Native.parameters.count()) {
                    return false;
                }

                // Compare parameters
                var it = a.Native.parameters.iterator();
                while (it.next()) |kv| {
                    if (b.Native.parameters.get(kv.key_ptr.*)) |value| {
                        if (!kv.value_ptr.*.eql(value)) {
                            return false;
                        }
                    } else {
                        return false;
                    }
                }

                return true;
            },
        };
    }

    // Compare two type definitions
    pub fn eql(self: *Self, other: *Self) bool {
        const type_eql: bool = self.def_type == other.def_type
            and ((self.resolved_type == null and other.resolved_type == null)
                or eqlTypeUnion(self.resolved_type.?, other.resolved_type.?));

        return self == other
            or (self.optional and other.def_type == .Void) // Void is equal to any optional type
            or (type_eql or other.def_type == .Placeholder or self.def_type == .Placeholder);
    }
};

// TODO: use ArrayList writer instead of std.fmt.bufPrint
pub fn objToString(allocator: *Allocator, buf: []u8, obj: *Obj) anyerror![]u8 {
    return switch (obj.obj_type) {
        .String => try std.fmt.bufPrint(buf, "{s}", .{ ObjString.cast(obj).?.string }),
        .Type => {
            // TODO: no use for typedef.toString to allocate a buffer
            var type_def: *ObjTypeDef = ObjTypeDef.cast(obj).?; 
            var type_str: []const u8 = try type_def.toString(allocator);
            defer allocator.free(type_str);

            return try std.fmt.bufPrint(buf, "type: 0x{x} `{s}`", .{ @ptrToInt(type_def), type_str });
        },
        .UpValue => {
            var upvalue: *ObjUpValue = ObjUpValue.cast(obj).?;
            var upvalue_str: []const u8 = try valueToString(allocator, upvalue.closed orelse upvalue.location.*);
            defer allocator.free(upvalue_str);

            return try std.fmt.bufPrint(buf, "upvalue: 0x{x} `{s}`", .{ @ptrToInt(upvalue), upvalue_str });
        },
        .Closure => try std.fmt.bufPrint(buf, "closure: 0x{x} `{s}`", .{ @ptrToInt(ObjClosure.cast(obj).?), ObjClosure.cast(obj).?.function.name.string }),
        .Function => try std.fmt.bufPrint(buf, "function: 0x{x} `{s}`", .{ @ptrToInt(ObjFunction.cast(obj).?), ObjFunction.cast(obj).?.name.string }),
        .ObjectInstance => try std.fmt.bufPrint(buf, "object instance: 0x{x} `{s}`", .{ @ptrToInt(ObjObjectInstance.cast(obj).?), ObjObjectInstance.cast(obj).?.object.name.string }),
        .Object => try std.fmt.bufPrint(buf, "object: 0x{x} `{s}`", .{ @ptrToInt(ObjObject.cast(obj).?), ObjObject.cast(obj).?.name.string }),
        .List => {
            var list: *ObjList = ObjList.cast(obj).?;
            var type_str: []const u8 = try list.item_type.toString(allocator);
            defer allocator.free(type_str);

            return try std.fmt.bufPrint(buf, "list: 0x{x} [{s}]", .{ @ptrToInt(list), type_str });
        },
        .Map => {
            var map: *ObjMap = ObjMap.cast(obj).?;
            var key_type_str: []const u8 = try map.key_type.toString(allocator);
            defer allocator.free(key_type_str);
            var value_type_str: []const u8 = try map.value_type.toString(allocator);
            defer allocator.free(value_type_str);

            return try std.fmt.bufPrint(buf, "map: 0x{x} {{{s}, {s}}}", .{ @ptrToInt(map), key_type_str, value_type_str });
        },
        .Enum => try std.fmt.bufPrint(buf, "enum: 0x{x} `{s}`", .{ @ptrToInt(ObjEnum.cast(obj).?), ObjEnum.cast(obj).?.name.string }),
        .EnumInstance => enum_instance: {
            var instance: *ObjEnumInstance = ObjEnumInstance.cast(obj).?;
            var enum_: *ObjEnum = instance.enum_ref;

            break :enum_instance try std.fmt.bufPrint(
                buf,
                "{s}.{s}",
                .{
                    enum_.name.string,
                    enum_.enum_def.resolved_type.?.Enum.cases.items[instance.case]
                }
            );
        },
        .Bound => {
            var bound: *ObjBoundMethod = ObjBoundMethod.cast(obj).?;
            var receiver_str: []const u8 = try valueToString(allocator, bound.receiver);
            defer allocator.free(receiver_str);

            if (bound.closure) |closure| {
                var closure_name: []const u8 =  closure.function.name.string;
                return try std.fmt.bufPrint(buf, "bound method: {s} to {s}", .{ receiver_str, closure_name });
            } else {
                assert(bound.native != null);
                return try std.fmt.bufPrint(buf, "bound method: {s} to native 0x{}", .{ receiver_str, @ptrToInt(bound.native.?) });
            }
        },
        .Native => {
            var native: *ObjNative = ObjNative.cast(obj).?;

            return try std.fmt.bufPrint(buf, "native: 0x{x}", .{ @ptrToInt(native) });
        },
        .Error => {
            var err: *ObjError = ObjError.cast(obj).?;

            return try std.fmt.bufPrint(buf, "err: 0x{x} `{s}`", .{ @ptrToInt(err), err.message.string });
        }
    };
}

pub const PlaceholderDef = struct {
    const Self = @This();

    // TODO: are relations enough and booleans useless?
    const PlaceholderRelation = enum {
        Call,
        Subscript,
        FieldAccess,
        Assignment,
    };

    name: ?*ObjString = null,

    // Assumption made by the code referencing the value
    callable: ?bool = null,             // Function, Object or Class
    subscriptable: ?bool = null,        // Array or Map
    field_accessible: ?bool = null,     // Object, Class or Enum
    assignable: ?bool = null,           // Not a Function, Object, Class or Enum
    resolved_parameters: ?std.StringArrayHashMap(*ObjTypeDef) = null, // Maybe we resolved argument list but we don't know yet if Object/Class or Function
    resolved_def_type: ?ObjTypeDef.Type = null,    // Meta type
    // TODO: do we ever infer that much that we can build an actual type?
    resolved_type: ?*ObjTypeDef = null, // Actual type
    where: Token,                       // Where the placeholder was created

    // When accessing/calling/subscrit/assign a placeholder we produce another. We keep them linked so we
    // can trace back the root of the unknown type.
    parent: ?*ObjTypeDef = null,
    // What's the relation with the parent?
    parent_relation: ?PlaceholderRelation = null,
    // Children adds themselves here
    children: std.ArrayList(*ObjTypeDef),

    pub fn init(allocator: *Allocator, where: Token) Self {
        return Self {
            .where = where.clone(),
            .children = std.ArrayList(*ObjTypeDef).init(allocator)
        };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
    }

    pub fn link(parent: *ObjTypeDef, child: *ObjTypeDef, relation: PlaceholderRelation) !void {
        assert(parent.def_type == .Placeholder);
        assert(child.def_type == .Placeholder);

        child.resolved_type.?.Placeholder.parent = parent;
        try parent.resolved_type.?.Placeholder.children.append(child);
        child.resolved_type.?.Placeholder.parent_relation = relation;
    }

    pub fn eql(a: Self, b: Self) bool {
        if (a.resolved_parameters != null and b.resolved_parameters != null) {
            var it = a.resolved_parameters.?.iterator();
            while (it.next()) |kv| {
                if (b.resolved_parameters.?.get(kv.key_ptr.*)) |b_arg_type| {
                    return b_arg_type.eql(kv.value_ptr.*);
                } else {
                    return false;
                }
            }
        }

        return ((a.callable != null and b.callable != null and a.callable.? == b.callable.?) or a.callable == null or b.callable == null)
            and ((a.subscriptable != null and b.subscriptable != null and a.subscriptable.? == b.subscriptable.?) or a.subscriptable == null or b.subscriptable == null)
            and ((a.field_accessible != null and b.field_accessible != null and a.field_accessible.? == b.field_accessible.?) or a.field_accessible == null or b.subscriptable == null)
            and ((a.assignable != null and b.assignable != null and a.assignable.? == b.assignable.?) or a.assignable == null or b.subscriptable == null)
            and ((a.resolved_def_type != null and b.resolved_def_type != null and a.resolved_def_type.? == b.resolved_def_type.?) or a.resolved_def_type == null or b.resolved_def_type == null)
            and ((a.resolved_type != null and b.resolved_type != null and a.resolved_type.?.eql(b.resolved_type.?)) or a.resolved_type == null or b.subscriptable == null);
    }

    pub fn enrich(one: *Self, other: *Self) !void {
        one.callable = one.callable orelse other.callable;
        other.callable = one.callable orelse other.callable;

        one.subscriptable = one.subscriptable orelse other.subscriptable;
        other.subscriptable = one.subscriptable orelse other.subscriptable;

        one.field_accessible = one.field_accessible orelse other.field_accessible;
        other.field_accessible = one.field_accessible orelse other.field_accessible;

        one.assignable = one.assignable orelse other.assignable;
        other.assignable = one.assignable orelse other.assignable;

        one.resolved_def_type = one.resolved_def_type orelse other.resolved_def_type;
        other.resolved_def_type = one.resolved_def_type orelse other.resolved_def_type;

        one.resolved_type = one.resolved_type orelse other.resolved_type;
        other.resolved_type = one.resolved_type orelse other.resolved_type;

        if (other.resolved_parameters) |parameters| {
            one.resolved_parameters = try parameters.clone();
        } else if (one.resolved_parameters) |parameters| {
            other.resolved_parameters = try parameters.clone();
        }
    }

    // TODO: zig bug here
    pub fn isBasicType(self: Self, basic_type: ObjTypeDef.Type) bool {
        return self.resolved_def_type == basic_type
                or (self.resolved_type != null and self.resolved_type.?.def_type == basic_type);
    }

    pub fn isAssignable(self: *Self) bool {
        if (self.assignable == null) {
            return true;
        }

        return self.assignable.?
            and (self.resolved_def_type == null
                // TODO: method actually but right now we have no way to distinguish them
                or self.resolved_def_type.? != .Function
                or self.resolved_def_type.? != .Object)
            and (self.resolved_type == null
                // TODO: method actually but right now we have no way to distinguish them
                or self.resolved_type.?.def_type != .Function
                or self.resolved_type.?.def_type != .Object);
    }

    pub fn isCallable(self: *Self) bool {
        if (self.callable == null) {
            return true;
        }

        return self.callable.?
            and (self.resolved_def_type == null
                or self.resolved_def_type.? == .Function
                or self.resolved_def_type.? == .Object)
            and (self.resolved_type == null
                or self.resolved_type.?.def_type == .Function
                or self.resolved_type.?.def_type == .Object);
    }

    pub fn isFieldAccessible(self: *Self) bool {
        if (self.field_accessible == null) {
            return true;
        }

        return self.field_accessible.?
            and (self.resolved_def_type == null
                or self.resolved_def_type.? == .Enum
                or self.resolved_def_type.? == .EnumInstance
                or self.resolved_def_type.? == .ObjectInstance)
            and (self.resolved_type == null
                or self.resolved_type.?.def_type == .Enum
                or self.resolved_type.?.def_type == .EnumInstance
                or self.resolved_type.?.def_type == .ObjectInstance);
    }

    pub fn isSubscriptable(self: *Self) bool {
        if (self.subscriptable == null) {
            return true;
        }

        return self.subscriptable.?
            and (self.resolved_def_type == null
                or self.resolved_def_type.? == .List
                or self.resolved_def_type.? == .Map)
            and (self.resolved_type == null
                or self.resolved_type.?.def_type == .List
                or self.resolved_type.?.def_type == .Map);
    }

    pub fn couldBeList(self: *Self) bool {
        return self.isSubscriptable()
            and (self.resolved_def_type == null or self.resolved_def_type.? == .List)
            and (self.resolved_type == null or self.resolved_type.?.def_type == .List);
    }

    pub fn couldBeMap(self: *Self) bool {
        return self.isSubscriptable()
            and (self.resolved_def_type == null or self.resolved_def_type.? == .Map)
            and (self.resolved_type == null or self.resolved_type.?.def_type == .Map);
    }

    pub fn isCoherent(self: *Self) bool {
        if (self.resolved_def_type != null
            and self.resolved_type != null
            and @as(ObjTypeDef.Type, self.resolved_type.?.def_type) != self.resolved_def_type.?) {
            return false;
        }

        // Nothing can be called and subscrited
        if ((self.callable orelse false) and (self.subscriptable orelse false)) {
            return false;
        }

        // Nothing with fields can be subscrited
        if ((self.field_accessible orelse false) and (self.subscriptable orelse false)) {
            return false;
        }

        // `and` because we checked for compatibility earlier and those function will return true if the flag is null
        return self.isCallable() and self.isSubscriptable() and self.isFieldAccessible() and self.isAssignable();
    }
};