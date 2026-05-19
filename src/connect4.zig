const std = @import("std");
const Io = std.Io;
const mem = std.mem;

fn buildBits(comptime bits: [6]u8) u64 {
    return (@as(u64, bits[0]) << @as(u6, 35)) |
        (@as(u64, bits[1]) << @as(u6, 28)) |
        (@as(u64, bits[2]) << @as(u6, 21)) |
        (@as(u64, bits[3]) << @as(u6, 14)) |
        (@as(u64, bits[4]) << @as(u6, 7)) |
        @as(u64, bits[5]);
}

fn randomBit(random: std.Random, mask: u64) u64 {
    var n = random.uintLessThan(u32, @popCount(mask));
    var m = mask;

    while (n > 0) : (n -= 1)
        m &= m - 1;

    return m & (~m + 1);
}

fn cellBit(row: u6, col: u6) u64 {
    return @as(u64, 1) << ((5 - row) * 7 + col);
}

fn columnMask(column: usize) ?u64 {
    if (column >= 7) return null;

    var mask: u64 = 0;
    for (0..6) |row| {
        mask |= cellBit(@intCast(row), @intCast(column));
    }
    return mask;
}

fn columnForMove(move: u64) ?usize {
    if (@popCount(move) != 1) return null;

    for (0..7) |column| {
        if (move & columnMask(column).? != 0) return column;
    }
    return null;
}

const PlayerBoard = struct {
    const Self = @This();

    cells: u64,

    fn matches4(self: *const Self, comptime mask: u64, comptime shift: u8) u64 {
        const validStarts = self.cells & mask;
        return (validStarts &
            (self.cells >> shift) &
            (self.cells >> (2 * shift)) &
            (self.cells >> (3 * shift)));
    }

    pub fn hasWin(self: *const Self) bool {
        const horizontalMask = comptime buildBits([6]u8{
            0b0001111,
            0b0001111,
            0b0001111,
            0b0001111,
            0b0001111,
            0b0001111,
        });
        const verticalMask = comptime buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000000,
            0b1111111,
            0b1111111,
            0b1111111,
        });
        const downwardLeftMask = comptime buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000000,
            0b1111000,
            0b1111000,
            0b1111000,
        });
        const downwardRightMask = comptime buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000000,
            0b0001111,
            0b0001111,
            0b0001111,
        });

        const horizontalShift = 1;
        const verticalShift = 7;
        const downwardLeftShift = 6;
        const downwardRightShift = 8;

        return (self.matches4(horizontalMask, horizontalShift) |
            self.matches4(verticalMask, verticalShift) |
            self.matches4(downwardLeftMask, downwardLeftShift) |
            self.matches4(downwardRightMask, downwardRightShift)) != 0;
    }
};

/// 6x7 grids
const Board = struct {
    const Self = @This();

    playerBoards: [2]PlayerBoard,

    pub const Status = enum { player1_wins, player2_wins, draw, unfinished };

    pub const empty = Self{ .playerBoards = [2]PlayerBoard{ .{ .cells = 0 }, .{ .cells = 0 } } };

    fn cellMark(self: *const Self, row: u6, col: u6) []const u8 {
        const mask = cellBit(row, col);
        if (self.playerBoards[0].cells & mask != 0) return "X";
        if (self.playerBoards[1].cells & mask != 0) return "O";
        return " ";
    }

    pub fn format(self: *const Self, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("\n");
        for (0..6) |row| {
            for (0..7) |col| {
                if (col != 0) try writer.writeAll(" ║");
                try writer.print(" {s}", .{self.cellMark(@intCast(row), @intCast(col))});
            }
            try writer.writeAll("\n");
            if (row != 5) try writer.writeAll("═══╬═══╬═══╬═══╬═══╬═══╬═══\n");
        }
    }

    fn print(self: *const Self) void {
        std.debug.print("{f}", .{self});
    }
};

