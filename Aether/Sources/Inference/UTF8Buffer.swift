import Foundation

/// A robust, RFC-3629 compliant streaming UTF-8 buffer.
///
/// Accumulates partial multi-byte UTF-8 sequences across token boundaries and safely
/// decodes them. If an invalid or unrecoverable byte sequence is encountered, it emits
/// the standard Unicode replacement character (`\u{FFFD}`) rather than permanently
/// poisoning the buffer or halting token emission.
internal struct UTF8Buffer: Sendable {
    private var buffer: [UInt8] = []

    internal init() {}

    /// Appends raw CChar token piece bytes and drains all complete characters.
    internal mutating func append(_ bytes: [CChar], onString: (String) -> Void) {
        for b in bytes {
            buffer.append(UInt8(bitPattern: b))
            drain(onString: onString)
        }
    }

    /// Appends raw UInt8 token piece bytes and drains all complete characters.
    internal mutating func append(_ bytes: [UInt8], onString: (String) -> Void) {
        for b in bytes {
            buffer.append(b)
            drain(onString: onString)
        }
    }

    /// Convenience process for UInt8 returning emitted String.
    internal mutating func processBytes(_ bytes: [UInt8]) -> String {
        var result = ""
        append(bytes) { result += $0 }
        return result
    }

    /// Flushes any remaining bytes at the end of generation.
    internal mutating func flush(onString: (String) -> Void) {
        while !buffer.isEmpty {
            if let str = String(bytes: buffer, encoding: .utf8) {
                onString(str)
                buffer.removeAll()
                return
            } else {
                onString("\u{FFFD}")
                buffer.removeFirst()
            }
        }
    }

    /// Convenience flush returning emitted String.
    internal mutating func flush() -> String {
        var result = ""
        flush { result += $0 }
        return result
    }

    private mutating func drain(onString: (String) -> Void) {
        while !buffer.isEmpty {
            let first = buffer[0]
            let expectedLen: Int

            if first < 0x80 {
                expectedLen = 1
            } else if (first & 0xE0) == 0xC0 && first >= 0xC2 {
                expectedLen = 2
            } else if (first & 0xF0) == 0xE0 {
                expectedLen = 3
            } else if (first & 0xF8) == 0xF0 && first <= 0xF4 {
                expectedLen = 4
            } else {
                // Illegal UTF-8 start byte: emit replacement character and advance
                onString("\u{FFFD}")
                buffer.removeFirst()
                continue
            }

            if buffer.count < expectedLen {
                // Incomplete multi-byte sequence; wait for subsequent bytes
                return
            }

            let slice = Array(buffer[..<expectedLen])
            if let validStr = String(bytes: slice, encoding: .utf8) {
                onString(validStr)
                buffer.removeFirst(expectedLen)
            } else {
                // Malformed sequence bytes: emit replacement character and advance
                onString("\u{FFFD}")
                buffer.removeFirst()
            }
        }
    }
}
