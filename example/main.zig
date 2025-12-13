const std = @import("std");
const pcm = @import("pcm");

const log = std.log.scoped(.example);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |path| {
        var diagnostics: pcm.Diagnostics = undefined;

        const info = pcm.readInfo(path, &diagnostics) catch |err| {
            log.err("readInfo: {any}: {s}", .{ err, diagnostics.chunk_id });
            std.process.exit(1);
        };
        log.info("{any}", .{info});

        _, const data = pcm.readAll(allocator, path, &diagnostics) catch |err| {
            log.err("readAll: {any}: {s}", .{ err, diagnostics.chunk_id });
            std.process.exit(1);
        };
        log.info("read {d} frames", .{data.len});
    } else {
        log.err("no audio file provided\n", .{});
        std.process.exit(1);
    }
}
