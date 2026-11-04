// Converts AVSpeechSynthesizer's buffers to the PCM the rest of OpenClicky expects.
// Channel layout per AVAudioBuffer.h: `floatChannelData` (and the int16/int32 variants) holds one pointer per
// channel, each to `frameLength` samples spaced by `stride`.

import AVFAudio
import Foundation

extension AppleSpeechSynthesisClient {
    /// Mono, 16-bit, little-endian PCM at the buffer's own sample rate. Float samples are clipped to [-1, 1], scaled
    /// by 32767 (so ±1.0 map to ±32767 symmetrically) and rounded to nearest, halves away from zero. Several channels
    /// are averaged into one before that.
    enum PCM16 {
        /// One float sample as a 16-bit sample. NaN is silence; infinities clip.
        static func sample(_ value: Float) -> Int16 {
            guard !value.isNaN else { return 0 }
            let clipped = min(max(value, -1), 1)
            return Int16((clipped * 32767).rounded(.toNearestOrAwayFromZero))
        }

        /// Nil when the buffer is not Float32, Int16 or Int32 PCM, or has no channels or no sample rate.
        static func monoData(from buffer: AVAudioPCMBuffer) -> (Data, PCMFormat)? {
            let format = buffer.format
            let channels = Int(format.channelCount)
            let sampleRate = Int(format.sampleRate.rounded())
            guard channels > 0, sampleRate > 0 else { return nil }
            let frames = Int(buffer.frameLength)
            let stride = buffer.stride
            let pcmFormat = PCMFormat(sampleRate: sampleRate)

            switch format.commonFormat {
            case .pcmFormatFloat32:
                guard let planes = buffer.floatChannelData else { return nil }
                return (render(frames: frames) { frame in
                    var sum: Float = 0
                    for channel in 0..<channels { sum += planes[channel][frame * stride] }
                    return sample(sum / Float(channels))
                }, pcmFormat)
            case .pcmFormatInt16:
                guard let planes = buffer.int16ChannelData else { return nil }
                return (render(frames: frames) { frame in
                    if channels == 1 { return planes[0][frame * stride] }
                    var sum = 0
                    for channel in 0..<channels { sum += Int(planes[channel][frame * stride]) }
                    return Int16((Double(sum) / Double(channels)).rounded(.toNearestOrAwayFromZero))
                }, pcmFormat)
            case .pcmFormatInt32:
                guard let planes = buffer.int32ChannelData else { return nil }
                return (render(frames: frames) { frame in
                    var sum = 0.0
                    for channel in 0..<channels { sum += Double(planes[channel][frame * stride]) / 2_147_483_648 }
                    return sample(Float(sum / Double(channels)))
                }, pcmFormat)
            default:
                return nil
            }
        }

        private static func render(frames: Int, sampleAt: (Int) -> Int16) -> Data {
            var data = Data(count: frames * 2)
            data.withUnsafeMutableBytes { raw in
                for frame in 0..<frames {
                    raw.storeBytes(of: sampleAt(frame).littleEndian, toByteOffset: frame * 2, as: Int16.self)
                }
            }
            return data
        }
    }
}
