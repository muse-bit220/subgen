import Accelerate
import AVFoundation
import Foundation

/// 動画・音声ファイルの音声情報（診断表示用）
struct AudioInfo {
    var duration: TimeInterval = 0
    var trackCount: Int = 0
    var codec: String = "不明"
    var channels: Int = 0
    var sampleRate: Double = 0
    /// 抽出音声のピークレベル（dB、無音は -120）
    var peakDB: Double = -120

    var isSilent: Bool { peakDB < -50 }

    /// 1行サマリ（例: 音声トラック 1件（AAC・2ch・48000Hz）／長さ 36.6秒・ピーク -3dB）
    var summary: String {
        var parts: [String] = []
        if trackCount == 0 {
            parts.append("音声トラックなし")
        } else {
            var detail = codec
            if channels > 0 { detail += "・\(channels)ch" }
            if sampleRate > 0 { detail += "・\(Int(sampleRate))Hz" }
            parts.append("音声トラック \(trackCount)件（\(detail)）")
        }
        if duration > 0 {
            parts.append(String(format: "長さ %.1f秒", duration))
        }
        if peakDB > -119 {
            parts.append("ピーク \(Int(peakDB.rounded()))dB")
        }
        return parts.joined(separator: "／")
    }
}

/// 動画ファイルから音声トラックだけを .m4a に抽出する（WhisperKit 入力用）
enum AudioExtractor {
    static func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractError.sessionUnavailable
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        await session.export()

        switch session.status {
        case .completed:
            return outputURL
        default:
            if let error = session.error { throw error }
            throw AudioExtractError.exportFailed
        }
    }

    /// 元動画の音声トラック情報（長さ・形式）を取得する
    static func inspectSource(url: URL) async -> AudioInfo {
        var info = AudioInfo()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            info.duration = duration.seconds
        }
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        info.trackCount = tracks.count
        if let track = tracks.first,
           let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first {
            info.codec = friendlyCodecName(CMFormatDescriptionGetMediaSubType(description))
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                info.channels = Int(asbd.mChannelsPerFrame)
                info.sampleRate = asbd.mSampleRate
            }
        }
        return info
    }

    /// 抽出した音声ファイルの長さとピークレベルを測る（無音かどうかの判定用）
    static func inspectExtracted(url: URL) async -> AudioInfo {
        var info = AudioInfo()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            info.duration = duration.seconds
        }
        guard let file = try? AVAudioFile(forReading: url) else { return info }
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return info }
        var peak: Float = 0
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: capacity)
            } catch {
                break
            }
            guard let channelData = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            for channel in 0 ..< Int(format.channelCount) {
                var maxMagnitude: Float = 0
                vDSP_maxmgv(channelData[channel], 1, &maxMagnitude, vDSP_Length(frames))
                if maxMagnitude > peak { peak = maxMagnitude }
            }
        }
        info.peakDB = peak > 0 ? Double(20 * log10(peak)) : -120
        return info
    }

    private static func friendlyCodecName(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatLinearPCM: return "リニアPCM"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatMPEG4AAC_HE: return "HE-AAC"
        case kAudioFormatOpus: return "Opus"
        default:
            let bytes: [UInt8] = [
                UInt8((subtype >> 24) & 0xff),
                UInt8((subtype >> 16) & 0xff),
                UInt8((subtype >> 8) & 0xff),
                UInt8(subtype & 0xff),
            ]
            let text = String(bytes: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return text.isEmpty ? "不明" : text
        }
    }

    enum AudioExtractError: LocalizedError {
        case sessionUnavailable
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                return "音声抽出セッションを作成できませんでした"
            case .exportFailed:
                return "音声の抽出に失敗しました"
            }
        }
    }
}
