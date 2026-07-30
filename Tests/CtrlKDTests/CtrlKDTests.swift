import Testing
@testable import CtrlKD

@Test func lineJoinsMultipleSpanTexts() {
    let line = Line(spans: [
        Span(text: "Hello, "),
        Span(text: "world", styles: [.bold]),
        Span(text: "!"),
    ])
    #expect(line.text() == "Hello, world!")
}

@Test func blockDefaultsToParaAndHeadingZero() {
    let block = Block()
    #expect(block.kind == .para)
    #expect(block.heading == 0)
}
