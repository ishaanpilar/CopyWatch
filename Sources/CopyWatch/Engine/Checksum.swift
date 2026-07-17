import Foundation
import CryptoKit

/// Which checksum a job uses to prove every byte arrived intact.
///
/// SHA-256 is cryptographic and is what the integrity certificate's reproducible
/// ID is built from. xxHash64 is the film-industry default for media offload —
/// non-cryptographic but ~an order of magnitude faster per core, so it keeps the
/// hash from becoming the bottleneck on fast Thunderbolt RAIDs. Both catch the
/// bad-cable / failing-drive corruption that verification exists to find.
enum ChecksumAlgorithm: String, Codable, CaseIterable, Identifiable {
    case sha256
    case xxh64

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sha256: return "SHA-256"
        case .xxh64: return "xxHash64"
        }
    }

    var blurb: String {
        switch self {
        case .sha256: return "Cryptographic. Powers the certificate ID."
        case .xxh64: return "Faster. The media-industry standard (MHL)."
        }
    }

    func makeHasher() -> any StreamingHasher {
        switch self {
        case .sha256: return SHA256Hasher()
        case .xxh64: return XXH64()
        }
    }
}

/// A hash that can be fed a file in chunks and then asked for its hex digest.
protocol StreamingHasher {
    mutating func update(_ data: Data)
    func finalizedHex() -> String
}

/// CryptoKit SHA-256 behind the streaming interface.
struct SHA256Hasher: StreamingHasher {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalizedHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Streaming XXH64 (Yann Collet's xxHash, 64-bit) in pure Swift. Produces the
/// canonical 16-hex-digit digest and matches the reference implementation
/// byte-for-byte regardless of how the input is chunked.
struct XXH64: StreamingHasher {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private let seed: UInt64
    private var v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64
    private var mem = [UInt8](repeating: 0, count: 32)
    private var memSize = 0
    private var totalLen: UInt64 = 0

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        Self.rotl(acc &+ (input &* p2), 31) &* p1
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        ((acc ^ round(0, val)) &* p1) &+ p4
    }

    private static func read64(_ buf: UnsafeRawBufferPointer, _ off: Int) -> UInt64 {
        buf.loadUnaligned(fromByteOffset: off, as: UInt64.self).littleEndian
    }
    private static func read32(_ buf: UnsafeRawBufferPointer, _ off: Int) -> UInt32 {
        buf.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian
    }

    mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let len = raw.count
            totalLen &+= UInt64(len)
            var idx = 0

            // Not enough to complete a 32-byte block: just buffer it.
            if memSize + len < 32 {
                for i in 0..<len { mem[memSize + i] = raw[i] }
                memSize += len
                return
            }

            // Complete a partially-filled buffer and consume it.
            if memSize > 0 {
                let need = 32 - memSize
                for i in 0..<need { mem[memSize + i] = raw[i] }
                mem.withUnsafeBytes { mp in
                    v1 = Self.round(v1, Self.read64(mp, 0))
                    v2 = Self.round(v2, Self.read64(mp, 8))
                    v3 = Self.round(v3, Self.read64(mp, 16))
                    v4 = Self.round(v4, Self.read64(mp, 24))
                }
                idx += need
                memSize = 0
            }

            // Bulk 32-byte blocks straight from the input.
            while idx + 32 <= len {
                v1 = Self.round(v1, Self.read64(raw, idx))
                v2 = Self.round(v2, Self.read64(raw, idx + 8))
                v3 = Self.round(v3, Self.read64(raw, idx + 16))
                v4 = Self.round(v4, Self.read64(raw, idx + 24))
                idx += 32
            }

            // Stash the tail for next time / finalize.
            let rem = len - idx
            if rem > 0 {
                for i in 0..<rem { mem[i] = raw[idx + i] }
                memSize = rem
            }
        }
    }

    func finalizedHex() -> String {
        var h: UInt64
        if totalLen >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.mergeRound(h, v1)
            h = Self.mergeRound(h, v2)
            h = Self.mergeRound(h, v3)
            h = Self.mergeRound(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h = h &+ totalLen

        mem.withUnsafeBytes { mp in
            var i = 0
            while i + 8 <= memSize {
                h ^= Self.round(0, Self.read64(mp, i))
                h = (Self.rotl(h, 27) &* Self.p1) &+ Self.p4
                i += 8
            }
            if i + 4 <= memSize {
                h ^= UInt64(Self.read32(mp, i)) &* Self.p1
                h = (Self.rotl(h, 23) &* Self.p2) &+ Self.p3
                i += 4
            }
            while i < memSize {
                h ^= UInt64(mp[i]) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }

        h ^= h >> 33
        h = h &* Self.p2
        h ^= h >> 29
        h = h &* Self.p3
        h ^= h >> 32
        return String(format: "%016llx", h)
    }
}
