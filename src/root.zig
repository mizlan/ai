const std = @import("std");
const Io = std.Io;
const mem = std.mem;

fn randomIndex(random: std.Random, slice: anytype) usize {
    return random.uintLessThan(usize, slice.len);
}

const Board = struct {
    const Self = @This();

    cells: [9]i8,

    pub const Status = enum { player1_wins, player2_wins, draw, unfinished };

    pub const empty = Self{ .cells = [9]i8{ 0, 0, 0, 0, 0, 0, 0, 0, 0 } };

    // status makes sense in tic tac toe but may not generalize
    // e.g. we may need status to depend on whose turn it is
    pub fn status(self: *const Self) Status {
        const winning_positions = [8][3]u8{
            [3]u8{ 0, 1, 2 },
            [3]u8{ 3, 4, 5 },
            [3]u8{ 6, 7, 8 },
            [3]u8{ 0, 3, 6 },
            [3]u8{ 1, 4, 7 },
            [3]u8{ 2, 5, 8 },
            [3]u8{ 0, 4, 8 },
            [3]u8{ 2, 4, 6 },
        };
        for (winning_positions) |configuration| {
            const a, const b, const c = configuration;
            if (self.cells[a] != 0 and self.cells[a] == self.cells[b] and self.cells[b] == self.cells[c]) {
                return if (self.cells[a] == 1) .player1_wins else .player2_wins;
            }
        }
        for (self.cells) |elem| {
            if (elem == 0) {
                return .unfinished;
            }
        }
        return .draw;
    }

    fn cellMark(cell: i8) []const u8 {
        return switch (cell) {
            1 => "X",
            2 => "O",
            else => " ",
        };
    }

    pub fn format(self: *const Self, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            \\
            \\===========
            \\ {s} ║ {s} ║ {s}
            \\═══╬═══╬═══
            \\ {s} ║ {s} ║ {s}
            \\═══╬═══╬═══
            \\ {s} ║ {s} ║ {s}
            \\===========
            \\
        , .{
            cellMark(self.cells[0]), cellMark(self.cells[1]), cellMark(self.cells[2]),
            cellMark(self.cells[3]), cellMark(self.cells[4]), cellMark(self.cells[5]),
            cellMark(self.cells[6]), cellMark(self.cells[7]), cellMark(self.cells[8]),
        });
    }

    fn print(self: *const Self) void {
        std.debug.print("{f}", .{self});
    }
};

test "player 1 can win" {
    try std.testing.expectEqual(Board.status(&Board{
        .cells = [9]i8{ 0, 0, 1, 0, 0, 1, 0, 0, 1 },
    }), .player1_wins);
}

test "can be unfinished" {
    try std.testing.expectEqual(Board.status(&Board{
        .cells = [9]i8{ 2, 1, 2, 2, 1, 1, 0, 2, 2 },
    }), .unfinished);
}

const Game = struct {
    const Self = @This();

    board: Board,
    playerToMove: i8,

    pub const initial = Self{
        .board = Board.empty,
        .playerToMove = 1,
    };

    pub const Outcome = enum { win, loss, draw };

    fn nextStates(self: *const Self, allocator: mem.Allocator) error{OutOfMemory}!std.ArrayList(Game) {
        var res = std.ArrayList(Game).empty;
        try res.ensureTotalCapacity(allocator, 9);
        for (self.board.cells, 0..) |elem, i| {
            if (elem == 0) {
                var newState = self.*;
                newState.board.cells[i] = self.playerToMove;
                newState.playerToMove = 3 - newState.playerToMove;
                try res.append(allocator, newState);
            }
        }
        return res;
    }

    fn rollout(
        self: *const Self,
        allocator: mem.Allocator,
        random: std.Random,
    ) error{OutOfMemory}!Game.Outcome {
        var state = self.*;
        while (state.board.status() == .unfinished) {
            var next_states = try state.nextStates(allocator);
            defer next_states.deinit(allocator);

            const moveIdx = randomIndex(random, next_states.items);
            const nextState = next_states.items[moveIdx];
            state = nextState;
        }
        return switch (state.board.status()) {
            .draw => .draw,
            .player1_wins => if (self.playerToMove == 1) .win else .loss,
            .player2_wins => if (self.playerToMove == 2) .win else .loss,
            .unfinished => unreachable,
        };
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
    const allocator = std.testing.allocator;

    var next_states = try Game.initial.nextStates(allocator);
    defer next_states.deinit(allocator);

    try std.testing.expectEqual(next_states.items.len, 9);
}

test "rollout reaches end states" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    var results = [3]u8{ 0, 0, 0 };
    for (1..100) |_| {
        const result = try Game.initial.rollout(allocator, random);
        const idx: usize = switch (result) {
            .draw => 0,
            .win => 1,
            .loss => 2,
        };
        results[idx] += 1;
    }

    try std.testing.expect(results[0] > 0);
    try std.testing.expect(results[1] > 0);
    try std.testing.expect(results[2] > 0);
}

pub const MCTS = struct {
    const Self = @This();

    const Node = struct {
        game: Game,
        parent: ?*Node,
        children: std.ArrayList(*Node) = .empty,
        visitCount: u32 = 0,
        value: i32 = 0,

        pub fn isLeaf(self: *@This()) bool {
            return self.children.items.len == 0;
        }

        fn UCB1(self: *@This()) f64 {
            if (self.visitCount == 0) {
                return std.math.inf(f64);
            }

            const q_value = (self.value / @as(f64, self.visitCount) + 1) / 2;
            const N: f64 = self.parent.?.visitCount;
            return q_value + std.math.sqrt1_2 * std.math.sqrt(@log(N) / self.visitCount);
        }

        pub fn select(self: *@This()) *Node {
            if (self.isLeaf()) {
                return self;
            }

            var bestScore = -std.math.inf(f64);
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

        pub fn expand(self: *@This(), allocator: mem.Allocator) error{OutOfMemory}!void {
            if (self.game.board.status() != .unfinished) {
                return;
            }

            var nextStates = try self.game.nextStates(allocator);
            defer nextStates.deinit(allocator);

            for (nextStates.items) |game| {
                const child = try allocator.create(Node);
                errdefer allocator.destroy(child);

                child.* = .{
                    .game = game,
                    .parent = self,
                };

                try self.children.append(allocator, child);
            }
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

        pub fn backpropagate(self: *@This(), outcome: Game.Outcome) void {
            // each node's value field should be understood from the
            // perspective of the parent node. that is, a higher value
            // means the parent would prefer to enter this node.
            // correspondingly, this means that a higher value means
            // the current player to move actually *dislikes* this
            // state
            const value: i8 = switch (outcome) {
                .draw => 0,
                .win => -1,
                .loss => 1,
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
        };

        return Self{
            .root = root,
        };
    }

    pub fn doRound(self: *Self, allocator: mem.Allocator, random: std.Random) error{OutOfMemory}!void {
        const leaf = self.root.select();
        try leaf.expand(allocator);
        const outcome = try leaf.game.rollout(allocator, random);
        leaf.backpropagate(outcome);
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
        var newRoot: ?*Node = null;

        for (self.root.children.items, 0..) |candidate, i| {
            if (candidate == child) {
                newRoot = self.root.children.orderedRemove(i);
                break;
            }
        } else {
            return false;
        }

        self.root.deinit(allocator);
        self.root = newRoot.?;
        return true;
    }

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        self.root.deinit(allocator);
    }
};
