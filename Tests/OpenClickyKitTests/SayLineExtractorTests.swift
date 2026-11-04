import Testing
@testable import OpenClickyKit

private func extract(_ program: String, chunk: Int) -> [SayLineExtractor.Line] {
    var extractor = SayLineExtractor()
    var lines: [SayLineExtractor.Line] = []
    var index = program.startIndex
    while index < program.endIndex {
        let end = program.index(index, offsetBy: chunk, limitedBy: program.endIndex) ?? program.endIndex
        lines += extractor.feed(String(program[index..<end]))
        index = end
    }
    return lines
}

private let program = """
```js
step(1);
say("I generate graphics as we talk, like this gyroscope.");
const f = figure(660, 183, 550, 390, {title: "Live \\"gyro\\""});
// say("not spoken: in a comment")
/* say('also not spoken') */
const note = "say(\\"inside another string\\")";
essay("not a say call"); obj.say("member call, skip");
say( 'It\\'s built piece by piece.' );
say(`Drag it to look around.`);
say(`Value is ${x}`);
say(dynamicText);
say("Read more at [the docs](https://example.com/docs) or https://example.com.");
say("caf\\u00e9 and \\u{1F600}");
```
"""

@Test(arguments: [1, 2, 3, 7, 64, 10_000])
func extractsSayLinesAtAnyChunkSize(chunk: Int) {
    let lines = extract(program, chunk: chunk)
    #expect(lines.map(\.text) == [
        "I generate graphics as we talk, like this gyroscope.",
        "It's built piece by piece.",
        "Drag it to look around.",
        "Read more at the docs or.",
        "café and 😀",
    ])
    #expect(lines.map(\.index) == [0, 1, 2, 3, 4])
    #expect(lines[3].raw.contains("https://example.com/docs"))
}

@Test func emitsALineAsSoonAsItsQuoteCloses() {
    var extractor = SayLineExtractor()
    #expect(extractor.feed("say(\"Hello the").isEmpty)
    let lines = extractor.feed("re\"")
    #expect(lines.map(\.text) == ["Hello there"])
    #expect(extractor.feed(");\nline(1,2,3,4);").isEmpty)
}

@Test func ignoresEmptyLines() {
    #expect(extract("say(\"  \"); say('ok')", chunk: 4).map(\.text) == ["ok"])
}

@Test func speakableRemovesLinksAndURLs() {
    #expect(SayLineExtractor.speakable("See [this guide](http://x.y/z) now") == "See this guide now")
    #expect(SayLineExtractor.speakable("Go to www.example.com for more") == "Go to for more")
}
