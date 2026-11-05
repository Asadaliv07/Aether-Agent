import Foundation

/// A bounded, streaming stop-sequence filter adapted from upstream llama.cpp
/// (`tools/server/server-context.cpp` and `common/common.h:string_find_partial_stop`).
///
/// Incremental text pieces are buffered such that trailing text matching any prefix of
/// a configured stop sequence is held back. When a complete stop sequence is encountered,
/// safe preceding text is emitted, the stop sequence and subsequent text in the chunk
/// are discarded, and `didHitStop` is flagged as `true`. If generation ends without
/// reaching a full stop match, `flush()` emits the held-back text.
public struct StreamingStopFilter: Sendable {
    /// Configured unique stop sequences.
    public let stopSequences: [String]

    /// Maximum character length among all configured stop sequences.
    private let maxStopLength: Int

    /// Buffer holding potentially matching partial suffixes.
    private var pendingBuffer: String = ""

    /// Initializes a streaming stop filter with an array of stop sequences.
    ///
    /// Empty strings are ignored, and duplicates are removed while preserving order.
    public init(stopSequences: [String]) {
        var unique: [String] = []
        for s in stopSequences where !s.isEmpty && !unique.contains(s) {
            unique.append(s)
        }
        self.stopSequences = unique
        self.maxStopLength = unique.map(\.count).max() ?? 0
    }

    /// Appends a new text piece to the streaming filter.
    ///
    /// - Parameter text: Newly decoded text piece.
    /// - Returns: A tuple containing:
    ///   - `textToEmit`: Safe text confirmed not to be part of any stop sequence.
    ///   - `didHitStop`: Whether a configured stop sequence was fully matched.
    public mutating func append(_ text: String) -> (textToEmit: String, didHitStop: Bool) {
        // Fast path: No stop sequences configured, pass through immediately with zero latency.
        guard !stopSequences.isEmpty else {
            return (textToEmit: text, didHitStop: false)
        }

        guard !text.isEmpty else {
            return (textToEmit: "", didHitStop: false)
        }

        pendingBuffer += text

        // Step 1: Check for a full stop match in pendingBuffer.
        // We look for the earliest match (smallest lowerBound in pendingBuffer).
        var earliestMatchRange: Range<String.Index>? = nil
        for stop in stopSequences {
            if let range = pendingBuffer.range(of: stop) {
                if let currentEarliest = earliestMatchRange {
                    if range.lowerBound < currentEarliest.lowerBound {
                        earliestMatchRange = range
                    }
                } else {
                    earliestMatchRange = range
                }
            }
        }

        if let matchRange = earliestMatchRange {
            // Safe text is everything before the earliest stop sequence match.
            let safeText = String(pendingBuffer[..<matchRange.lowerBound])
            // Discard the stop sequence and anything after it in this chunk.
            pendingBuffer = ""
            return (textToEmit: safeText, didHitStop: true)
        }

        // Step 2: Check for a partial stop match.
        // A partial stop is a non-empty suffix of pendingBuffer that matches a prefix of any stop sequence.
        // To prevent leaking a partial stop, we hold back the LONGEST matching suffix.
        let checkLength = min(pendingBuffer.count, maxStopLength)
        var longestPartialMatchLength = 0

        for len in stride(from: checkLength, through: 1, by: -1) {
            let suffix = pendingBuffer.suffix(len)
            if stopSequences.contains(where: { $0.hasPrefix(suffix) }) {
                longestPartialMatchLength = len
                break
            }
        }

        if longestPartialMatchLength > 0 {
            let splitIndex = pendingBuffer.index(pendingBuffer.endIndex, offsetBy: -longestPartialMatchLength)
            let safeText = String(pendingBuffer[..<splitIndex])
            pendingBuffer = String(pendingBuffer[splitIndex...])
            return (textToEmit: safeText, didHitStop: false)
        } else {
            let safeText = pendingBuffer
            pendingBuffer = ""
            return (textToEmit: safeText, didHitStop: false)
        }
    }

    /// Flushes any pending held-back characters at normal end of generation.
    ///
    /// - Returns: Any buffered characters that were held as potential partial matches.
    public mutating func flush() -> String {
        let remaining = pendingBuffer
        pendingBuffer = ""
        return remaining
    }
}
