const std = @import("std");
const pcm = @import("pcm");

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |path| {
        std.debug.print("file info: {}", .{try pcm.readInfo(path, null)});
    } else {
        std.debug.print("no audio file provided", .{});
    }
}
