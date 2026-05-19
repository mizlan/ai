const std = @import("std");
const Io = std.Io;

const c4 = @import("connect4");

const CliError = error{ InvalidColumn, GameAlreadyOver };

fn parseColumn(arg: []const u8) !usize {
    const column = try std.fmt.parseInt(usize, arg, 10);
    if (column >= 7) return CliError.InvalidColumn;
    return column;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const io = init.io;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    var mcts = try c4.MCTS.init(arena);

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
            const numRounds = try mcts.doRoundsForDuration(arena, random, io, .fromMilliseconds(100));
            const child = mcts.bestChild() orelse return CliError.GameAlreadyOver;
            const column = child.columnFromParent() orelse return CliError.GameAlreadyOver;

            _ = mcts.commit(child, arena);
            try stdout_writer.print("computer move {d} after {d} rounds\n{f}\n", .{
                column,
                numRounds,
                mcts.root.game.board,
            });
        } else {
            const column = parseColumn(line) catch {
                try stdout_writer.writeAll("enter a column from 0 through 6, or leave blank for the computer\n");
                continue;
            };

            if (!try mcts.commitColumn(column, arena)) {
                try stdout_writer.print("column {d} is not playable\n", .{column});
                continue;
            }

            try stdout_writer.print("manual move {d}{f}\n", .{
                column,
                mcts.root.game.board,
            });
        }
    }

    try stdout_writer.flush(); // Don't forget to flush!
}
