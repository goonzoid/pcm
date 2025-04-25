const std = @import("std");
const builtin = @import("builtin");

const target_endianness = builtin.cpu.arch.endian();
comptime {
    // we handle endianness correctly in some places, but not everywhere. it's safest to just stick
    // to little endian systems for now until we have time to test on a big endian machine
    std.debug.assert(target_endianness == .little);
}

const pcm_log = std.log.scoped(.pcm);

pub const PCMInfo = struct {
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,
};

const PCMAll = struct { PCMInfo, []f32 };

pub const max_err_info_size = 4;
const PCMReadError = error{
    ShortRead,
    InvalidChunkID,
    InvalidFORMChunkFormat,
    InvalidRIFFChunkFormat,
};

const ro_flag = std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_only };

// use max_err_info_size to ensure err_info will always have capacity for any error info
pub fn readInfo(path: []const u8, err_info: ?[]u8) !PCMInfo {
    // void the err_info so we don't report nonsense if we have an unanticipated error
    if (err_info) |ei| @memcpy(ei, "void");
    // populate ei with a dummy buffer if no err_info was provided
    const ei: []u8 = err_info orelse @constCast(&std.mem.zeroes([max_err_info_size]u8));

    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    switch (try getFormat(f, ei)) {
        Format.wav => return readWavHeader(f, ei),
        Format.aiff => return readAiffHeader(f, ei),
    }
}

// use max_err_info_size to ensure err_info will always have capacity for any error info
pub fn readAll(allocator: std.mem.Allocator, path: []const u8, err_info: ?[]u8) !PCMAll {
    // void the err_info so we don't report nonsense if we have an unanticipated error
    if (err_info) |ei| @memcpy(ei, "void");
    // populate ei with a dummy buffer if no err_info was provided
    const ei: []u8 = err_info orelse @constCast(&std.mem.zeroes([max_err_info_size]u8));

    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    switch (try getFormat(f, ei)) {
        Format.wav => return readWavData(allocator, f, ei),
        Format.aiff => @panic("not implemented yet"),
    }
}

const Format = enum {
    wav,
    aiff,
};

const ChunkID = enum(u32) {
    // these are reversed, because endianness
    fmt = 0x20746d66, // " tmf"
    data = 0x61746164, // "atad"
    bext = 0x74786562, // "txeb"
    id3 = 0x20336469, // " 3di"
    fake = 0x656b6146, // "ekaF"
    junk = 0x4b4e554a, // "knuj"
    COMM = 0x4D4D4F43, // "MMOC"
    COMT = 0x544D4F43, // "TMOC"
    INST = 0x54534E49, // "TSNI"
    MARK = 0x4B52414D, // "KRAM"
    unknown = 0x0,
};

// This used to be a packed u64 struct, which allowed us to use @bitCast
// when parsing chunk info. It may or may not have been faster, but was
// worse for debugging. Might be worth profiling at some point.
const ChunkInfo = struct {
    id_int: u32,
    size: u32,

    fn id(self: @This()) ChunkID {
        return std.meta.intToEnum(ChunkID, self.id_int) catch ChunkID.unknown;
    }
};

// TODO: the calls to nextChunkInfo in readWavHeader and readAiffHeader may
// have the wrong reverse_size_field parameter on big endian systems... still
// getting my head around that so need to test it out!

fn readWavHeader(f: std.fs.File, err_info: []u8) !PCMInfo {
    while (true) {
        const chunk_info = try nextChunkInfo(f, false);
        pcm_log.debug("chunk_info: {}, size: {d}", .{ chunk_info.id(), chunk_info.size });
        switch (chunk_info.id()) {
            ChunkID.fmt => return readFmtChunk(f),
            ChunkID.bext,
            ChunkID.id3,
            ChunkID.fake,
            ChunkID.junk,
            => try evenSeek(f, chunk_info.size),
            else => {
                @memcpy(err_info[0..4], &std.mem.toBytes(chunk_info.id_int));
                pcm_log.debug("readWavHeader: invalid chunk id: {s}", .{err_info[0..4]});
                return PCMReadError.InvalidChunkID;
            },
        }
    }
}

fn readAiffHeader(f: std.fs.File, err_info: []u8) !PCMInfo {
    while (true) {
        const chunk_info = try nextChunkInfo(f, true);
        pcm_log.debug("chunk_info: {}, size: {d}", .{ chunk_info.id(), chunk_info.size });
        switch (chunk_info.id()) {
            ChunkID.COMM => return readCOMMChunk(f),
            ChunkID.COMT,
            ChunkID.INST,
            ChunkID.MARK,
            => try evenSeek(f, chunk_info.size),
            else => {
                @memcpy(err_info[0..4], &std.mem.toBytes(chunk_info.id_int));
                pcm_log.debug("readAiffHeader: invalid chunk id: {s}", .{err_info[0..4]});
                return PCMReadError.InvalidChunkID;
            },
        }
    }
}

fn evenSeek(f: std.fs.File, offset: u32) !void {
    const o: i64 = if (offset & 1 == 1) offset + 1 else offset;
    try f.seekBy(o);
}

