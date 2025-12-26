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

        const format = pcm.readFormat(path, &diagnostics) catch |err| {
            log.err("readFormat: {any}: {s}", .{ err, diagnostics.chunk_id });
            std.process.exit(1);
        };
        log.info("{any}", .{format});

        const audio = pcm.readAll(allocator, path, &diagnostics) catch |err| {
            log.err("readAll: {any}: {s}", .{ err, diagnostics.chunk_id });
            std.process.exit(1);
        };
        log.info("read {d} samples", .{audio.samples.len});

        const dir = if (std.fs.path.dirname(path)) |dir| dir else ".";
        const output_path = try std.fs.path.join(allocator, &.{ dir, "pcm_example.wav" });

        try pcm.writeAll(output_path, audio.format, audio.samples);
        log.info("wrote {d} samples to {s}", .{ audio.samples.len, output_path });
    } else {
        log.err("no audio file provided\n", .{});
        std.process.exit(1);
    }
}
