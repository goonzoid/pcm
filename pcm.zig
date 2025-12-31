const std = @import("std");
const builtin = @import("builtin");

// TODO: in the current version of zig (0.15.2) file readers use positional mode by default.
// in this mode, calling readSliceAll and friends doesn't make use of the buffer, we need to
// call fill ourselves to fill it. it seems likely that we could get a performance benefit by
// providing a buffer and filling it, or switching to streaming mode, but we need to measure.

// TODO: we currently assume 32 bit depth means floating point samples, but this doesn't have
// to be the case. We should start paying attention to the actual sample type from the header so
// that we can support more valid format.

const native_endian = builtin.cpu.arch.endian();
comptime {
    // we handle endianness correctly in some places, but not everywhere. it's safest to just stick
    // to little endian systems for now until we have time to test on a big endian machine
    std.debug.assert(native_endian == .little);
}

const pcm_log = std.log.scoped(.pcm);

pub const Format = struct {
    file_type: FileType,
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,
};

pub const FileType = enum {
    wav,
    aiff,
};

pub const Audio = struct {
    format: Format,
    samples: []f32,
};

pub const Diagnostics = struct {
    chunk_id: [4]u8,
};

pub fn readFormat(path: []const u8, diagnostics: ?*Diagnostics) !Format {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    var fr = f.reader(&.{});
    const r = &fr.interface;

    switch (try readFileType(r, diagnostics)) {
        FileType.wav => return readWavHeader(r, diagnostics),
        FileType.aiff => return readAiffHeader(r, diagnostics),
    }
}

pub fn readAll(allocator: std.mem.Allocator, path: []const u8, diagnostics: ?*Diagnostics) !Audio {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    var fr = f.reader(&.{});
    const r = &fr.interface;

    switch (try readFileType(r, diagnostics)) {
        FileType.wav => return readWavData(allocator, r, diagnostics),
        FileType.aiff => @panic("not implemented yet"),
    }
}

pub fn writeAll(path: []const u8, format: Format, samples: []const f32) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();

    var buf: [4096]u8 = undefined;
    var fw = f.writer(&buf);
    const w = &fw.interface;

    switch (format.file_type) {
        FileType.wav => try writeWav(w, format, samples),
        FileType.aiff => @panic("not implemented yet"),
    }
}

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

fn readWavHeader(r: *std.Io.Reader, diagnostics: ?*Diagnostics) !Format {
    while (true) {
        const chunk_info = try nextChunkInfo(r, .wav);
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
                return error.ReadError;
            },
        }
    }
}

fn readAiffHeader(r: *std.Io.Reader, diagnostics: ?*Diagnostics) !Format {
    while (true) {
        const chunk_info = try nextChunkInfo(r, .aiff);
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
                return error.ReadError;
            },
        }
    }
}

fn evenSeek(r: *std.Io.Reader, offset: usize) !void {
    try r.discardAll(offset + (offset & 1));
}

fn readWavData(allocator: std.mem.Allocator, r: *std.Io.Reader, diagnostics: ?*Diagnostics) !Audio {
    const format = try readWavHeader(r, diagnostics);

    while (true) {
        const chunk_info = try nextChunkInfo(r, .wav);
        pcm_log.debug("chunk id: {s}, size: {d}", .{ chunk_info.id, chunk_info.size });

        switch (chunk_info.ID()) {
            ChunkID.data => {
                switch (format.bit_depth) {
                    32 => {
                        const data = try allocator.alloc(u8, chunk_info.size);
                        try r.readSliceAll(data);
                        return .{ .format = format, .samples = @ptrCast(@alignCast(data)) };
                    },
                    16, 24 => {
                        const bytes_per_sample = format.bit_depth / 8;
                        const sample_count = chunk_info.size / bytes_per_sample;

                        const raw_data = try allocator.alloc(u8, chunk_info.size);
                        defer allocator.free(raw_data);
                        try r.readSliceAll(raw_data);

                        const result = try allocator.alloc(f32, sample_count);
                        errdefer allocator.free(result);

                        pcm_log.debug(
                            "transforming {d} frames @ {d} bytes per sample",
                            .{ sample_count / format.channels, bytes_per_sample },
                        );

                        var iterator = std.mem.window(u8, raw_data, bytes_per_sample, bytes_per_sample);

                        // Ideally we wouldn't need this second switch, but reading arbitrary sized ints into a single
                        // fixed size type is tricky. std.mem.readVarInt looked promising, but either has a bug, or
                        // isn't intended for this use case (more likely).
                        // e.g. readVarInt(i24, &.{0xFF, 0xFF}, .little) returns 65535 rather than -1
                        // This is okay for now, but hopefully we can find a better solution when we start supporting
                        // arbitrary bit depths.
                        switch (format.bit_depth) {
                            16 => {
                                try scaleIntsToFloats(i16, &iterator, sample_count, scaleFactor(format.bit_depth), result);
                            },
                            24 => {
                                try scaleIntsToFloats(i24, &iterator, sample_count, scaleFactor(format.bit_depth), result);
                            },
                            else => unreachable,
                        }

                        return .{ .format = format, .samples = result };
                    },
                    else => @panic("bit depth not supported"),
                }
            },
            else => {
                try evenSeek(r, chunk_info.size);
            },
        }
    }
}

