const std = @import("std");
const Io = std.Io;

const c4 = @import("connect4");
const color = @import("color");

const CliError = error{ InvalidColumn, GameAlreadyOver };
const progress_bar_width = 40;
const block_eighths = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };
const progress_foreground = "\x1b[32m";
const progress_background = "\x1b[48;5;240m";
const progress_background_foreground = "\x1b[38;5;240m";

fn parseColumn(arg: []const u8) !usize {
    const column = try std.fmt.parseInt(usize, arg, 10);
    if (column >= 7) return CliError.InvalidColumn;
    return column;
}

fn scaledEighths(value: u64, max: u64, comptime width: usize) u64 {
    if (max == 0) return 0;

    const bar_eighths = width * 8;
    return @min(bar_eighths, @divFloor(value * bar_eighths + max / 2, max));
}

fn ratioEighths(numerator: u64, denominator: u64, scaled_denominator: u64) u64 {
    if (denominator == 0) return 0;
    return @min(scaled_denominator, @divFloor(numerator * scaled_denominator + denominator / 2, denominator));
}

fn cellEighths(scaled_value: u64, cell_start: u64) usize {
    if (scaled_value <= cell_start) return 0;
    return @intCast(@min(8, scaled_value - cell_start));
}

fn writeProgressBar(
    writer: *Io.Writer,
    numerator: u64,
    denominator: u64,
    max: u64,
    comptime width: usize,
) Io.Writer.Error!void {
    const denominator_eighths = scaledEighths(@max(numerator, denominator), max, width);
    const numerator_eighths = ratioEighths(numerator, denominator, denominator_eighths);

    try writer.writeAll("│");
    for (0..width) |i| {
        const cell_start = @as(u64, @intCast(i)) * 8;
        const numerator_fill = cellEighths(numerator_eighths, cell_start);
        const denominator_fill = cellEighths(denominator_eighths, cell_start);

        if (denominator_fill == 8) {
            try writer.writeAll(progress_background);
            if (numerator_fill > 0) {
                try writer.writeAll(progress_foreground);
                try writer.writeAll(block_eighths[numerator_fill]);
            } else {
                try writer.writeByte(' ');
            }
            try writer.writeAll(color.reset);
        } else if (numerator_fill > 0) {
            if (denominator_fill > numerator_fill) {
                try writer.writeAll(progress_background);
                try writer.writeAll(progress_foreground);
                try writer.writeAll(block_eighths[numerator_fill]);
                try writer.writeAll(color.reset);
            } else {
                try writer.writeAll(progress_foreground);
                try writer.writeAll(block_eighths[numerator_fill]);
                try writer.writeAll(color.reset);
            }
        } else if (denominator_fill > 0) {
            try writer.writeAll(progress_background_foreground);
            try writer.writeAll(block_eighths[denominator_fill]);
            try writer.writeAll(color.reset);
        } else {
            try writer.writeByte(' ');
        }
    }
    try writer.writeAll("│");
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const duration = blk: {
        if (args.len == 1) {
            break :blk 1000;
        } else {
            const res = try std.fmt.parseInt(u32, args[1], 10);
            break :blk res;
        }
    };

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var mcts = try c4.MCTS.init(arena, io);

    try stdout_writer.print("{f}\n", .{mcts.root.game.board});

    var inputEnded = false;
    while (mcts.root.game.status() == .unfinished) {
        try stdout_writer.writeAll("column 0-6, or enter for computer move: ");
        try stdout_writer.flush();

        const raw_line = try stdin_reader.takeDelimiter('\n') orelse {
            inputEnded = true;
            break;
        };
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) {
            const numRounds = try mcts.doRoundsForDuration(arena, random, io, .fromMilliseconds(duration));
            // _ = duration;
            // try mcts.doNRounds(arena, random, 200);
            const child = mcts.bestChild() orelse return CliError.GameAlreadyOver;
            // const numRounds = 7;
            // _ = numRounds;
            const column = child.columnFromParent() orelse return CliError.GameAlreadyOver;

            try stdout_writer.print("computer moves [{d}] after {d} rounds of MCTS\n{f}\n", .{
                column,
                numRounds,
                child,
            });
            var max_visit_count: u64 = 0;
            for (mcts.root.children.items) |c| {
                max_visit_count = @max(max_visit_count, c.visitCount);
            }

            mcts.root.sortChildren();
            for (mcts.root.children.items) |c| {
                const num_wins: u64 = @intCast(@divFloor((@as(i64, c.value) + @as(i64, c.visitCount)), 2));

                try stdout_writer.print("> [{d}] ", .{
                    c.columnFromParent().?,
                });
                try writeProgressBar(stdout_writer, num_wins, c.visitCount, max_visit_count, progress_bar_width);
                try stdout_writer.print(" {d}/{d} (ucb1 = {d} = {d})\n", .{
                    num_wins,
                    c.visitCount,
                    c.UCB1(&mcts.ucb, mcts.ucb.parentConstant(mcts.root.visitCount)) + 0.5,
                    c.slowUCB1(),
                });
            }
            try stdout_writer.flush();

            _ = mcts.commit(child, arena);
        } else {
            const column = parseColumn(line) catch {
                try stdout_writer.writeAll("enter a column from 0 through 6, or leave blank for the computer\n");
                continue;
            };

            var max_visit_count: u64 = 0;
            for (mcts.root.children.items) |c| {
                max_visit_count = @max(max_visit_count, c.visitCount);
            }

            mcts.root.sortChildren();
            for (mcts.root.children.items) |c| {
                const num_wins: u64 = @intCast(@divFloor((@as(i64, c.value) + @as(i64, c.visitCount)), 2));

                try stdout_writer.print("> [{d}] ", .{
                    c.columnFromParent().?,
                });
                try writeProgressBar(stdout_writer, num_wins, c.visitCount, max_visit_count, progress_bar_width);
                try stdout_writer.print(" {d}/{d} (ucb1 = {d} = {d})\n", .{
                    num_wins,
                    c.visitCount,
                    c.UCB1(&mcts.ucb, mcts.ucb.parentConstant(mcts.root.visitCount)) + 0.5,
                    c.slowUCB1(),
                });
            }
            try stdout_writer.flush();

            if (!try mcts.commitColumn(column, arena)) {
                try stdout_writer.print("column {d} is not playable\n", .{column});
                continue;
            }

            try stdout_writer.print("manual move {d}\n{f}\n", .{
                column,
                mcts.root,
            });
        }
    }

    // try stdout_writer.flush(); // Don't forget to flush!
}
