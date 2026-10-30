import Foundation
import UIKit
import WhisperKit

/// ダウンロード進捗をスレッドセーフに受け渡すための箱（ProgressCallback は @Sendable のため）
final class DownloadProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double = 0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func update(_ newValue: Double) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}

/// WhisperKit を使った文字起こしの管理（モデル準備 → 音声抽出 → 文字起こし）
/// モデル準備は「明示ダウンロード（進捗つき・背景セッション）→ ローカルから初期化」に分け、
/// 通信タイムアウト時は自動で最大3回までリトライする。
@MainActor
final class TranscriptionManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparingModel
        case extractingAudio
        case transcribing
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// モデルダウンロードの進捗（0.0〜1.0）。ダウンロードが不要な場合は nil
    @Published private(set) var downloadProgress: Double?
    /// モデルダウンロードの試行回数（1始まり）。リトライ中のみ意味を持つ
    @Published private(set) var downloadAttempt: Int = 1

    private var whisperKit: WhisperKit?
    private var loadedModelID: String?

    private static let maxDownloadAttempts = 3

    /// モデルの保存先（v1.2で変更。以前の保存先に不完全なデータが残っていても影響を受けないよう、
    /// アプリ専用フォルダへ取り直す）
    private static var modelDownloadBase: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("SubGenModels", isDirectory: true)
    }

    /// Whisper の制御トークン（<|...|>）をテキストから除去する
    private static func cleanText(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "<\\|.*?\\|>",
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBusy: Bool {
        switch phase {
        case .preparingModel, .extractingAudio, .transcribing:
            return true
        default:
            return false
        }
    }

    /// 動画ファイルから字幕セグメント列を生成する
    /// - Parameters:
    ///   - videoURL: 動画ファイル
    ///   - modelID: WhisperKit のモデルフォルダ名
    ///   - language: 言語コード（"ja" / "en"）。nil なら自動検出
    func transcribe(videoURL: URL, modelID: String, language: String?) async throws -> [SubtitleSegment] {
        // ダウンロード／文字起こし中に画面がロックされて処理が止まらないようにする
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            if whisperKit == nil || loadedModelID != modelID {
                phase = .preparingModel
                whisperKit = try await prepareModel(modelID: modelID)
                loadedModelID = modelID
            }
            guard let whisperKit else {
                throw TranscriptionError.modelUnavailable
            }

            phase = .extractingAudio
            let audioURL = try await AudioExtractor.extractAudio(from: videoURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            phase = .transcribing
            // skipSpecialTokens を有効にしないと <|startoftranscript|> 等の制御トークンが
            // セグメントのテキストに混ざってしまう（DecodingOptions の既定は false）
            let options: DecodingOptions
            if let language {
                options = DecodingOptions(task: .transcribe, language: language, skipSpecialTokens: true)
            } else {
                options = DecodingOptions(task: .transcribe, skipSpecialTokens: true)
            }
            let results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)

            let segments = (results ?? [])
                .flatMap { $0.segments }
                .map {
                    SubtitleSegment(
                        start: TimeInterval($0.start),
                        end: TimeInterval($0.end),
                        text: Self.cleanText($0.text)
                    )
                }
                .filter { !$0.text.isEmpty && $0.end > $0.start }

            phase = .done
            return segments
        } catch let error as TranscriptionError {
            phase = .failed(error.localizedDescription)
            throw error
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// モデルをダウンロードして WhisperKit を初期化する（タイムアウト時は自動リトライ）
    private func prepareModel(modelID: String) async throws -> WhisperKit {
        var lastError: Error?
        for attempt in 1 ... Self.maxDownloadAttempts {
            downloadAttempt = attempt
            downloadProgress = nil
            do {
                let folder = try await downloadModel(modelID: modelID)
                downloadProgress = nil
                let config = WhisperKitConfig(
                    downloadBase: Self.modelDownloadBase,
                    modelFolder: folder.path,
                    useBackgroundDownloadSession: true
                )
                return try await WhisperKit(config)
            } catch {
                lastError = error
                if attempt < Self.maxDownloadAttempts {
                    // 少し待ってから再試行する（ダウンロード済みのファイルは再利用される）
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                }
            }
        }
        downloadProgress = nil
        throw TranscriptionError.friendly(from: lastError)
    }

    /// WhisperKit.download でモデル本体を取得し、進捗を公開する
    private func downloadModel(modelID: String) async throws -> URL {
        let box = DownloadProgressBox()
        // 進捗のポーリング（メインアクター上で UI 用プロパティへ反映）
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.downloadProgress = box.value
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { poller.cancel() }
        let folder = try await WhisperKit.download(
            variant: modelID,
            downloadBase: Self.modelDownloadBase,
            useBackgroundSession: true,
            progressCallback: { progress in
                box.update(progress.fractionCompleted)
            }
        )
        downloadProgress = box.value
        return folder
    }

    enum TranscriptionError: LocalizedError {
        case modelUnavailable
        case message(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "音声認識モデルを準備できませんでした"
            case .message(let text):
                return text
            }
        }

        /// WhisperKit が包んで返す巨大な英語エラーを、原因に応じた短い日本語に変換する
        static func friendly(from error: Error?) -> TranscriptionError {
            guard let error else { return .modelUnavailable }
            let nsError = error as NSError
            var codes: [Int] = []
            var current: NSError? = nsError
            while let c = current {
                codes.append(c.code)
                if c.domain == NSURLErrorDomain { codes.append(c.code) }
                current = c.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            let text = "\(error.localizedDescription) \(nsError.userInfo)"
            let lowered = text.lowercased()
            if codes.contains(NSURLErrorTimedOut) || lowered.contains("timed out") || text.contains("-1001") {
                return .message("モデルのダウンロードがタイムアウトしました（自動で3回試行済み）。電波の良いWi-Fiで、アプリを開いたままもう一度お試しください。何度も失敗する場合は、設定で軽量な「Base」モデルに切り替えると成功しやすくなります。")
            }
            if codes.contains(NSURLErrorNotConnectedToInternet) || codes.contains(NSURLErrorNetworkConnectionLost) {
                return .message("インターネットに接続できませんでした。Wi-Fiの接続を確認して、もう一度お試しください。モデルのダウンロードは初回のみ必要です。")
            }
            return .message("モデルを準備できませんでした。通信環境を確認して、もう一度お試しください。何度も失敗する場合は、設定で軽量な「Base」モデルもお試しください。")
        }
    }
}
