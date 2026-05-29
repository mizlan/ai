const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const color = @import("color");

const MaxCachedVisits: usize = 1_000_000;
const UcbTableLen = MaxCachedVisits + 1;

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

fn columnMask(comptime column: usize) u64 {
    if (column >= 7) unreachable;

    const bits: u8 = 1 << column;
    return buildBits([6]u8{ bits, bits, bits, bits, bits, bits });
}

fn columnForMove(move: u64) u8 {
    return @ctz(move) % 7;
}

const Bitmasks = struct {
    const byColumn = [7]u64{
        columnMask(0),
        columnMask(1),
        columnMask(2),
        columnMask(3),
        columnMask(4),
        columnMask(5),
        columnMask(6),
    };

    // Records the lowest bit that must be set for a win in the relevant direction
    const Win = struct {
        const horizontalMask = buildBits([6]u8{
            0b0001111,
            0b0001111,
            0b0001111,
            0b0001111,
            0b0001111,
            0b0001111,
        });
        const verticalMask = buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000000,
            0b1111111,
            0b1111111,
            0b1111111,
        });
        const downwardLeftMask = buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000000,
            0b1111000,
            0b1111000,
            0b1111000,
        });
        const downwardRightMask = buildBits([6]u8{
            0b0000000,
            0b0000000,
            0b0000000,
            0b0001111,
            0b0001111,
            0b0001111,
        });
    };
};

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
        const horizontalShift = 1;
        const verticalShift = 7;
        const downwardLeftShift = 6;
        const downwardRightShift = 8;

        return (self.matches4(Bitmasks.Win.horizontalMask, horizontalShift) |
            self.matches4(Bitmasks.Win.verticalMask, verticalShift) |
            self.matches4(Bitmasks.Win.downwardLeftMask, downwardLeftShift) |
            self.matches4(Bitmasks.Win.downwardRightMask, downwardRightShift)) != 0;
    }
};

