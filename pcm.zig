const std = @import("std");
const builtin = @import("builtin");

// TODO: in the current version of zig (0.15.2) file readers use positional mode by default.
// in this mode, calling readSliceAll and friends doesn't make use of the buffer, we need to
// call fill ourselves to fill it. it seems likely that we could get a performance benefit by
// providing a buffer and filling it, or switching to streaming mode, but we need to measure.

const target_endianness = builtin.cpu.arch.endian();
comptime {
    // we handle endianness correctly in some places, but not everywhere. it's safest to just stick
    // to little endian systems for now until we have time to test on a big endian machine
    std.debug.assert(target_endianness == .little);
}

const pcm_log = std.log.scoped(.pcm);

pub const Format = struct {
    file_type: FileType,
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,
};

const AudioData = struct { Format, []f32 };

const ReadError = error{
    InvalidChunkID,
    InvalidFORMChunkFormat,
    InvalidRIFFChunkFormat,
};

pub const Diagnostics = struct {
    chunk_id: [4]u8,
};

pub fn readFormat(path: []const u8, diagnostics: ?*Diagnostics) !Format {
    const f = try std.fs.cwd().openFile(path, std.fs.File.OpenFlags{});
    defer f.close();

    var fr = f.reader(&.{});
    const r = &fr.interface;

    switch (try readFileType(r, diagnostics)) {
        FileType.wav => return readWavHeader(r, diagnostics),
        FileType.aiff => return readAiffHeader(r, diagnostics),
    }
}

pub fn readAll(allocator: std.mem.Allocator, path: []const u8, diagnostics: ?*Diagnostics) !AudioData {
    const f = try std.fs.cwd().openFile(path, std.fs.File.OpenFlags{});
    defer f.close();

    var fr = f.reader(&.{});
    const r = &fr.interface;

    switch (try readFileType(r, diagnostics)) {
        FileType.wav => return readWavData(allocator, r, diagnostics),
        FileType.aiff => @panic("not implemented yet"),
    }
}

const FileType = enum {
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
    id: [4]u8,
    size: u32,

    fn ID(self: @This()) ChunkID {
        const id_int: u32 = @bitCast(self.id);
        return std.meta.intToEnum(ChunkID, id_int) catch ChunkID.unknown;
    }
};

// TODO: the calls to nextChunkInfo in readWavHeader and readAiffHeader may
// have the wrong reverse_size_field parameter on big endian systems... still
// getting my head around that so need to test it out!

fn readWavHeader(r: *std.Io.Reader, diagnostics: ?*Diagnostics) !Format {
    while (true) {
        const chunk_info = try nextChunkInfo(r, false);
        pcm_log.debug("chunk id: {s}, size: {d}", .{ chunk_info.id, chunk_info.size });
        switch (chunk_info.ID()) {
            ChunkID.fmt => return readFmtChunk(r),
            ChunkID.bext,
            ChunkID.id3,
            ChunkID.fake,
            ChunkID.junk,
            => try evenSeek(r, chunk_info.size),
            else => {
                pcm_log.debug("readWavHeader: invalid chunk id: {s}", .{chunk_info.id});
                if (diagnostics) |d| d.chunk_id = chunk_info.id;
                return ReadError.InvalidChunkID;
            },
        }
    }
}

fn readAiffHeader(r: *std.Io.Reader, diagnostics: ?*Diagnostics) !Format {
    while (true) {
        const chunk_info = try nextChunkInfo(r, true);
        pcm_log.debug("chunk id: {s}, size: {d}", .{ chunk_info.id, chunk_info.size });
        switch (chunk_info.ID()) {
            ChunkID.COMM => return readCOMMChunk(r),
            ChunkID.COMT,
            ChunkID.INST,
            ChunkID.MARK,
            => try evenSeek(r, chunk_info.size),
            else => {
                pcm_log.debug("readAiffHeader: invalid chunk id: {s}", .{chunk_info.id});
                if (diagnostics) |d| d.chunk_id = chunk_info.id;
                return ReadError.InvalidChunkID;
            },
        }
    }
}

fn evenSeek(r: *std.Io.Reader, offset: u32) !void {
    const o = if (offset & 1 == 1) offset + 1 else offset;
    try r.discardAll(o);
}

