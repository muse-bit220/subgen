import AVFoundation
import Foundation

/// 無音区間を検出して詰めた動画を書き出す（Vrewの「無音部分を短縮」に相当）
enum SilenceCutter {

    /// 無音カットの強さ（しきい値と最小無音長さのプリセット）
    enum Strength: String, CaseIterable, Identifiable {
        case gentle = "弱め"
        case standard = "標準"
        case strong = "強め"

        var id: String { rawValue }

        /// これより小さい音量を無音とみなす（dB）
        var thresholdDB: Float {
            switch self {
            case .gentle: return -50
            case .standard: return -45
            case .strong: return -40
            }
        }

        /// この長さ以上の無音だけをカットの対象にする（秒）
        var minSilence: TimeInterval {
            switch self {
            case .gentle: return 0.8
            case .standard: return 0.5
            case .strong: return 0.3
            }
        }
    }

    struct Result {
        var outputURL: URL
        var originalDuration: TimeInterval
        var newDuration: TimeInterval
        var keepRanges: [CMTimeRange]
        var removedDuration: TimeInterval { originalDuration - newDuration }
    }

    // MARK: - 無音検出

    /// 音声ファイルから「残す区間（発話区間）」を求める
    /// - Parameters:
    ///   - audioURL: 解析する音声ファイル（.m4a 等）
    ///   - strength: 強さプリセット
    ///   - margin: 発話の前後に残す余白（秒）。言葉の頭と尻尾を切らないため
    static func speechRanges(
        audioURL: URL,
        strength: Strength,
        margin: TimeInterval = 0.12
    ) throws -> (ranges: [CMTimeRange], duration: TimeInterval) {
        guard let file = try? AVAudioFile(forReading: audioURL) else {
            throw SilenceCutError.audioReadFailed
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            throw SilenceCutError.audioReadFailed
        }
        let duration = TimeInterval(file.length) / sampleRate

        // 0.05秒ごとの音量（RMS・dB）を測る
        let windowSeconds = 0.05
        let windowFrames = max(1, Int(sampleRate * windowSeconds))
        let chunkFrames: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw SilenceCutError.audioReadFailed
        }
        var windowDB: [Float] = []
        var windowSumSquares: Double = 0
        var windowSampleCount = 0

