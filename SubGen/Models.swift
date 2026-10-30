import Foundation

/// 1つの字幕セグメント（開始・終了時刻つきテキスト）
struct SubtitleSegment: Identifiable, Equatable {
    let id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var translatedText: String = ""

    var duration: TimeInterval { max(0, end - start) }
}

/// SRT書き出しのテキスト種別
enum SubtitleExportMode: String, CaseIterable, Identifiable {
    case original = "原文のみ"
    case translated = "翻訳のみ"
    case bilingual = "バイリンガル（原文＋翻訳）"

    var id: String { rawValue }
}

/// WhisperKit のモデル選択肢
struct ModelOption: Identifiable {
    let id: String // WhisperKit に渡すモデルフォルダ名
    let label: String
    let detail: String

    static let all: [ModelOption] = [
        ModelOption(
            id: "openai_whisper-large-v3-v20240930_626MB",
            label: "Large v3（高精度）",
            detail: "約626MB・日本語の精度が最も高い推奨モデル"
        ),
        ModelOption(
            id: "openai_whisper-small",
            label: "Small（バランス）",
            detail: "約460MB・精度と速度のバランス型"
        ),
        ModelOption(
            id: "openai_whisper-base",
            label: "Base（軽量）",
            detail: "約140MB・速いが精度は控えめ"
        ),
    ]

    static var defaultModelID: String { all[0].id }
}

/// エラー表示用ラッパー
struct DisplayError: Identifiable {
    let id = UUID()
    let message: String
}

/// "mm:ss.d" 形式の時刻表示
func formatTimestamp(_ t: TimeInterval) -> String {
    let clamped = max(0, t)
    let minutes = Int(clamped) / 60
    let seconds = Int(clamped) % 60
    let deci = Int((clamped - floor(clamped)) * 10)
    return String(format: "%02d:%02d.%d", minutes, seconds, deci)
}
