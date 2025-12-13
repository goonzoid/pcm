const std = @import("std");
const pcm = @import("pcm");

const log = std.log.scoped(.example);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var err_buf: [4]u8 = undefined;
    var errors = Errors.init(&err_buf);

    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |path| {
        const info = pcm.readInfo(path, &errors.writer) catch |err| {
            // TODO: we probably shouldn't call flush in pcm.zig - call it when you want to access the error info?
            log.err("readInfo: {any}: {s}", .{ err, errors.last_err_data });
            std.process.exit(1);
        };
        log.info("pcm format info: {any}", .{info});

        _, const data = pcm.readAll(allocator, path, &errors.writer) catch |err| {
            log.err("readAll: {any}: {s}", .{ err, errors.last_err_data });
            std.process.exit(1);
        };
        log.info("read {d} frames", .{data.len});
    } else {
        log.err("no audio file provided\n", .{});
        std.process.exit(1);
    }
}

const Errors = struct {
    writer: std.io.Writer,
    last_err_data: [4]u8,

    pub fn init(buffer: []u8) Errors {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = Errors.drain,
                    .flush = Errors.flush,
                },
                .buffer = buffer,
            },
            .last_err_data = undefined,
        };
    }

    pub fn drain(w: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        w.end = 0;
        return 0;
    }

    pub fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const errors: *Errors = @alignCast(@fieldParentPtr("writer", w));
        @memcpy(errors.last_err_data[0..4], w.buffer[w.end - 4 .. 4]);
    }
};
