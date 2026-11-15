import XCTest
@testable import Aether

final class MessageMarkdownTests: XCTestCase {
    func testPlainProseWithoutCode() {
        let text = "Hello, world! This is a simple conversational message."
        let segments = MarkdownContentParser.parse(text)

        XCTAssertEqual(segments.count, 1)
        if case .prose(_, let content) = segments.first {
            XCTAssertEqual(content, text)
        } else {
            XCTFail("Expected single prose segment")
        }
    }

    func testSingleCodeBlockWithLanguage() {
        let text = """
        Here is a Swift function:
        ```swift
        func greet() -> String {
            return "Hello"
        }
        ```
        Hope that helps!
        """

        let segments = MarkdownContentParser.parse(text)
        XCTAssertEqual(segments.count, 3)

        if case .prose(_, let p1) = segments[0] {
            XCTAssertTrue(p1.contains("Here is a Swift function:"))
        } else {
            XCTFail("Expected prose segment at index 0")
        }

        if case .codeBlock(_, let lang, let code) = segments[1] {
            XCTAssertEqual(lang, "swift")
            XCTAssertTrue(code.contains("func greet()"))
        } else {
            XCTFail("Expected codeBlock segment at index 1")
        }

        if case .prose(_, let p2) = segments[2] {
            XCTAssertTrue(p2.contains("Hope that helps!"))
        } else {
            XCTFail("Expected prose segment at index 2")
        }
    }

    func testStreamingPartialCodeBlock() {
        let text = """
        Thinking about:
        ```python
        import math
        def circle(r):
        """

        let segments = MarkdownContentParser.parse(text)
        XCTAssertEqual(segments.count, 2)

        if case .codeBlock(_, let lang, let code) = segments[1] {
            XCTAssertEqual(lang, "python")
            XCTAssertTrue(code.contains("import math"))
        } else {
            XCTFail("Expected open code block to be parsed gracefully during streaming")
        }
    }

    func testMultipleInterleavedCodeBlocks() {
        let text = """
        First block:
        ```json
        {"status": "ok"}
        ```
        Second block:
        ```bash
        echo "done"
        ```
        """

        let segments = MarkdownContentParser.parse(text)
        XCTAssertEqual(segments.count, 4)

        if case .codeBlock(_, let lang1, _) = segments[1] {
            XCTAssertEqual(lang1, "json")
        }
        if case .codeBlock(_, let lang2, _) = segments[3] {
            XCTAssertEqual(lang2, "bash")
        }
    }
}

