import Foundation

// The bytes OpenAITranscriptionClient uploads: buffered PCM wrapped as a WAV file inside a multipart/form-data
// body. Nested in the client type so other adapters' helpers can't collide with these names.

extension OpenAITranscriptionClient {
    /// One text part of the form, e.g. `model` or `keywords[]`.
    struct FormField: Sendable, Hashable {
        var name: String
        var value: String

        init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Canonical 44-byte RIFF/WAVE header + 16-bit little-endian PCM.
    enum WAV {
        static func wrap(_ pcm: Data, format: PCMFormat) -> Data {
            let channels = max(format.channels, 1)
            let blockAlign = channels * 2
            // A capture chunk can split a sample; drop a trailing partial frame so the data chunk stays aligned.
            let usable = pcm.count - pcm.count % blockAlign
            var wav = Data(capacity: 44 + usable)
            wav.append(contentsOf: Array("RIFF".utf8))
            wav.appendLittleEndian(UInt32(36 + usable))
            wav.append(contentsOf: Array("WAVE".utf8))
            wav.append(contentsOf: Array("fmt ".utf8))
            wav.appendLittleEndian(UInt32(16))  // fmt chunk size for PCM
            wav.appendLittleEndian(UInt16(1))  // format tag: integer PCM
            wav.appendLittleEndian(UInt16(channels))
            wav.appendLittleEndian(UInt32(format.sampleRate))
            wav.appendLittleEndian(UInt32(format.sampleRate * blockAlign))  // byte rate
            wav.appendLittleEndian(UInt16(blockAlign))
            wav.appendLittleEndian(UInt16(16))  // bits per sample
            wav.append(contentsOf: Array("data".utf8))
            wav.appendLittleEndian(UInt32(usable))
            wav.append(pcm.prefix(usable))
            return wav
        }
    }

    /// multipart/form-data per RFC 7578: text fields first, the file last, CRLF line endings.
    enum Multipart {
        static let fileName = "audio.wav"
        static let fileContentType = "audio/wav"

        /// A boundary that appears nowhere in the parts (a UUID collision with audio bytes is astronomically
        /// unlikely, but checking is cheap).
        static func boundary(avoiding fields: [FormField], file: Data) -> String {
            while true {
                let candidate = "OpenClicky-\(UUID().uuidString)"
                let marker = Data(candidate.utf8)
                if file.range(of: marker) == nil, !fields.contains(where: { $0.value.contains(candidate) }) {
                    return candidate
                }
            }
        }

        static func body(fields: [FormField], file: Data, boundary: String) -> Data {
            var body = Data()
            func line(_ text: String) { body.append(contentsOf: Array("\(text)\r\n".utf8)) }
            for field in fields {
                line("--\(boundary)")
                line("Content-Disposition: form-data; name=\"\(field.name)\"")
                line("")
                line(field.value)
            }
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"")
            line("Content-Type: \(fileContentType)")
            line("")
            body.append(file)
            line("")
            line("--\(boundary)--")
            return body
        }
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
