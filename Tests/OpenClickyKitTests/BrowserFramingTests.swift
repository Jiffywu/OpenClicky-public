import Foundation
import Testing
@testable import OpenClickyKit

@Test func framingPrefixesLittleEndianLength() throws {
    let framed = try NativeMessageFraming.frame(["type": "hello"])
    let body = Data(#"{"type":"hello"}"#.utf8)
    #expect(framed.count == 4 + body.count)
    #expect(Array(framed.prefix(4)) == [UInt8(body.count), 0, 0, 0])
    #expect(framed.dropFirst(4) == body)

    let big = NativeMessageFraming.header(for: 0x0102_0304)
    #expect(Array(big) == [0x04, 0x03, 0x02, 0x01])
    #expect(NativeMessageFraming.length(of: big) == 0x0102_0304)
}

@Test(arguments: [1, 2, 3, 5, 17, 4096])
func decoderReassemblesMessagesFromAnyChunking(chunkSize: Int) throws {
    let messages: [JSONValue] = [
        ["type": "hello", "protocol": 1, "profileId": "8a6e0c55-3f1b-4f7a-9d44-0b1c2d3e4f50"],
        ["type": "result", "id": "x", "ok": true, "result": ["text": .string(String(repeating: "é", count: 300))]],
        ["type": "pong"],
    ]
    let stream = try messages.map { try NativeMessageFraming.frame($0) }.reduce(Data(), +)
    var decoder = NativeMessageDecoder()
    var decoded: [JSONValue] = []
    var offset = 0
    while offset < stream.count {
        let end = min(offset + chunkSize, stream.count)
        decoded += try decoder.feedMessages(stream[offset..<end])
        offset = end
    }
    #expect(decoded == messages)
    #expect(decoder.pendingByteCount == 0)
}

@Test func decoderHoldsAPartialMessageUntilItCompletes() throws {
    let framed = try NativeMessageFraming.frame(["type": "ready", "app": true])
    var decoder = NativeMessageDecoder()
    #expect(try decoder.feed(framed.prefix(3)).isEmpty)
    #expect(try decoder.feed(framed.dropFirst(3).prefix(6)).isEmpty)
    #expect(decoder.pendingByteCount == 9)
    let bodies = try decoder.feed(framed.dropFirst(9))
    #expect(bodies.count == 1)
    #expect(try NativeMessageFraming.decode(bodies[0])["app"] == true)
}

@Test func decoderRejectsOversizeLengthsBeforeBuffering() {
    var decoder = NativeMessageDecoder(limit: 1024)
    #expect(throws: NativeMessageFraming.Error.tooLarge(2048, limit: 1024)) {
        _ = try decoder.feed(NativeMessageFraming.header(for: 2048) + Data("{".utf8))
    }
}

@Test func framingRefusesToWriteOverTheLimit() {
    let body = Data(repeating: 0x20, count: NativeMessageFraming.maxToExtension + 1)
    #expect(throws: NativeMessageFraming.Error.self) {
        _ = try NativeMessageFraming.frame(body, limit: NativeMessageFraming.maxToExtension)
    }
}

@Test func nativeMessagesMustBeJSONObjects() {
    #expect(throws: NativeMessageFraming.Error.notAnObject) { _ = try NativeMessageFraming.decode(Data("[1,2]".utf8)) }
    #expect(throws: NativeMessageFraming.Error.invalidJSON) { _ = try NativeMessageFraming.decode(Data("{nope".utf8)) }
}

@Test func framedChannelRoundTripsOverAPipe() throws {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    let writer = FramedChannel(readFD: fds[1], writeFD: fds[1], ownsDescriptors: true)
    let reader = FramedChannel(readFD: fds[0], writeFD: fds[0], ownsDescriptors: true)
    try writer.write(["n": 1])
    try writer.write(["n": 2])
    writer.close()
    #expect(try reader.read()?["n"] == 1)
    #expect(try reader.read()?["n"] == 2)
    #expect(try reader.read() == nil)
    reader.close()
}
