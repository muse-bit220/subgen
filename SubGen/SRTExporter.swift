import Foundation

/// 字幕セグメント列から SRT 形式の文字列を作る
enum SRTExporter {
    static func makeSRT(segments: [SubtitleSegment], mode: SubtitleExportMode) -> String {
        var blocks: [String] = []
        for (index, segment) in segments.enumerated() {
            let text: String
            switch mode {
            case .original:
                text = segment.text
            case .translated:
                text = segment.translatedText.isEmpty ? segment.text : segment.translatedText
            case .bilingual:
                text = segment.translatedText.isEmpty
                    ? segment.text
                    : segment.text + "\n" + segment.translatedText
            }
            blocks.append("""
            \(index + 1)
            \(srtTimestamp(segment.start)) --> \(srtTimestamp(segment.end))
            \(text)
            """)
        }
        // Windows系プレイヤー互換のため BOM を付ける
        return "\u{FEFF}" + blocks.joined(separator: "\n\n") + "\n"
    }

    /// "HH:MM:SS,mmm" 形式
    static func srtTimestamp(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let seconds = Int(clamped) % 60
        let millis = Int((clamped - floor(clamped)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}
