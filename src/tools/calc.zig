const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

pub const CalcError = error{ InvalidExpression, DivisionByZero };

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn peek(p: *Parser) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn expr(p: *Parser) CalcError!f64 {
        var v = try p.term();
        while (true) {
            p.ws();
            const c = p.peek();
            if (c == '+') {
                p.i += 1;
                v += try p.term();
            } else if (c == '-') {
                p.i += 1;
                v -= try p.term();
            } else break;
        }
        return v;
    }

    fn term(p: *Parser) CalcError!f64 {
        var v = try p.factor();
        while (true) {
            p.ws();
            const c = p.peek();
            if (c == '*') {
                p.i += 1;
                v *= try p.factor();
            } else if (c == '/') {
                p.i += 1;
                const d = try p.factor();
                if (d == 0) return error.DivisionByZero;
                v /= d;
            } else break;
        }
        return v;
    }

    fn factor(p: *Parser) CalcError!f64 {
        p.ws();
        const c = p.peek();
        if (c == '-') {
            p.i += 1;
            return -try p.factor();
        }
        if (c == '+') {
            p.i += 1;
            return p.factor();
        }
        if (c == '(') {
            p.i += 1;
            const v = try p.expr();
            p.ws();
            if (p.peek() != ')') return error.InvalidExpression;
            p.i += 1;
            return v;
        }
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or p.s[p.i] == '.')) p.i += 1;
        if (p.i == start) return error.InvalidExpression;
        return std.fmt.parseFloat(f64, p.s[start..p.i]) catch error.InvalidExpression;
    }
};

/// Evaluate a single arithmetic expression: numbers, + - * / ( ) and unary +/-.
/// Returns the result formatted without a trailing ".0" for integer values.
pub fn evalExpression(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var p = Parser{ .s = text };
    const v = try p.expr();
    p.ws();
    if (p.i != p.s.len) return error.InvalidExpression;
    if (v == @floor(v) and @abs(v) < 1e15) {
        return std.fmt.allocPrint(gpa, "{d}", .{@as(i64, @intFromFloat(v))});
    }
    return std.fmt.allocPrint(gpa, "{d}", .{v});
}

/// Tool entry point: args[0] is the expression. No subprocess, no shell.
pub fn execCalc(gpa: std.mem.Allocator, expression: []const u8) error{OutOfMemory}!ToolResult {
    const out = evalExpression(gpa, expression) catch |err| {
        return ToolResult{
            .success = false,
            .stdout = "",
            .stderr = switch (err) {
                error.DivisionByZero => "division by zero",
                else => "invalid expression",
            },
            .exit_code = 2,
        };
    };
    return ToolResult{ .success = true, .stdout = out, .stderr = "", .exit_code = 0 };
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "evalExpression: integer arithmetic prints without decimal point" {
    const gpa = std.testing.allocator;
    const r = try evalExpression(gpa, "2 + 3 * 4");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("14", r);
}

test "evalExpression: parentheses and unary minus" {
    const gpa = std.testing.allocator;
    const r = try evalExpression(gpa, "-(2 + 3) * 4");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("-20", r);
}

test "evalExpression: float result keeps decimals" {
    const gpa = std.testing.allocator;
    const r = try evalExpression(gpa, "7 / 2");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("3.5", r);
}

test "evalExpression: trailing garbage is rejected" {
    try std.testing.expectError(error.InvalidExpression, evalExpression(std.testing.allocator, "2 + 3 x"));
}

test "evalExpression: division by zero" {
    try std.testing.expectError(error.DivisionByZero, evalExpression(std.testing.allocator, "1/0"));
}

test "execCalc: wraps errors into failed ToolResult" {
    const gpa = std.testing.allocator;
    const r = try execCalc(gpa, "hello");
    try std.testing.expect(!r.success);
    try std.testing.expectEqualStrings("invalid expression", r.stderr);
}