fn readWavData(allocator: std.mem.Allocator, f: std.fs.File, err_info: []u8) !PCMAll {
    const info = try readWavHeader(f, err_info);
    pcm_log.debug("readWavData: info: {}", .{info});

    while (true) {
        const chunk_info = try nextChunkInfo(f, false);
        pcm_log.debug("chunk_info: {}, size: {d}", .{ chunk_info.id(), chunk_info.size });

        switch (chunk_info.id()) {
            ChunkID.data => {
                const raw_data = try allocator.alloc(u8, chunk_info.size);
                defer allocator.free(raw_data);

                const read = try f.readAll(raw_data);
                if (read < chunk_info.size) {
                    pcm_log.debug("readWavData: ShortRead: {d} bytes", .{read});
                    return PCMReadError.ShortRead;
                }

                const bytes_per_sample = info.bit_depth / 8;
                const sample_count = chunk_info.size / bytes_per_sample;
                pcm_log.debug("transforming {d} frames / {d} bytes per frame", .{ sample_count, bytes_per_sample });

                var iterator = std.mem.window(u8, raw_data, bytes_per_sample, bytes_per_sample);
                var result = try allocator.alloc(f32, sample_count);

                // TODO: handle null from iterator.next()
                switch (info.bit_depth) {
                    16 => {
                        for (0..sample_count) |i| {
                            const s: f32 = @floatFromInt(std.mem.bytesToValue(i16, iterator.next().?));
                            result[i] = s / 32768.0;
                        }
                    },
                    24 => {
                        for (0..sample_count) |i| {
                            const s: f32 = @floatFromInt(std.mem.bytesToValue(i24, iterator.next().?));
                            result[i] = s / 8388608.0;
                        }
                    },
                    32 => {
                        // TODO: we can probably just use std.mem.bytesToValue or bytesAsValue on the whole slice
                        for (0..sample_count) |i| {
                            result[i] = std.mem.bytesToValue(f32, iterator.next().?);
                        }
                    },
                    else => @panic("bit depth not supported"),
                }

                return .{ info, result };
            },
            else => {
                try evenSeek(f, chunk_info.size);
            },
        }
    }
}

// NOTE: each of these functions assumes that the file offset is in the correct
// place (e.g. 0 for the RIFF chunk, or at the start of a new chunk for nextChunkInfo)

fn getFormat(f: std.fs.File, err_info: []u8) !Format {
    const chunk_size: u32 = 12;
    var buf: [chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < chunk_size) {
        pcm_log.debug("getFormat: ShortRead: {d} bytes", .{read});
        return PCMReadError.ShortRead;
    }

    // TODO: there's probably a more elegant way to write the rest of this function
    if (std.mem.eql(u8, buf[0..4], "RIFF")) {
        if (!std.mem.eql(u8, buf[8..12], "WAVE")) {
            @memcpy(err_info[0..4], buf[8..12]);
            pcm_log.debug("getFormat: invalid RIFF chunk format: {s}", .{err_info[0..4]});
            return PCMReadError.InvalidRIFFChunkFormat;
        }
        return Format.wav;
    } else if (std.mem.eql(u8, buf[0..4], "FORM")) {
        if (!std.mem.eql(u8, buf[8..12], "AIFF")) {
            @memcpy(err_info[0..4], buf[8..12]);
            pcm_log.debug("getFormat: invalid FORM chunk format: {s}", .{err_info[0..4]});
            return PCMReadError.InvalidFORMChunkFormat;
        }
        return Format.aiff;
    }

    @memcpy(err_info[0..4], buf[0..4]);
    pcm_log.debug("getFormat: invalid chunk id: {s}", .{err_info[0..4]});
    return PCMReadError.InvalidChunkID;
}

fn nextChunkInfo(f: std.fs.File, reverse_size_field: bool) !ChunkInfo {
    const size = @sizeOf(ChunkInfo);
    var buf: [size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < size) {
        pcm_log.debug("nextChunkInfo: ShortRead: {d} bytes", .{read});
        return PCMReadError.ShortRead;
    }
    if (reverse_size_field) std.mem.reverse(u8, buf[4..8]);
    return .{
        .id_int = std.mem.bytesToValue(u32, buf[0..4]),
        .size = std.mem.bytesToValue(u32, buf[4..8]),
    };
}

// in readFmtChunk and readCOMMChunk, predicting the chunk size at comptime,
// rather than reading the size from the chunk prefix itself, allows us to avoid
// use of an allocator, which makes our public API super simple.
// for uncompressed audio, the chunks are unlikely to be anything other than
// 16/18 bytes for wav/fmt and aiff/COMM respectively. if they are larger,
// nothing we care about at the moment will need those additional bytes.

fn readFmtChunk(f: std.fs.File) !PCMInfo {
    const chunk_size: usize = 16;
    var buf: [chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < chunk_size) {
        pcm_log.debug("readFmtChunk: ShortRead: {d} bytes", .{read});
        return PCMReadError.ShortRead;
    }
    return .{
        .channels = std.mem.bytesToValue(u16, buf[2..4]),
        .sample_rate = std.mem.bytesToValue(u32, buf[4..8]),
        .bit_depth = std.mem.bytesToValue(u16, buf[14..16]),
    };
}

fn readCOMMChunk(f: std.fs.File) !PCMInfo {
    const chunk_size: usize = 18;
    var buf: [chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < chunk_size) {
        pcm_log.debug("readCOMMChunk: ShortRead: {d} bytes", .{read});
        return PCMReadError.ShortRead;
    }

    if (target_endianness == std.builtin.Endian.little) {
        std.mem.reverse(u8, buf[0..2]);
        std.mem.reverse(u8, buf[6..8]);
        std.mem.reverse(u8, buf[8..18]);
    }

    return .{
        .channels = std.mem.bytesToValue(u16, buf[0..2]),
        .sample_rate = @intFromFloat(std.mem.bytesToValue(f80, buf[8..18])),
        .bit_depth = std.mem.bytesToValue(u16, buf[6..8]),
    };
}
