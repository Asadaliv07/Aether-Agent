import XCTest
@testable import Aether

final class StreamingStopFilterTests: XCTestCase {

    func testStopSequenceWithinSinglePiece() {
        var filter = StreamingStopFilter(stopSequences: ["###"])
        let (emitted1, stop1) = filter.append("Hello world###")
        XCTAssertEqual(emitted1, "Hello world")
        XCTAssertTrue(stop1)
        XCTAssertEqual(filter.flush(), "")
    }

    func testStopSequenceSplitAcrossTwoPieces() {
        var filter = StreamingStopFilter(stopSequences: ["###"])
        let (emitted1, stop1) = filter.append("Hello world#")
        XCTAssertEqual(emitted1, "Hello world")
        XCTAssertFalse(stop1)

        let (emitted2, stop2) = filter.append("##")
        XCTAssertEqual(emitted2, "")
        XCTAssertTrue(stop2)
        XCTAssertEqual(filter.flush(), "")
    }

    func testStopSequenceSplitAcrossMultiplePieces() {
        var filter = StreamingStopFilter(stopSequences: ["<|end|>"])
        var result = ""

        let chunks = ["Hello ", "<", "|", "end", "|", ">"]
        var stopped = false
        for chunk in chunks {
            let (emitted, stop) = filter.append(chunk)
            result += emitted
            if stop {
                stopped = true
                break
            }
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(result, "Hello ")
        XCTAssertEqual(filter.flush(), "")
    }

    func testNoStopSequenceFlushesAllSafeOutput() {
        var filter = StreamingStopFilter(stopSequences: ["###"])
        let (emitted1, stop1) = filter.append("The quick brown fox jumps over the lazy dog.")
        XCTAssertFalse(stop1)
        let flushed = filter.flush()
        XCTAssertEqual(emitted1 + flushed, "The quick brown fox jumps over the lazy dog.")
    }

    func testEmptyStopSequenceListEmitsImmediately() {
        var filter = StreamingStopFilter(stopSequences: [])
        let (emitted1, stop1) = filter.append("Hello world")
        XCTAssertEqual(emitted1, "Hello world")
        XCTAssertFalse(stop1)
        XCTAssertEqual(filter.flush(), "")
    }

    func testMultipleConfiguredStopSequences() {
        var filter = StreamingStopFilter(stopSequences: ["</s>", "###", "<|im_end|>"])
        let (e1, s1) = filter.append("Thinking process...\n")
        XCTAssertFalse(s1)
        let (e2, s2) = filter.append("Answer is 42.###")
        XCTAssertTrue(s2)
        XCTAssertEqual(e1 + e2, "Thinking process...\nAnswer is 42.")
    }

    func testPrefixSharingAndOverlappingStopSequences() {
        // "apple" and "apple pie"
        var filter = StreamingStopFilter(stopSequences: ["apple pie", "apple"])
        let (e1, s1) = filter.append("I like to eat ")
        XCTAssertFalse(s1)
        let (e2, s2) = filter.append("apple")
        // "apple" matches! Earliest match halts generation and discards stop word
        XCTAssertTrue(s2)
        XCTAssertEqual(e1 + e2, "I like to eat ")
    }

    func testPartialStopPrefixAtEndOfGenerationFlushed() {
        var filter = StreamingStopFilter(stopSequences: ["###"])
        let (e1, s1) = filter.append("Here is #")
        XCTAssertEqual(e1, "Here is ")
        XCTAssertFalse(s1)

        // Generation ends without second and third '#'
        let flushed = filter.flush()
        XCTAssertEqual(flushed, "#")
    }

    func testFalsePositivePartialMatchResumesEmission() {
        var filter = StreamingStopFilter(stopSequences: ["###"])
        let (e1, s1) = filter.append("Value is #")
        XCTAssertEqual(e1, "Value is ")
        XCTAssertFalse(s1)

        let (e2, s2) = filter.append("123")
        XCTAssertEqual(e2, "#123")
        XCTAssertFalse(s2)

        XCTAssertEqual(filter.flush(), "")
    }

    func testMultibyteUTF8SplitAcrossPieces() {
        var filter = StreamingStopFilter(stopSequences: ["🛑STOP"])
        let (e1, s1) = filter.append("Attention 🛑")
        XCTAssertEqual(e1, "Attention ")
        XCTAssertFalse(s1)

        let (e2, s2) = filter.append("STOP now")
        XCTAssertEqual(e2, "")
        XCTAssertTrue(s2)
    }

    func testEmptyTokenPieces() {
        var filter = StreamingStopFilter(stopSequences: ["STOP"])
        let (e1, s1) = filter.append("")
        XCTAssertEqual(e1, "")
        XCTAssertFalse(s1)

        let (e2, s2) = filter.append("Running")
        XCTAssertEqual(e2, "Running")
        XCTAssertFalse(s2)

        let (e3, s3) = filter.append("")
        XCTAssertEqual(e3, "")
        XCTAssertFalse(s3)
        XCTAssertEqual(filter.flush(), "")
    }

    func testStopSequenceFollowedByTrailingTextInSameChunk() {
        var filter = StreamingStopFilter(stopSequences: ["###"])
        let (e1, s1) = filter.append("First line###Trailing text that must not be emitted")
        XCTAssertEqual(e1, "First line")
        XCTAssertTrue(s1)
        XCTAssertEqual(filter.flush(), "")
    }

    func testCancellationWhilePartialMatchBuffered() {
        var filter = StreamingStopFilter(stopSequences: ["<|end|>"])
        let (e1, s1) = filter.append("Result <|")
        XCTAssertEqual(e1, "Result ")
        XCTAssertFalse(s1)
        XCTAssertFalse(e1.contains("<"))
    }

    func testStopSequenceAtTokenLimitBoundary() {
        var filter = StreamingStopFilter(stopSequences: ["END"])
        var emittedTotal = ""
        let tokens = ["Alpha", "Beta", "EN"]
        for t in tokens {
            let (e, _) = filter.append(t)
            emittedTotal += e
        }
        let (eLast, didStop) = filter.append("D")
        emittedTotal += eLast
        XCTAssertTrue(didStop)
        XCTAssertEqual(emittedTotal, "AlphaBeta")
    }

    func testConfigurationBoundsValidation() {
        let validConfig = GenerationConfiguration(stopSequences: ["###", "</s>"])
        XCTAssertNoThrow(try validConfig.validate())

        let emptySeqConfig = GenerationConfiguration(stopSequences: [""])
        XCTAssertThrowsError(try emptySeqConfig.validate())

        let tooManyConfig = GenerationConfiguration(stopSequences: ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertThrowsError(try tooManyConfig.validate())

        let tooLongSeq = String(repeating: "A", count: 65)
        let tooLongConfig = GenerationConfiguration(stopSequences: [tooLongSeq])
        XCTAssertThrowsError(try tooLongConfig.validate())
    }
}