const Game = struct {
    const Self = @This();

    board: Board,
    playerToMove: u1,

    pub const initial = Self{
        .board = Board.empty,
        .playerToMove = 0,
    };

    pub const RolloutOutcome = enum { win, draw, loss };
    pub const Status = enum { playerWhoJustWentWon, draw, unfinished };

    pub fn possibleMoves(self: *const Self) u64 {
        const emptySquares = (self.board.playerBoards[0].cells | self.board.playerBoards[1].cells) ^ ((1 << 42) - 1);
        const availableMoves = (emptySquares ^ (emptySquares << 7)) & ((1 << 42) - 1);
        return availableMoves;
    }

    pub fn moveForColumn(self: *const Self, column: usize) ?u64 {
        const mask = columnMask(column) orelse return null;
        const move = self.possibleMoves() & mask;
        return if (move == 0) null else move;
    }

    fn playerWhoJustWentWon(self: *const Self) bool {
        const playerWhoJustWent = 1 ^ self.playerToMove;
        const board = self.board.playerBoards[playerWhoJustWent];
        return board.hasWin();
    }

    pub fn status(self: *const Self) Status {
        if (self.playerWhoJustWentWon()) {
            return .playerWhoJustWentWon;
        } else if (self.possibleMoves() == 0) {
            return .draw;
        } else {
            return .unfinished;
        }
    }

    fn makeRandomMoveIfPossible(self: *Self, random: std.Random, moveOptions: u64) ?u64 {
        if (moveOptions == 0) {
            return null;
        }

        const move = randomBit(random, moveOptions);

        self.board.playerBoards[self.playerToMove].cells |= move;
        self.playerToMove = 1 ^ self.playerToMove;

        return move;
    }

    fn makeMoveIfPossible(self: *Self, move: u64) bool {
        if (@popCount(move) != 1 or move & self.possibleMoves() != move) return false;

        self.board.playerBoards[self.playerToMove].cells |= move;
        self.playerToMove = 1 ^ self.playerToMove;
        return true;
    }

    fn rollout(
        self: *const Self,
        random: std.Random,
    ) error{OutOfMemory}!Game.RolloutOutcome {
        var state = self.*;

        while (!state.playerWhoJustWentWon()) {
            const move = state.makeRandomMoveIfPossible(random, state.possibleMoves());
            if (move == null) {
                return .draw;
            }
        }

        const playerWhoEndedGame = 1 ^ state.playerToMove;
        const playerWhoJustWentAtLeaf = 1 ^ self.playerToMove;
        return if (playerWhoEndedGame == playerWhoJustWentAtLeaf) .win else .loss;
    }

    pub fn format(self: *const Self, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("current turn: player {d}\n{f}", .{
            self.playerToMove,
            &self.board,
        });
    }

    fn print(self: *const Self) void {
        std.debug.print("{f}", .{self});
    }
};

test "next states of starting game" {
    const next_states = Game.initial.possibleMoves();

    try std.testing.expectEqual(next_states, buildBits([6]u8{
        0b0000000,
        0b0000000,
        0b0000000,
        0b0000000,
        0b0000000,
        0b1111111,
    }));
}

test "moves stack above occupied squares" {
    var game = Game.initial;

    game.board.playerBoards[0].cells |= @as(u64, 1) << 0;

    try std.testing.expectEqual(game.possibleMoves(), buildBits([6]u8{
        0b0000000,
        0b0000000,
        0b0000000,
        0b0000000,
        0b0000001,
        0b1111110,
    }));
}

test "detects wins in every direction" {
    const boards = [_]PlayerBoard{
        .{ .cells = buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000000,
            0b0000000,
            0b0000000,
            0b0001111,
        }) },
        .{ .cells = buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000001,
            0b0000001,
            0b0000001,
            0b0000001,
        }) },
        .{ .cells = buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000001,
            0b0000010,
            0b0000100,
            0b0001000,
        }) },
        .{ .cells = buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0001000,
            0b0000100,
            0b0000010,
            0b0000001,
        }) },
    };

    for (boards) |board| {
        try std.testing.expect(board.hasWin());
    }
}

