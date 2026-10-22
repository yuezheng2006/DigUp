import Foundation

/// ISAAC-64, based on Bob Jenkins' public-domain algorithm (1996):
/// https://burtleburtle.net/bob/c/isaac64.c
/// SNS consumes reverse result words, serialized big-endian.
struct MomentsCipher {
    private var memory = [UInt64](repeating: 0, count: 256)
    private var output = [UInt64](repeating: 0, count: 256)
    private var a: UInt64 = 0
    private var b: UInt64 = 0
    private var c: UInt64 = 0
    private var remaining = 0
    init(seed: UInt64) {
        var state = [UInt64](repeating: 0x9e3779b97f4a7c13, count: 8)
        for _ in 0..<4 { Self.mix(&state) }
        for pass in 0..<2 {
            for base in stride(from: 0, to: 256, by: 8) {
                for j in 0..<8 { state[j] &+= pass == 0 ? (base + j == 0 ? seed : 0) : memory[base + j] }
                Self.mix(&state)
                for j in 0..<8 { memory[base + j] = state[j] }
            }
        }
    }
    private static func mix(_ s: inout [UInt64]) {
        let shifts = [9, 9, 23, 15, 14, 20, 17, 14]
        for j in 0..<8 {
            s[j] &-= s[(j + 4) % 8]
            let value = s[(j + 7) % 8]
            s[(j + 5) % 8] ^= j % 2 == 0 ? value >> shifts[j] : value << shifts[j]
            s[(j + 7) % 8] &+= s[j]
        }
    }
    mutating func next() -> UInt64 {
        if remaining == 0 {
            c &+= 1; b &+= c
            for i in 0..<256 {
                let x = memory[i]
                switch i % 4 {
                case 0: a = ~(a ^ (a << 21))
                case 1: a ^= a >> 5
                case 2: a ^= a << 12
                default: a ^= a >> 33
                }
                a &+= memory[(i + 128) % 256]
                let y = memory[Int((x >> 3) & 255)] &+ a &+ b
                memory[i] = y
                b = memory[Int((y >> 11) & 255)] &+ x
                output[i] = b
            }
            remaining = 256
        }
        remaining -= 1
        return output[remaining]
    }
    static func decode(_ bytes: Data, seed: UInt64) -> Data {
        var cipher = Self(seed: seed)
        var result = [UInt8](bytes)
        for offset in stride(from: 0, to: result.count, by: 8) {
            let word = cipher.next()
            for j in 0..<min(8, result.count - offset) { result[offset + j] ^= UInt8(truncatingIfNeeded: word >> (56 - j * 8)) }
        }
        return Data(result)
    }
}