fn scaleFactor(bit_depth: u16) f32 {
    return @floatFromInt(std.math.pow(i32, 2, bit_depth - 1));
}

fn scaleIntsToFloats(comptime T: type, iterator: *std.mem.WindowIterator(u8), sample_count: usize, scale_factor: f32, result: []f32) !void {
    for (0..sample_count) |i| {
        const bytes = iterator.next() orelse return error.ReadError;
        const s: f32 = @floatFromInt(std.mem.readVarInt(T, bytes, .little));
        result[i] = s / scale_factor;
    }
}

fn writeWav(w: *std.Io.Writer, format: Format, samples: []const f32) !void {
    const header_size = 4 + 24 + 8; // RIFF format + fmt chunk + data chunk header
    const bytes_per_sample = format.bit_depth / 8;
    const bytes_per_frame = format.channels * bytes_per_sample;
    const bytes_per_second = format.sample_rate * bytes_per_frame;
    const data_size = std.math.cast(u32, @as(u64, samples.len) * bytes_per_sample) orelse {
        std.log.err("cannot write {d} samples @ {d} bytes per sample to a regular wav", .{ samples.len, bytes_per_sample });
        return error.AudioDataTooLarge;
    };
    const total_size = header_size + data_size;
    pcm_log.debug("writeWav: total size: {d} data size: {d}", .{ total_size, data_size });

    try w.writeAll("RIFF");
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, total_size)));
    try w.writeAll("WAVE");

    try w.writeAll("fmt ");
    // TODO: this may be incorrect for 32bit float
    // see http://www-mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/WAVE.html
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, 16)));

    // wFormatTag (2 bytes): 1 for PCM, 3 for float
    // TODO: do this properly when we support more bit depths
    const audio_format: u16 = if (format.bit_depth < 32) 1 else 3;
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, audio_format)));

    // nChannels (2 bytes)
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, format.channels)));

    // nSamplesPerSec (4 bytes): sample rate
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, format.sample_rate)));

    // nAvgBytesPerSec (4 bytes): data rate (SampleRate * NumChannels * BitsPerSample / 8)
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, bytes_per_second)));

    // nBlockAlign (2 bytes): size of one audio block (NumChannels * BitsPerSample / 8)
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, bytes_per_frame)));

    // wBitsPerSample (2 bytes): bits per sample
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, format.bit_depth)));

    try w.writeAll("data");
    try w.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, data_size)));

    const scale_factor = scaleFactor(format.bit_depth);
    switch (format.bit_depth) {
        16 => {
            for (samples) |s| {
                const clamped = std.math.clamp(s * scale_factor, -scale_factor, scale_factor - 1);
                const int: i16 = @intFromFloat(clamped);
                const bytes: [2]u8 = @bitCast(int);
                try w.writeAll(&bytes);
            }
        },
        24 => {
            for (samples) |s| {
                const clamped = std.math.clamp(s * scale_factor, -scale_factor, scale_factor - 1);
                const int: i24 = @intFromFloat(clamped);
                const bytes: [3]u8 = @bitCast(int);
                try w.writeAll(&bytes);
            }
        },
        32 => {
            for (samples) |s| {
                try w.writeAll(@ptrCast(&s));
            }
        },
        else => @panic("bit depth not supported"),
    }

    try w.flush();
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
            return error.ReadError;
        }
        return FileType.wav;
    } else if (std.mem.eql(u8, buf[0..4], "FORM")) {
        if (!std.mem.eql(u8, buf[8..12], "AIFF")) {
            pcm_log.debug("getFormat: invalid FORM chunk format: {s}", .{buf[8..12]});
            if (diagnostics) |d| d.chunk_id = buf[8..12].*;
            return error.ReadError;
        }
        return FileType.aiff;
    }

    pcm_log.debug("getFormat: invalid chunk id: {s}", .{buf[0..4]});
    if (diagnostics) |d| d.chunk_id = buf[0..4].*;
    return error.ReadError;
}

fn nextChunkInfo(r: *std.Io.Reader, file_type: FileType) !ChunkInfo {
    var buf: [@sizeOf(ChunkInfo)]u8 = undefined;
    try r.readSliceAll(&buf);
    var size = std.mem.bytesToValue(u32, buf[4..8]);
    if (file_type == .aiff) size = std.mem.bigToNative(u32, size);
    return .{
        .id = buf[0..4].*,
        .size = size,
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

    if (native_endian == std.builtin.Endian.little) {
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