fn readWavData(allocator: std.mem.Allocator, r: *std.Io.Reader, diagnostics: ?*Diagnostics) !AudioData {
    const format = try readWavHeader(r, diagnostics);

    while (true) {
        const chunk_info = try nextChunkInfo(r, false);
        pcm_log.debug("chunk id: {s}, size: {d}", .{ chunk_info.id, chunk_info.size });

        switch (chunk_info.ID()) {
            ChunkID.data => {
                const raw_data = try allocator.alloc(u8, chunk_info.size);
                defer allocator.free(raw_data);

                try r.readSliceAll(raw_data);

                const bytes_per_sample = format.bit_depth / 8;
                const sample_count = chunk_info.size / bytes_per_sample;
                pcm_log.debug("transforming {d} frames @ {d} bytes per sample", .{ sample_count / format.channels, bytes_per_sample });

                var iterator = std.mem.window(u8, raw_data, bytes_per_sample, bytes_per_sample);
                var result = try allocator.alloc(f32, sample_count);

                // TODO: handle null from iterator.next()
                switch (format.bit_depth) {
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

                return .{ format, result };
            },
            else => {
                try evenSeek(r, chunk_info.size);
            },
        }
    }
}

// NOTE: each of these functions assumes that the file offset is in the correct
// place (e.g. 0 for the RIFF chunk, or at the start of a new chunk for nextChunkInfo)

fn readFileType(r: *std.Io.Reader, diagnostics: ?*Diagnostics) !FileType {
    var buf: [12]u8 = undefined;
    try r.readSliceAll(&buf);

    // TODO: there's probably a more elegant way to write the rest of this function
    if (std.mem.eql(u8, buf[0..4], "RIFF")) {
        if (!std.mem.eql(u8, buf[8..12], "WAVE")) {
            pcm_log.debug("getFormat: invalid RIFF chunk format: {s}", .{buf[8..12]});
            if (diagnostics) |d| d.chunk_id = buf[8..12].*;
            return ReadError.InvalidRIFFChunkFormat;
        }
        return FileType.wav;
    } else if (std.mem.eql(u8, buf[0..4], "FORM")) {
        if (!std.mem.eql(u8, buf[8..12], "AIFF")) {
            pcm_log.debug("getFormat: invalid FORM chunk format: {s}", .{buf[8..12]});
            if (diagnostics) |d| d.chunk_id = buf[8..12].*;
            return ReadError.InvalidFORMChunkFormat;
        }
        return FileType.aiff;
    }

    pcm_log.debug("getFormat: invalid chunk id: {s}", .{buf[0..4]});
    if (diagnostics) |d| d.chunk_id = buf[0..4].*;
    return ReadError.InvalidChunkID;
}

fn nextChunkInfo(r: *std.Io.Reader, reverse_size_field: bool) !ChunkInfo {
    const size = @sizeOf(ChunkInfo);
    var buf: [size]u8 = undefined;
    try r.readSliceAll(&buf);
    if (reverse_size_field) std.mem.reverse(u8, buf[4..8]);
    return .{
        .id = buf[0..4].*,
        .size = std.mem.bytesToValue(u32, buf[4..8]),
    };
}

// in readFmtChunk and readCOMMChunk, predicting the chunk size at comptime,
// rather than reading the size from the chunk prefix itself, allows us to avoid
// use of an allocator, which makes our public API super simple.
// for uncompressed audio, the chunks are unlikely to be anything other than
// 16/18 bytes for wav/fmt and aiff/COMM respectively. if they are larger,
// nothing we care about at the moment will need those additional bytes.

fn readFmtChunk(r: *std.Io.Reader) !Format {
    var buf: [16]u8 = undefined;
    try r.readSliceAll(&buf);
    return .{
        .file_type = FileType.wav,
        .channels = std.mem.bytesToValue(u16, buf[2..4]),
        .sample_rate = std.mem.bytesToValue(u32, buf[4..8]),
        .bit_depth = std.mem.bytesToValue(u16, buf[14..16]),
    };
}

fn readCOMMChunk(r: *std.Io.Reader) !Format {
    var buf: [18]u8 = undefined;
    try r.readSliceAll(&buf);

    if (target_endianness == std.builtin.Endian.little) {
        std.mem.reverse(u8, buf[0..2]);
        std.mem.reverse(u8, buf[6..8]);
        std.mem.reverse(u8, buf[8..18]);
    }

    return .{
        .file_type = FileType.aiff,
        .channels = std.mem.bytesToValue(u16, buf[0..2]),
        .sample_rate = @intFromFloat(std.mem.bytesToValue(f80, buf[8..18])),
        .bit_depth = std.mem.bytesToValue(u16, buf[6..8]),
    };
}
