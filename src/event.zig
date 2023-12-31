const std = @import("std");
const libsecp256k1 = @import("libsecp256k1.zig");
const keys = @import("keys.zig");
const string = @import("string.zig");

pub const ValidationError = error{ IdDoesntMatch, InvalidPublicKey, InvalidSignature, InternalError };

pub const Event = struct {
    kind: u16,
    content: []const u8,
    tags: [][][]const u8 = undefined,
    created_at: i64 = undefined,
    pubkey: [32]u8 = undefined,
    id: [32]u8 = undefined,
    sig: [64]u8 = undefined,

    pub fn verify(self: Event, allocator: std.mem.Allocator) ValidationError!void {
        // check id
        var s = string.init(allocator);
        defer s.deinit();

        self.serializeForHashing(&s) catch |err| switch (err) {
            error.OutOfMemory => return ValidationError.InternalError,
            error.InvalidRange => unreachable,
        };

        var id: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(s.str(), &id, .{});
        if (!std.mem.eql(u8, &id, &self.id)) {
            return ValidationError.IdDoesntMatch;
        }

        // check signature
        const ctx = libsecp256k1.getContext();
        var xonly_pk: libsecp256k1.secp256k1_xonly_pubkey = undefined;
        if (0 == libsecp256k1.secp256k1_xonly_pubkey_parse(ctx, &xonly_pk, &self.pubkey)) {
            return ValidationError.InvalidPublicKey;
        }

        if (0 == libsecp256k1.secp256k1_schnorrsig_verify(ctx, &self.sig, &id, 32, &xonly_pk)) {
            return ValidationError.InvalidSignature;
        }
    }

    pub fn finalize(self: *Event, sk: keys.SecretKey, allocator: std.mem.Allocator) !void {
        // set created_at if not set
        self.created_at = std.time.timestamp();

        // write public key
        sk.serializedPublicKey(&self.pubkey);

        // serialize and hash the event to obtain the id
        var s = string.init(allocator);
        defer s.deinit();
        try self.serializeForHashing(&s);
        std.crypto.hash.sha2.Sha256.hash(s.str(), &self.id, .{});

        // fill in the signature
        try sk.sign(&self.sig, self.id);
    }

    pub fn serialize(self: *Event, s: *string.String) !void {
        try s.allocate("'id''','pubkey''','sig''','content''','tags'[],'kind'~~~~~,'created_at'~~~~~~~~~~,".len + 128 + 64 + 64 + self.content.len);
        try s.concat("{\"id\":");
        try std.json.encodeJsonString(&std.fmt.bytesToHex(self.id, std.fmt.Case.lower), .{}, s.writer());
        try s.concat(",\"sig\":");
        try std.json.encodeJsonString(&std.fmt.bytesToHex(self.sig, std.fmt.Case.lower), .{}, s.writer());
        try s.concat(",\"pubkey\":");
        try std.json.encodeJsonString(&std.fmt.bytesToHex(self.pubkey, std.fmt.Case.lower), .{}, s.writer());
        try s.concat(",\"created_at\":");
        try std.fmt.formatInt(self.created_at, 10, std.fmt.Case.lower, .{}, s.writer());
        try s.concat(",\"kind\":");
        try std.fmt.formatInt(self.kind, 10, std.fmt.Case.lower, .{}, s.writer());
        try s.concat(",\"tags\":");
        try self.serializeTags(s);
        try s.concat(",\"content\":");
        try std.json.encodeJsonString(self.content, .{}, s.writer());
        try s.concat("}");
    }

    fn serializeForHashing(self: Event, s: *string.String) !void {
        try s.allocate("[0,'',,,[],'']".len + 64 + self.content.len);
        try s.concat("[0,");
        try std.json.encodeJsonString(&std.fmt.bytesToHex(self.pubkey, std.fmt.Case.lower), .{}, s.writer());
        try s.concat(",");
        try std.fmt.formatInt(self.created_at, 10, std.fmt.Case.lower, .{}, s.writer());
        try s.concat(",");
        try std.fmt.formatInt(self.kind, 10, std.fmt.Case.lower, .{}, s.writer());
        try s.concat(",");
        try self.serializeTags(s);
        try s.concat(",");
        try std.json.encodeJsonString(self.content, .{}, s.writer());
        try s.concat("]");
    }

    fn serializeTags(self: Event, w: *string.String) !void {
        try w.concat("[");
        for (self.tags, 0..) |tag, t| {
            if (t != 0) {
                try w.concat(",");
            }
            try w.concat("[");
            for (tag, 0..) |item, i| {
                if (i != 0) {
                    try w.concat(",");
                }
                try std.json.encodeJsonString(item, .{}, w.writer());
            }
            try w.concat("]");
        }
        try w.concat("]");
    }
};