        func flushWindow() {
            guard windowSampleCount > 0 else { return }
            let rms = sqrt(windowSumSquares / Double(windowSampleCount))
            windowDB.append(rms > 0 ? Float(20 * log10(rms)) : -120)
            windowSumSquares = 0
            windowSampleCount = 0
        }

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            let channels = max(1, Int(format.channelCount))
            for frame in 0 ..< frames {
                var sum: Float = 0
                for channel in 0 ..< channels {
                    let value = channelData[channel][frame]
                    sum += value * value
                }
                windowSumSquares += Double(sum) / Double(channels)
                windowSampleCount += 1
                if windowSampleCount >= windowFrames { flushWindow() }
            }
        }
        flushWindow()
        guard !windowDB.isEmpty else { throw SilenceCutError.audioReadFailed }

        // 無音の連続区間（minSilence以上）を求める
        let threshold = strength.thresholdDB
        var silenceIntervals: [(start: TimeInterval, end: TimeInterval)] = []
        var silentRunStart: Int?
        for index in windowDB.indices {
            if windowDB[index] < threshold {
                if silentRunStart == nil { silentRunStart = index }
            } else if let runStart = silentRunStart {
                let start = TimeInterval(runStart) * windowSeconds
                let end = TimeInterval(index) * windowSeconds
                if end - start >= strength.minSilence {
                    silenceIntervals.append((start, end))
                }
                silentRunStart = nil
            }
        }
        if let runStart = silentRunStart {
            let start = TimeInterval(runStart) * windowSeconds
            if duration - start >= strength.minSilence {
                silenceIntervals.append((start, duration))
            }
        }

        // 発話区間 = 全体 − 無音区間。前後に余白を付けてから重なりをまとめる
        var speech: [(start: TimeInterval, end: TimeInterval)] = []
        var cursor: TimeInterval = 0
        for silence in silenceIntervals {
            if silence.start > cursor {
                speech.append((cursor, silence.start))
            }
            cursor = max(cursor, silence.end)
        }
        if cursor < duration {
            speech.append((cursor, duration))
        }
        guard !speech.isEmpty else { throw SilenceCutError.noSpeech }

        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for interval in speech {
            let expanded = (
                start: max(0, interval.start - margin),
                end: min(duration, interval.end + margin)
            )
            if var last = merged.last, expanded.start <= last.end {
                last.end = max(last.end, expanded.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(expanded)
            }
        }

        let ranges = merged.map {
            CMTimeRange(
                start: CMTime(seconds: $0.start, preferredTimescale: 600),
                end: CMTime(seconds: $0.end, preferredTimescale: 600)
            )
        }
        return (ranges, duration)
    }

    // MARK: - 書き出し

    /// 動画の無音を詰めた新しい動画を書き出す
    static func exportCutVideo(videoURL: URL, strength: Strength) async throws -> Result {
        let sourceInfo = await AudioExtractor.inspectSource(url: videoURL)
        guard sourceInfo.trackCount > 0 else {
            throw SilenceCutError.noAudioTrack
        }

        let audioURL = try await AudioExtractor.extractAudio(from: videoURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let (keepRanges, _) = try speechRanges(audioURL: audioURL, strength: strength)

        let asset = AVURLAsset(url: videoURL)
        let originalDuration = try await asset.load(.duration).seconds
        let keptDuration = keepRanges.reduce(0) { $0 + $1.duration.seconds }
        guard originalDuration - keptDuration >= 0.5 else {
            throw SilenceCutError.noSilenceFound
        }

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw SilenceCutError.noVideoTrack
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SilenceCutError.exportFailed
        }
        let compAudio = sourceAudio == nil ? nil : composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursorTime = CMTime.zero
        for range in keepRanges {
            try compVideo.insertTimeRange(range, of: sourceVideo, at: cursorTime)
            if let sourceAudio, let compAudio {
                try compAudio.insertTimeRange(range, of: sourceAudio, at: cursorTime)
            }
            cursorTime = CMTimeAdd(cursorTime, range.duration)
        }
        compVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("silencecut-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw SilenceCutError.exportFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else {
            if let error = session.error { throw error }
            throw SilenceCutError.exportFailed
        }

        return Result(
            outputURL: outputURL,
            originalDuration: originalDuration,
            newDuration: cursorTime.seconds,
            keepRanges: keepRanges
        )
    }

    // MARK: - 時刻変換

    /// 元動画の時刻を、カット後の動画の時刻へ変換する
    static func mapTime(_ time: TimeInterval, keepRanges: [CMTimeRange]) -> TimeInterval {
        var newTime: TimeInterval = 0
        for range in keepRanges {
            let start = range.start.seconds
            let end = range.end.seconds
            if time <= start {
                return newTime
            }
            if time < end {
                return newTime + (time - start)
            }
            newTime += end - start
        }
        return newTime
    }

    /// 字幕セグメント列をカット後のタイミングへ変換する（カットで消えた字幕は除く）
    static func remapSegments(
        _ segments: [SubtitleSegment],
        keepRanges: [CMTimeRange]
    ) -> [SubtitleSegment] {
        segments.compactMap { segment in
            let newStart = mapTime(segment.start, keepRanges: keepRanges)
            let newEnd = mapTime(segment.end, keepRanges: keepRanges)
            guard newEnd - newStart >= 0.05 else { return nil }
            return SubtitleSegment(
                start: newStart,
                end: newEnd,
                text: segment.text,
                translatedText: segment.translatedText
            )
        }
    }

    enum SilenceCutError: LocalizedError {
        case noAudioTrack
        case noSpeech
        case noSilenceFound
        case noVideoTrack
        case audioReadFailed
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "この動画には音声トラックがありません"
            case .noSpeech:
                return "声の区間が見つかりませんでした（全体が無音の可能性があります）"
            case .noSilenceFound:
                return "目立つ無音区間は見つかりませんでした"
            case .noVideoTrack:
                return "動画トラックが見つかりませんでした"
            case .audioReadFailed:
                return "音声の解析に失敗しました"
            case .exportFailed:
                return "無音カット動画の書き出しに失敗しました"
            }
        }
    }
}