/// 6x7 grids
const Board = struct {
    const Self = @This();

    playerBoards: [2]PlayerBoard,

    pub const Status = enum { player1_wins, player2_wins, draw, unfinished };

    pub const empty = Self{ .playerBoards = [2]PlayerBoard{ .{ .cells = 0 }, .{ .cells = 0 } } };

    fn cellMark(self: *const Self, row: u6, col: u6, highlightedMove: ?u64) []const u8 {
        const mask = cellBit(row, col);
        if (highlightedMove == mask) {
            if (self.playerBoards[0].cells & mask != 0) return color.onGreen(color.red(" X "));
            if (self.playerBoards[1].cells & mask != 0) return color.onGreen(color.yellow(" O "));
        }
        if (self.playerBoards[0].cells & mask != 0) return color.red(" X ");
        if (self.playerBoards[1].cells & mask != 0) return color.yellow(" O ");
        return "   ";
    }

    pub fn formatHighlighted(self: *const Self, writer: *Io.Writer, highlightedMove: ?u64) Io.Writer.Error!void {
        try writer.writeAll("\n");
        for (0..6) |row| {
            for (0..7) |col| {
                if (col != 0) try writer.writeAll(color.darkGrey("║"));
                try writer.print("{s}", .{self.cellMark(@intCast(row), @intCast(col), highlightedMove)});
            }
            try writer.writeAll("\n");
            if (row != 5) try writer.writeAll(color.darkGrey("═══╬═══╬═══╬═══╬═══╬═══╬═══\n"));
        }
    }

    pub fn format(self: *const Self, writer: *Io.Writer) Io.Writer.Error!void {
        try self.formatHighlighted(writer, null);
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

    const initialPossibleMoves = initial.possibleMoves();
    const initialNumPossibleMoves = @popCount(initialPossibleMoves);

    pub const RolloutOutcome = enum { win, draw, loss };
    pub const Status = enum { playerWhoJustWentWon, draw, unfinished };

    pub fn possibleMoves(self: *const Self) u64 {
        const emptySquares = (self.board.playerBoards[0].cells | self.board.playerBoards[1].cells) ^ ((1 << 42) - 1);
        const availableMoves = (emptySquares ^ (emptySquares << 7)) & ((1 << 42) - 1);
        return availableMoves;
    }

    pub fn moveForColumn(self: *const Self, column: usize) ?u64 {
        if (column >= Bitmasks.byColumn.len) return null;

        const mask = Bitmasks.byColumn[column];
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
    const next_states = Game.initialPossibleMoves;

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

    const UCB = struct {
        const cache_dir = ".zig-cache";
        const cache_path = cache_dir ++ "/connect4-ucb-tables-v1.bin";
        const magic = "C4UCBT1\n";
        const table_count = 3;
        const cache_header_len = magic.len + @sizeOf(u32) + @sizeOf(u32);
        const cache_data_len = table_count * UcbTableLen * @sizeOf(f32);
        const cache_file_len = cache_header_len + cache_data_len;

        values: []f32,

        pub fn init(allocator: mem.Allocator, io: Io) !UCB {
            if (try loadCache(allocator, io)) |values| {
                std.debug.print("using saved cache\n", .{});
                return .{ .values = values };
            }

            std.debug.print("building cache\n", .{});

            const values = try allocator.alloc(f32, table_count * UcbTableLen);
            errdefer allocator.free(values);
            fill(values);
            writeCache(io, values) catch {};
            return .{ .values = values };
        }

        pub fn deinit(self: *UCB, allocator: mem.Allocator) void {
            allocator.free(self.values);
            self.* = undefined;
        }

        fn halfInvTable(self: *const UCB) []const f32 {
            return self.values[0 * UcbTableLen .. 1 * UcbTableLen];
        }

        fn invSqrtTable(self: *const UCB) []const f32 {
            return self.values[1 * UcbTableLen .. 2 * UcbTableLen];
        }

        fn parentConstantTable(self: *const UCB) []const f32 {
            return self.values[2 * UcbTableLen .. 3 * UcbTableLen];
        }

        fn fill(values: []f32) void {
            std.debug.assert(values.len == table_count * UcbTableLen);

            const half_inv_table = values[0 * UcbTableLen .. 1 * UcbTableLen];
            const inv_sqrt_table = values[1 * UcbTableLen .. 2 * UcbTableLen];
            const parent_constant_table = values[2 * UcbTableLen .. 3 * UcbTableLen];

            half_inv_table[0] = 0.0;
            inv_sqrt_table[0] = std.math.inf(f32);
            parent_constant_table[0] = 0.0;
            parent_constant_table[1] = 0.0;

            for (1..UcbTableLen) |i| {
                const x: f32 = @floatFromInt(i);
                half_inv_table[i] = 0.5 / x;
                inv_sqrt_table[i] = 1.0 / @sqrt(x);
                if (i > 1) {
                    parent_constant_table[i] = 1.5 * @sqrt(@log(x));
                }
            }
        }

        fn loadCache(allocator: mem.Allocator, io: Io) !?[]f32 {
            const cwd = Io.Dir.cwd();
            const stat = cwd.statFile(io, cache_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return null,
            };
            if (stat.size != cache_file_len) return null;

            var file = cwd.openFile(io, cache_path, .{}) catch return null;
            defer file.close(io);

            var header: [cache_header_len]u8 = undefined;
            if (try file.readPositionalAll(io, &header, 0) != header.len) return null;
            if (!mem.eql(u8, header[0..magic.len], magic)) return null;

            const cached_table_count = mem.readInt(u32, header[magic.len..][0..4], .little);
            const cached_table_len = mem.readInt(u32, header[magic.len + 4 ..][0..4], .little);
            if (cached_table_count != table_count or cached_table_len != UcbTableLen) return null;

            const values = try allocator.alloc(f32, table_count * UcbTableLen);
            errdefer allocator.free(values);

            const bytes = mem.sliceAsBytes(values);
            if (try file.readPositionalAll(io, bytes, cache_header_len) != bytes.len) {
                allocator.free(values);
                return null;
            }

            return values;
        }

        fn writeCache(io: Io, values: []const f32) !void {
            const cwd = Io.Dir.cwd();
            try cwd.createDirPath(io, cache_dir);

            var file = try cwd.createFile(io, cache_path, .{});
            defer file.close(io);

            var header: [cache_header_len]u8 = undefined;
            @memcpy(header[0..magic.len], magic);
            mem.writeInt(u32, header[magic.len..][0..4], table_count, .little);
            mem.writeInt(u32, header[magic.len + 4 ..][0..4], UcbTableLen, .little);

            try file.writePositionalAll(io, &header, 0);
            try file.writePositionalAll(io, mem.sliceAsBytes(values), cache_header_len);
        }

        pub inline fn halfInv(self: *const UCB, visits: usize) f32 {
            if (visits <= MaxCachedVisits) {
                return self.halfInvTable()[visits];
            }

            const x: f32 = @floatFromInt(visits);
            return 0.5 / x;
        }

        pub inline fn invSqrt(self: *const UCB, visits: usize) f32 {
            if (visits <= MaxCachedVisits) {
                return self.invSqrtTable()[visits];
            }

            const x: f32 = @floatFromInt(visits);
            return 1.0 / @sqrt(x);
        }

        pub inline fn parentConstant(self: *const UCB, visits: usize) f32 {
            if (visits <= MaxCachedVisits) {
                return self.parentConstantTable()[visits];
            }

            if (visits <= 1) return 0.0;

            const x: f32 = @floatFromInt(visits);
            return 1.5 * @sqrt(@log(x));
        }
    };

    const Node = struct {
        game: Game,
        parent: ?*Node,
        children: std.ArrayList(*Node) = .empty,
        visitCount: u32 = 0,
        value: i32 = 0,

        // available tic tac toe moves that haven't been expanded yet
        unexpandedMoves: u64,

        // if the game is fully decided, what is the decisive outcome from this node?
        decided: ?Game.RolloutOutcome = null,
        numUndecidedChildren: u8,

        pub fn isLeaf(self: *@This()) bool {
            return self.unexpandedMoves != 0;
        }

        pub fn slowUCB1(self: *@This()) f32 {
            if (self.visitCount == 0) {
                return std.math.inf(f32);
            }

            const value: f32 = @floatFromInt(self.value);
            const visits: f32 = @floatFromInt(self.visitCount);

            const q_value = (value / visits + 1.0) / 2.0;
            const N: f32 = @floatFromInt(self.parent.?.visitCount);
            return q_value + 1.5 * std.math.sqrt(@log(N) / visits);
        }

        pub fn UCB1(self: *@This(), ucb: *const UCB, constant: f32) f32 {
            const value: f32 = @floatFromInt(self.value);

            // q_value_minus_05 is wins/visits - 0.5; it is simpler to calculate

            const q_value_minus_05 = value * ucb.halfInv(self.visitCount);
            return q_value_minus_05 + constant * ucb.invSqrt(self.visitCount);
        }

        pub fn select(self: *@This(), ucb: *const UCB) *Node {
            var cur = self;
            while (!cur.isLeaf()) {
                if (cur.children.items.len == 0) {
                    return cur;
                }

                const constant: f32 = ucb.parentConstant(cur.visitCount);

                var bestScore = -std.math.inf(f32);
                var bestCandidate = cur.children.items[0];
                for (cur.children.items) |candidate| {
                    const score = candidate.UCB1(ucb, constant);

                    if (score > bestScore) {
                        bestCandidate = candidate;
                        bestScore = score;
                    }
                }
                cur = bestCandidate;
            }
            return cur;
        }

        pub fn expand(self: *@This(), allocator: mem.Allocator, random: std.Random) error{OutOfMemory}!*Node {
            if (self.game.status() != .unfinished) {
                return self;
            }

            const move = randomBit(random, self.unexpandedMoves);

            return self.createChildForMove(allocator, move);
        }

        fn createChildForMove(self: *@This(), allocator: mem.Allocator, move: u64) error{OutOfMemory}!*Node {
            const child = try allocator.create(Node);
            errdefer allocator.destroy(child);

            child.* = .{
                .game = self.game,
                .parent = self,
                .unexpandedMoves = undefined,
                .numUndecidedChildren = undefined,
            };

            std.debug.assert(child.game.makeMoveIfPossible(move));

            if (child.game.status() == .unfinished) {
                child.unexpandedMoves = child.game.possibleMoves();
                child.numUndecidedChildren = @popCount(child.unexpandedMoves);
            } else {
                child.unexpandedMoves = 0;
            }

            self.unexpandedMoves = self.unexpandedMoves & ~move;

            try self.children.append(allocator, child);
            return child;
        }

        fn columnLessThan(context: void, a: *@This(), b: *@This()) bool {
            _ = context;
            return a.columnFromParent().? < b.columnFromParent().?;
        }

        pub fn sortChildren(self: @This()) void {
            std.sort.insertion(*@This(), self.children.items, {}, columnLessThan);
        }

        fn moveFromParent(self: *const @This()) ?u64 {
            const parent = self.parent orelse return null;
            const playerWhoMoved = parent.game.playerToMove;
            const move = self.game.board.playerBoards[playerWhoMoved].cells & ~parent.game.board.playerBoards[playerWhoMoved].cells;
            if (move == 0) return null;
            return move;
        }

        pub fn columnFromParent(self: *const @This()) ?usize {
            const move = self.moveFromParent() orelse return null;
            return columnForMove(move);
        }

        pub fn format(self: *const @This(), writer: *Io.Writer) Io.Writer.Error!void {
            try self.game.board.formatHighlighted(writer, self.moveFromParent());

            const numWins = @divFloor(@as(i64, self.value) + @as(i64, self.visitCount), 2);

            try writer.print("\nvalue: {d}\nvisitCount: {d}", .{
                numWins,
                self.visitCount,
            });
        }

        pub fn print(self: *const @This()) void {
            std.debug.print("{f}\n", .{self});
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            for (self.children.items) |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            }
            self.children.deinit(allocator);
        }

        pub fn backpropagate(self: *@This(), outcome: Game.RolloutOutcome) void {
            // each node's value field should be understood from the
            // perspective of the parent node. that is, a higher value
            // means the parent would prefer to enter this node.
            // correspondingly, this means that a higher value means
            // the current player to move actually *dislikes* this
            // state
            var value: i8 = switch (outcome) {
                .draw => 0,
                .win => 1,
                .loss => -1,
            };

            var cur = self;
            while (true) {
                cur.value += value;
                cur.visitCount += 1;
                value = -value;
                cur = cur.parent orelse return;
            }
        }

        // this call chain starts from the node whose status is already finished
        pub fn recordFullExpansion(self: *@This(), outcome: Game.RolloutOutcome) void {
            _ = outcome;
            if (self.numUndecidedChildren == 0) {}
            // any win (child loss) becomes a win
            // all losses (child wins) (fully expanded) becomes loss
        }
    };

    root: *Node,
    ucb: UCB,

    pub fn init(allocator: mem.Allocator, io: Io) !Self {
        var ucb = try UCB.init(allocator, io);
        errdefer ucb.deinit(allocator);

        const root = try allocator.create(Node);

        root.* = Node{
            .game = Game.initial,
            .parent = null,
            .unexpandedMoves = Game.initialPossibleMoves,
            .numUndecidedChildren = Game.initialNumPossibleMoves,
        };

        return Self{
            .root = root,
            .ucb = ucb,
        };
    }

    pub fn doRound(self: *Self, allocator: mem.Allocator, random: std.Random) error{OutOfMemory}!void {
        const leaf = self.root.select(&self.ucb);
        const child = try leaf.expand(allocator, random);
        const childStatus = child.game.status();
        if (childStatus != .unfinished) {
            child.decided = if (childStatus == .playerWhoJustWentWon) .win else .draw;
        }
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

    pub fn doNRounds(
        self: *Self,
        allocator: mem.Allocator,
        random: std.Random,
        numRounds: usize,
    ) !void {
        for (0..numRounds) |_| {
            try self.doRound(allocator, random);
        }
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
        if (column >= Bitmasks.byColumn.len) return false;

        const move = self.root.game.possibleMoves() & Bitmasks.byColumn[column];

        if (self.root.unexpandedMoves & move != 0) {
            const child = try self.root.createChildForMove(allocator, move);
            return self.commit(child, allocator);
        }

        const newState = self.root.game.board.playerBoards[self.root.game.playerToMove].cells | move;
        for (self.root.children.items) |child| {
            if (child.game.board.playerBoards[self.root.game.playerToMove].cells == newState) {
                return self.commit(child, allocator);
            }
        }
        return false;
    }

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        self.root.deinit(allocator);
        allocator.destroy(self.root);
        self.ucb.deinit(allocator);
    }
};

test "committing a child makes it the parentless root" {
    const allocator = std.testing.allocator; //
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    var mcts = try MCTS.init(allocator, std.testing.io);
    defer mcts.deinit(allocator);

    _ = try mcts.root.expand(allocator, random);
    const child = mcts.root.children.items[0];

    try std.testing.expect(mcts.commit(child, allocator));
    try std.testing.expect(mcts.root.parent == null);
}

test "committing a column advances the root" {
    const allocator = std.testing.allocator;

    var mcts = try MCTS.init(allocator, std.testing.io);
    defer mcts.deinit(allocator);

    try std.testing.expect(try mcts.commitColumn(2, allocator));
    try std.testing.expectEqual(@as(u1, 1), mcts.root.game.playerToMove);
    try std.testing.expect(mcts.root.game.board.playerBoards[0].cells & cellBit(5, 2) != 0);
    try std.testing.expect(mcts.root.parent == null);
}

test "node formatting highlights only non-root moves" {
    const allocator = std.testing.allocator;

    var child_mcts = try MCTS.init(allocator, std.testing.io);
    defer child_mcts.deinit(allocator);

    const child = try child_mcts.root.createChildForMove(allocator, cellBit(5, 3));

    var child_buffer: [2048]u8 = undefined;
    var child_writer: Io.Writer = .fixed(&child_buffer);
    try child_writer.print("{f}", .{child});

    try std.testing.expect(mem.indexOf(u8, child_writer.buffered(), color.onGreen(color.red(" X "))) != null);
    try std.testing.expect(mem.indexOf(u8, child_writer.buffered(), "value: 0") != null);
    try std.testing.expect(mem.indexOf(u8, child_writer.buffered(), "visitCount: 0") != null);

    var root_mcts = try MCTS.init(allocator, std.testing.io);
    defer root_mcts.deinit(allocator);
    try std.testing.expect(try root_mcts.commitColumn(3, allocator));

    var root_buffer: [2048]u8 = undefined;
    var root_writer: Io.Writer = .fixed(&root_buffer);
    try root_writer.print("{f}", .{root_mcts.root});

    try std.testing.expect(mem.indexOf(u8, root_writer.buffered(), color.onGreen(color.red(" X "))) == null);
}
