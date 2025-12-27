const std = @import("std");
const builtin = @import("builtin");

// TODO: in the current version of zig (0.15.2) file readers use positional mode by default.
// in this mode, calling readSliceAll and friends doesn't make use of the buffer, we need to
// call fill ourselves to fill it. it seems likely that we could get a performance benefit by
// providing a buffer and filling it, or switching to streaming mode, but we need to measure.

const native_endian = builtin.cpu.arch.endian();
comptime {
    // we handle endianness correctly in some places, but not everywhere. it's safest to just stick
    // to little endian systems for now until we have time to test on a big endian machine
    std.debug.assert(native_endian == .little);
}

const pcm_log = std.log.scoped(.pcm);

// 2^(bits-1)
const scale_factor_16 = 32768;
const scale_factor_24 = 8388608;

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

const ReadError = error{
    InvalidChunkID,
    InvalidFORMChunkFormat,
    InvalidRIFFChunkFormat,
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

fn evenSeek(r: *std.Io.Reader, offset: usize) !void {
    try r.discardAll(offset + (offset & 1));
}

fn readWavData(allocator: std.mem.Allocator, r: *std.Io.Reader, diagnostics: ?*Diagnostics) !Audio {
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
                var result = try allocator.alloc(f32, sample_count);
                errdefer allocator.free(result);

                // TODO: handle null from iterator.next()
                pcm_log.debug("transforming {d} frames @ {d} bytes per sample", .{ sample_count / format.channels, bytes_per_sample });
                var iterator = std.mem.window(u8, raw_data, bytes_per_sample, bytes_per_sample);
                switch (format.bit_depth) {
                    16 => {
                        for (0..sample_count) |i| {
                            const s: f32 = @floatFromInt(std.mem.bytesToValue(i16, iterator.next().?));
                            result[i] = s / scale_factor_16;
                        }
                    },
                    24 => {
                        for (0..sample_count) |i| {
                            const s: f32 = @floatFromInt(std.mem.bytesToValue(i24, iterator.next().?));
                            result[i] = s / scale_factor_24;
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

                return .{ .format = format, .samples = result };
            },
            else => {
                try evenSeek(r, chunk_info.size);
            },
        }
    }
}

fn writeWav(w: *std.Io.Writer, format: Format, samples: []const f32) !void {
    const header_size = 4 + 24 + 8; // RIFF format + fmt chunk + data chunk header
    const bytes_per_sample = format.bit_depth / 8;
    const bytes_per_frame = format.channels * bytes_per_sample;
    const bytes_per_second = format.sample_rate * bytes_per_frame;
    const data_size = @as(u32, @intCast(samples.len)) * bytes_per_sample;
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
    const audio_format: u16 = if (format.bit_depth < 32) 1 else 3; // this is janky
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

    for (samples) |sample| {
        switch (format.bit_depth) {
            16 => {
                const int: i16 = @intFromFloat(sample * scale_factor_16);
                const bytes: [2]u8 = @bitCast(int);
                try w.writeAll(&bytes);
            },
            24 => {
                const int: i24 = @intFromFloat(sample * scale_factor_24);
                const bytes: [3]u8 = @bitCast(int);
                try w.writeAll(&bytes);
            },
            32 => {
                try w.writeAll(@ptrCast(&sample));
            },
            else => @panic("bit depth not supported"),
        }
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
