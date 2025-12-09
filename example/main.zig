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
        log.info("{}", .{try pcm.readInfo(path, null)});
        _, const data = try pcm.readAll(allocator, path, null);
        log.info("read {d} samples", .{data.len});
    } else {
        log.err("no audio file provided\n", .{});
        std.process.exit(1);
    }
}
