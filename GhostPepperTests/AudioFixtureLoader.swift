import AVFoundation
import Foundation

/// Loads a fixture recording and hands back exactly what the speech backends
/// expect: mono 16 kHz Float samples.
///
/// Andrew records in QuickTime, which produces 44.1 or 48 kHz stereo AAC. Every
/// backend in this project wants 16 kHz mono Float. Doing that conversion here,
/// once, is what lets the same clip be scored against four models without any
/// per-model preprocessing that could itself become a confound.
enum AudioFixtureLoader {

    enum LoadError: LocalizedError {
        case unreadable(URL, String)
        case converterUnavailable(URL)
        case empty(URL)

        var errorDescription: String? {
            switch self {
            case let .unreadable(url, detail):
                "Could not read \(url.lastPathComponent): \(detail)"
            case let .converterUnavailable(url):
                "Could not build an audio converter for \(url.lastPathComponent)"
            case let .empty(url):
                "\(url.lastPathComponent) decoded to zero samples"
            }
        }
    }

    static let targetSampleRate: Double = 16_000

    struct Fixture {
        let url: URL
        let samples: [Float]
        let duration: TimeInterval
        let sourceSampleRate: Double
        let sourceChannels: UInt32
        let sha256: String
    }

    static func load(_ url: URL) throws -> Fixture {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LoadError.unreadable(url, error.localizedDescription)
        }

        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw LoadError.converterUnavailable(url)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LoadError.converterUnavailable(url)
        }

        let sourceFrameCount = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw LoadError.converterUnavailable(url)
        }

        do {
            try file.read(into: inputBuffer)
        } catch {
            throw LoadError.unreadable(url, error.localizedDescription)
        }

        // Ratio plus a small margin: AVAudioConverter can emit slightly more
        // frames than the naive ratio predicts, and a short buffer truncates
        // the tail of the clip silently, which would look like a transcription
        // error rather than a loader bug.
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(sourceFrameCount) * ratio) + 4096

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: estimatedFrames
        ) else {
            throw LoadError.converterUnavailable(url)
        }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw LoadError.unreadable(url, conversionError.localizedDescription)
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw LoadError.empty(url)
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { throw LoadError.empty(url) }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        return Fixture(
            url: url,
            samples: samples,
            duration: Double(frameCount) / targetSampleRate,
            sourceSampleRate: sourceFormat.sampleRate,
            sourceChannels: sourceFormat.channelCount,
            sha256: try sha256OfFile(at: url)
        )
    }

    /// Hashes the source file rather than the decoded samples, because the
    /// manifest has to identify what Andrew recorded. LOOP.md makes any
    /// manifest hash change a human gate that invalidates every prior score, so
    /// this must be stable across runs and independent of decoding.
    static func sha256OfFile(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return output.split(separator: " ").first.map(String.init) ?? "unknown"
    }
}