pub const MCTS = struct {
    const Self = @This();

    const Node = struct {
        game: Game,
        parent: ?*Node,
        children: std.ArrayList(*Node) = .empty,
        visitCount: u32 = 0,
        value: i32 = 0,

        // tic tac toe specific
        remainingMoveOptions: u64,

        pub fn isLeaf(self: *@This()) bool {
            return self.remainingMoveOptions != 0;
        }

        fn UCB1(self: *@This()) f32 {
            if (self.visitCount == 0) {
                return std.math.inf(f32);
            }

            const value: f32 = @floatFromInt(self.value);
            const visits: f32 = @floatFromInt(self.visitCount);

            const q_value = (value / visits + 1.0) / 2.0;
            const N: f32 = @floatFromInt(self.parent.?.visitCount);
            return q_value + std.math.sqrt1_2 * std.math.sqrt(@log(N) / visits);
        }

        pub fn select(self: *@This()) *Node {
            if (self.isLeaf()) {
                return self;
            }

            if (self.children.items.len == 0) {
                return self;
            }

            var bestScore = -std.math.inf(f32);
            var bestCandidate = self.children.items[0];
            for (self.children.items) |candidate| {
                const score = candidate.UCB1();
                if (score > bestScore) {
                    bestCandidate = candidate;
                    bestScore = score;
                }
            }
            return bestCandidate.select();
        }

        pub fn expand(self: *@This(), allocator: mem.Allocator, random: std.Random) error{OutOfMemory}!*Node {
            if (self.game.status() != .unfinished) {
                return self;
            }

            const child = try allocator.create(Node);
            errdefer allocator.destroy(child);

            child.* = .{
                .game = self.game,
                .parent = self,
                .remainingMoveOptions = undefined,
            };

            // will not be draw, since we have checked game status
            // TODO: check this
            const move = child.game.makeRandomMoveIfPossible(random, self.remainingMoveOptions).?;
            child.remainingMoveOptions = child.game.possibleMoves();
            self.remainingMoveOptions = self.remainingMoveOptions & ~move;

            try self.children.append(allocator, child);

            return child;
        }

        fn createChildForMove(self: *@This(), allocator: mem.Allocator, move: u64) error{OutOfMemory}!*Node {
            const child = try allocator.create(Node);
            errdefer allocator.destroy(child);

            child.* = .{
                .game = self.game,
                .parent = self,
                .remainingMoveOptions = undefined,
            };

            std.debug.assert(child.game.makeMoveIfPossible(move));
            child.remainingMoveOptions = child.game.possibleMoves();
            // FIXME: pretty sure we need to change self.remainingMoveOptions as well

            try self.children.append(allocator, child);
            return child;
        }

        pub fn expandAllPossibleMoves(self: *@This(), allocator: mem.Allocator) error{OutOfMemory}!void {
            if (self.game.status() != .unfinished) {
                return;
            }

            while (self.remainingMoveOptions != 0) {
                const move = self.remainingMoveOptions & (~self.remainingMoveOptions + 1);
                _ = try self.createChildForMove(allocator, move);
                self.remainingMoveOptions &= ~move;
            }
        }

        pub fn childForColumn(self: *@This(), column: usize) ?*Node {
            const move = self.game.moveForColumn(column) orelse return null;
            const playerWhoMoves = self.game.playerToMove;

            for (self.children.items) |child| {
                const childMove = child.game.board.playerBoards[playerWhoMoves].cells & ~self.game.board.playerBoards[playerWhoMoves].cells;
                if (childMove == move) {
                    return child;
                }
            }

            return null;
        }

        // FIXME: seems like this function is only used for test. should we delete?
        pub fn columnFromParent(self: *@This()) ?usize {
            const parent = self.parent orelse return null;
            const playerWhoMoved = parent.game.playerToMove;
            const move = self.game.board.playerBoards[playerWhoMoved].cells & ~parent.game.board.playerBoards[playerWhoMoved].cells;
            return columnForMove(move);
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            for (self.children.items) |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            }
            self.children.deinit(allocator);
        }

        fn backpropagateValue(self: *@This(), value: i8) void {
            self.value += value;
            self.visitCount += 1;

            if (self.parent) |p| {
                p.backpropagateValue(-value);
            }
        }

        pub fn backpropagate(self: *@This(), outcome: Game.RolloutOutcome) void {
            // each node's value field should be understood from the
            // perspective of the parent node. that is, a higher value
            // means the parent would prefer to enter this node.
            // correspondingly, this means that a higher value means
            // the current player to move actually *dislikes* this
            // state
            const value: i8 = switch (outcome) {
                .draw => 0,
                .win => 1,
                .loss => -1,
            };

            self.backpropagateValue(value);
        }
    };

    root: *Node,

    pub fn init(allocator: mem.Allocator) !Self {
        const root = try allocator.create(Node);

        root.* = Node{
            .game = Game.initial,
            .parent = null,
            .remainingMoveOptions = Game.initial.possibleMoves(),
        };

        return Self{
            .root = root,
        };
    }

    pub fn doRound(self: *Self, allocator: mem.Allocator, random: std.Random) error{OutOfMemory}!void {
        const leaf = self.root.select();
        const child = try leaf.expand(allocator, random);
        const outcome = try child.game.rollout(random);
        child.backpropagate(outcome);
    }

    pub fn doRoundsForDuration(
        self: *Self,
        allocator: mem.Allocator,
        random: std.Random,
        io: Io,
        duration: Io.Duration,
    ) !i32 {
        const start = Io.Clock.awake.now(io);
        var numRounds: i32 = 0;
        while (start.untilNow(io, .awake).nanoseconds < duration.nanoseconds) {
            try self.doRound(allocator, random);
            numRounds += 1;
        }
        return numRounds;
    }

    pub fn bestChild(self: *Self) ?*Node {
        if (self.root.children.items.len == 0) {
            return null;
        }

        var best = self.root.children.items[0];

        for (self.root.children.items) |child| {
            if (child.visitCount > best.visitCount) {
                best = child;
            }
        }

        return best;
    }

    pub fn commit(self: *Self, child: *Node, allocator: mem.Allocator) bool {
        const oldRoot = self.root;
        var newRoot: *Node = undefined;

        for (oldRoot.children.items, 0..) |candidate, i| {
            if (candidate == child) {
                newRoot = oldRoot.children.orderedRemove(i);
                break;
            }
        } else {
            return false;
        }

        oldRoot.deinit(allocator);
        allocator.destroy(oldRoot);
        self.root = newRoot;
        self.root.parent = null;
        return true;
    }

    pub fn commitColumn(self: *Self, column: usize, allocator: mem.Allocator) error{OutOfMemory}!bool {
        try self.root.expandAllPossibleMoves(allocator);
        const child = self.root.childForColumn(column) orelse return false;
        return self.commit(child, allocator);
    }

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        self.root.deinit(allocator);
        allocator.destroy(self.root);
    }
};

