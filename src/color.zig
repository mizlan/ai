const std = @import("std");
const Io = std.Io;

pub const reset = "\x1b[0m";

pub const Color = enum {
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    dark_gray,
};

pub const RuntimeText = struct {
    color: Color,
    text: []const u8,

    pub fn format(self: RuntimeText, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(runtimeCode(self.color));
        writer.writeAll(self.text) catch |write_err| {
            writer.writeAll(reset) catch {};
            return write_err;
        };
        try writer.writeAll(reset);
    }
};

pub fn red(comptime value: []const u8) []const u8 {
    return fmt(.red, value);
}

pub fn green(comptime value: []const u8) []const u8 {
    return fmt(.green, value);
}

pub fn onGreen(comptime value: []const u8) []const u8 {
    return "\x1b[48;5;22m" ++ value ++ reset;
}

pub fn yellow(comptime value: []const u8) []const u8 {
    return fmt(.yellow, value);
}

pub fn blue(comptime value: []const u8) []const u8 {
    return fmt(.blue, value);
}

pub fn magenta(comptime value: []const u8) []const u8 {
    return fmt(.magenta, value);
}

pub fn cyan(comptime value: []const u8) []const u8 {
    return fmt(.cyan, value);
}

pub fn darkGray(comptime value: []const u8) []const u8 {
    return fmt(.dark_gray, value);
}

pub fn darkGrey(comptime value: []const u8) []const u8 {
    return darkGray(value);
}

pub fn fmt(comptime color: Color, comptime value: []const u8) []const u8 {
    return switch (color) {
        .red => "\x1b[31m" ++ value ++ reset,
        .green => "\x1b[32m" ++ value ++ reset,
        .yellow => "\x1b[33m" ++ value ++ reset,
        .blue => "\x1b[34m" ++ value ++ reset,
        .magenta => "\x1b[35m" ++ value ++ reset,
        .cyan => "\x1b[36m" ++ value ++ reset,
        .dark_gray => "\x1b[90m" ++ value ++ reset,
    };
}

pub fn runtime(comptime color: Color, value: []const u8) RuntimeText {
    return .{
        .color = color,
        .text = value,
    };
}

fn code(comptime color: Color) []const u8 {
    return switch (color) {
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .dark_gray => "\x1b[90m",
    };
}

fn runtimeCode(color: Color) []const u8 {
    return switch (color) {
        inline else => |comptime_color| code(comptime_color),
    };
}

test "colors text when formatted" {
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    try writer.print("{s}", .{green("ok")});

    try std.testing.expectEqualStrings("\x1b[32mok\x1b[0m", writer.buffered());
}

test "colors text dark gray" {
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    try writer.print("{s}", .{darkGray("dim")});

    try std.testing.expectEqualStrings("\x1b[90mdim\x1b[0m", writer.buffered());
}

test "colors runtime text" {
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    const value = "careful";
    try writer.print("{f}", .{runtime(.yellow, value)});

    try std.testing.expectEqualStrings("\x1b[33mcareful\x1b[0m", writer.buffered());
}
