const std = @import("std");
const pcm = @import("pcm");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |path| {
        std.debug.print("{}\n", .{try pcm.readInfo(path, null)});
        _, const data = try pcm.readAll(allocator, path, null);
        std.debug.print("read {d} samples\n", .{data.len});
    } else {
        std.debug.print("no audio file provided\n", .{});
    }
}