test "committing a child makes it the parentless root" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    var mcts = try MCTS.init(allocator);
    defer mcts.deinit(allocator);

    _ = try mcts.root.expand(allocator, random);
    const child = mcts.root.children.items[0];

    try std.testing.expect(mcts.commit(child, allocator));
    try std.testing.expect(mcts.root.parent == null);
}

test "can expand all root moves and find a child by column" {
    const allocator = std.testing.allocator;

    var mcts = try MCTS.init(allocator);
    defer mcts.deinit(allocator);

    try mcts.root.expandAllPossibleMoves(allocator);

    try std.testing.expectEqual(@as(usize, 7), mcts.root.children.items.len);
    try std.testing.expect(mcts.root.childForColumn(3) != null);
    try std.testing.expectEqual(@as(?usize, 3), mcts.root.childForColumn(3).?.columnFromParent());
    try std.testing.expect(mcts.root.childForColumn(7) == null);
}

test "committing a column advances the root" {
    const allocator = std.testing.allocator;

    var mcts = try MCTS.init(allocator);
    defer mcts.deinit(allocator);

    try std.testing.expect(try mcts.commitColumn(2, allocator));
    try std.testing.expectEqual(@as(u1, 1), mcts.root.game.playerToMove);
    try std.testing.expect(mcts.root.game.board.playerBoards[0].cells & cellBit(5, 2) != 0);
    try std.testing.expect(mcts.root.parent == null);
}
