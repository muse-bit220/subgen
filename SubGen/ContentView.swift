import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var transcriber = TranscriptionManager()

    // 動画とプレイヤー
    @State private var videoURL: URL?
    @State private var videoName = ""
    @State private var player: AVPlayer?

    // プレビューの字幕オーバーレイ（再生位置を定期的に取得する）
    @State private var currentPlaybackTime: TimeInterval = 0
    private let playbackTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    // ピッカー
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false

    // 文字起こし設定
    @State private var selectedModelID = ModelOption.defaultModelID
    @State private var languageChoice = "ja" // auto / ja / en（誤検出防止のため既定は日本語）

    // 字幕
    @State private var segments: [SubtitleSegment] = []

    // 翻訳
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translateSource = "en" // en: 英語→日本語 / ja: 日本語→英語
    @State private var isTranslating = false

    // 焼き込み
    @State private var burnInMode: SubtitleExportMode = .original
    @State private var isBurningIn = false

    // 無音カット
    @State private var silenceCutEnabled = false // 無音カットする／しない（既定は「しない」）
    @State private var silenceStrength: SilenceCutter.Strength = .standard
    @State private var isCuttingSilence = false
    @State private var applyCutToSubtitles = true
    @State private var cutSummary: String?

    // 共有・エラー
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var displayError: DisplayError?

    var body: some View {
        NavigationStack {
            List {
                videoSection
                settingsSection
                generateSection
                if videoURL != nil {
                    segmentsSection
                }
                if !segments.isEmpty {
                    translateSection
                    exportSection
                    silenceCutSection
                }
            }
            .navigationTitle("SubGen 字幕")
        }
        .onReceive(playbackTimer) { _ in
            if let seconds = player?.currentTime().seconds, seconds.isFinite {
                currentPlaybackTime = seconds
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .videos)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhotoItem(item) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        ) { result in
            handleFileImport(result)
        }
        .translationTask(translationConfig) { session in
            await performTranslation(session: session)
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ActivityView(items: [shareURL])
                    .ignoresSafeArea()
            }
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { displayError != nil },
                set: { if !$0 { displayError = nil } }
            ),
            presenting: displayError
        ) { _ in
            Button("OK") { displayError = nil }
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: - セクション

    private var videoSection: some View {
        Section("動画") {
            if let player {
                ZStack(alignment: .bottom) {
                    VideoPlayer(player: player)
                        .frame(height: 220)
                    if let active = activeSegment {
                        VStack(spacing: 2) {
                            Text(active.text)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            if !active.translatedText.isEmpty {
                                Text(active.translatedText)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(8)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
                .listRowInsets(EdgeInsets())
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("写真ライブラリから選ぶ", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("ファイルから選ぶ", systemImage: "folder")
            }
            if !videoName.isEmpty {
                Text(videoName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsSection: some View {
        Section("設定") {
            Picker("モデル", selection: $selectedModelID) {
                ForEach(ModelOption.all) { option in
                    Text(option.label).tag(option.id)
                }
            }
            if let current = ModelOption.all.first(where: { $0.id == selectedModelID }) {
                Text(current.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("動画の言語")
                Picker("動画の言語", selection: $languageChoice) {
                    Text("自動検出").tag("auto")
                    Text("日本語").tag("ja")
                    Text("英語").tag("en")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("モデルは初回使用時に自動でダウンロードされます（約140MB〜626MB）。Wi-Fi接続で、画面をつけたままお待ちください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var generateSection: some View {
        Section {
            Button {
                runTranscription()
            } label: {
                HStack {
                    Spacer()
                    Text("字幕を生成").bold()
                    Spacer()
                }
            }
            .disabled(videoURL == nil || transcriber.isBusy)

            if transcriber.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(phaseText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if transcriber.phase == .preparingModel, let progress = transcriber.downloadProgress {
                        ProgressView(value: progress)
                    }
                }
            } else if transcriber.phase == .done && !segments.isEmpty {
                Label("生成が完了しました", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if !transcriber.lastAudioSummary.isEmpty {
                Text("音声チェック: \(transcriber.lastAudioSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var translateSection: some View {
        Section("翻訳") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("翻訳の向き", selection: $translateSource) {
                    Text("英語 → 日本語").tag("en")
                    Text("日本語 → 英語").tag("ja")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Button {
                requestTranslation()
            } label: {
                HStack {
                    Spacer()
                    if isTranslating {
                        ProgressView()
                    } else {
                        Text("字幕を翻訳").bold()
                    }
                    Spacer()
                }
            }
            .disabled(isTranslating)
            Text("端末上の翻訳機能を使います。初回は言語データのダウンロードを求められる場合があります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var exportSection: some View {
        Section("書き出し") {
            Menu {
                ForEach(SubtitleExportMode.allCases) { mode in
                    Button(mode.rawValue) { exportSRT(mode: mode) }
                }
            } label: {
                Label("SRTファイルを書き出す", systemImage: "doc.text")
            }

            Picker("焼き込む字幕", selection: $burnInMode) {
                ForEach(SubtitleExportMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            Button {
                runBurnIn()
            } label: {
                HStack {
                    if isBurningIn {
                        ProgressView()
                    }
                    Label("字幕を焼き込んだ動画を書き出す", systemImage: "film")
                }
            }
            .disabled(isBurningIn)
            Text(silenceCutEnabled
                ? "焼き込みには無音カット「する（\(silenceStrength.rawValue)）」が適用されます"
                : "無音カットはしません（元の動画に焼き込みます）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var silenceCutSection: some View {
        Section("無音カット") {
            Picker("無音カット", selection: $silenceCutEnabled) {
                Text("しない").tag(false)
                Text("する").tag(true)
            }
            .pickerStyle(.segmented)

            if silenceCutEnabled {
                Text("声のない区間を検出して詰めた動画を書き出します。Vrewの「無音部分を短縮」と同じ発想です。この「する」の選択は、字幕の焼き込み書き出しにも適用されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("強さ", selection: $silenceStrength) {
                    ForEach(SilenceCutter.Strength.allCases) { strength in
                        Text(strength.rawValue).tag(strength)
                    }
                }
                Toggle("字幕のタイミングもカット後に合わせる", isOn: $applyCutToSubtitles)
                Button {
                    runSilenceCut()
                } label: {
                    HStack {
                        if isCuttingSilence {
                            ProgressView()
                        }
                        Label("無音カットした動画を書き出す", systemImage: "scissors")
                    }
                }
                .disabled(isCuttingSilence)
                if let cutSummary {
                    Text(cutSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if applyCutToSubtitles {
                    Text("字幕を合わせると、この画面のプレビュー（元の動画）とはタイミングが合わなくなります。カット後の動画用の字幕になります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("「する」を選ぶと、無音を詰めた動画を書き出したり、字幕の焼き込みに無音カットを適用したりできます。「しない」の間は、今までどおり元の動画のまま書き出します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var segmentsSection: some View {
        Section("字幕（\(segments.count)件）") {
            Button {
                addSegmentAtCurrentTime()
            } label: {
                Label("字幕を追加（現在の再生位置から）", systemImage: "plus.circle")
            }

            if segments.isEmpty {
                Text("字幕はまだありません。自動生成するか、「字幕を追加」で手動で作れます。文章と開始・終了の秒数はタップして編集できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($segments) { $segment in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        seek(to: segment.start)
                    } label: {
                        Text("\(formatTimestamp(segment.start)) → \(formatTimestamp(segment.end))")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)

                    TextField("字幕を入力", text: $segment.text, axis: .vertical)
                        .lineLimit(1 ... 4)

                    HStack(spacing: 6) {
                        Text("開始")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("開始秒", value: $segment.start, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Text("秒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("再生位置に") {
                            var updated = segment
                            updated.start = currentPlayerTime()
                            $segment.wrappedValue = updated
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    HStack(spacing: 6) {
                        Text("終了")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("終了秒", value: $segment.end, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Text("秒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("再生位置に") {
                            var updated = segment
                            updated.end = currentPlayerTime()
                            $segment.wrappedValue = updated
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if !segment.translatedText.isEmpty {
                        TextField("翻訳", text: $segment.translatedText, axis: .vertical)
                            .lineLimit(1 ... 4)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { segments.remove(atOffsets: $0) }

            if segments.count > 1 {
                Button {
                    sanitizeAndSortSegments()
                } label: {
                    Label("時間順に並べ替え", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }

    // MARK: - 状態テキスト

    private var phaseText: String {
        switch transcriber.phase {
        case .idle, .done:
            return ""
        case .preparingModel:
            if let progress = transcriber.downloadProgress, progress > 0 {
                let percent = Int(progress * 100)
                if transcriber.downloadAttempt > 1 {
                    return "モデルをダウンロード中… \(percent)%（再試行 \(transcriber.downloadAttempt)回目／初回のみ）"
                }
                return "モデルをダウンロード中… \(percent)%（初回のみ・時間がかかります）"
            }
            if transcriber.downloadAttempt > 1 {
                return "モデルを準備中…（再試行 \(transcriber.downloadAttempt)回目）"
            }
            return "モデルを準備中…（初回はダウンロードします）"
        case .extractingAudio:
            return "音声を抽出中…"
        case .transcribing:
            return "文字起こし中…（動画の長さにより時間がかかります）"
        case .failed(let message):
            return "エラー: \(message)"
        }
    }

    // MARK: - 動画の読み込み

    private func loadPhotoItem(_ item: PhotosPickerItem) async {
        do {
            if let movie = try await item.loadTransferable(type: MovieFile.self) {
                setVideo(url: movie.url, name: "ライブラリ動画")
            } else {
                displayError = DisplayError(message: "選択した動画を読み込めませんでした")
            }
        } catch {
            displayError = DisplayError(message: "動画の読み込みに失敗しました: \(error.localizedDescription)")
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("imported-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            do {
                try FileManager.default.copyItem(at: url, to: copyURL)
                setVideo(url: copyURL, name: url.lastPathComponent)
            } catch {
                displayError = DisplayError(message: "ファイルのコピーに失敗しました: \(error.localizedDescription)")
            }
        case .failure(let error):
            displayError = DisplayError(message: "ファイルの選択に失敗しました: \(error.localizedDescription)")
        }
    }

    private func setVideo(url: URL, name: String) {
        videoURL = url
        videoName = name
        player = AVPlayer(url: url)
        segments = []
    }

    private func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        player?.play()
    }

    /// 再生位置に重なっている字幕（プレビューのオーバーレイ表示用）
    private var activeSegment: SubtitleSegment? {
        segments
            .sorted { $0.start < $1.start }
            .first { currentPlaybackTime >= $0.start && currentPlaybackTime < $0.end }
    }

    // MARK: - 字幕の手動編集

    /// プレイヤーの現在位置（秒）。取得できない場合は最後の字幕の終了時刻
    private func currentPlayerTime() -> TimeInterval {
        if let seconds = player?.currentTime().seconds, seconds.isFinite {
            return max(0, seconds)
        }
        return segments.last?.end ?? 0
    }

    /// 現在の再生位置から3秒間の字幕を新規追加する
    private func addSegmentAtCurrentTime() {
        let start = currentPlayerTime()
        segments.append(SubtitleSegment(start: start, end: start + 3, text: ""))
        segments.sort { $0.start < $1.start }
    }

    /// 開始・終了の不整合（終了が開始以下など）を直して時間順に並べ替える
    private func sanitizeAndSortSegments() {
        for index in segments.indices {
            segments[index].start = max(0, segments[index].start)
            if segments[index].end <= segments[index].start {
                segments[index].end = segments[index].start + 0.5
            }
        }
        segments.sort { $0.start < $1.start }
    }

    // MARK: - 文字起こし

    private func runTranscription() {
        guard let videoURL else { return }
        Task {
            do {
                let result = try await transcriber.transcribe(
                    videoURL: videoURL,
                    modelID: selectedModelID,
                    language: languageChoice == "auto" ? nil : languageChoice
                )
                segments = result
                if result.isEmpty {
                    var message = "字幕が検出されませんでした。"
                    if !transcriber.lastAudioSummary.isEmpty {
                        message += "\n音声チェック: \(transcriber.lastAudioSummary)"
                    }
                    message += "\n音声があるのに変換できない場合は、動画の言語設定（日本語／英語／自動検出）を変えてお試しください。"
                    displayError = DisplayError(message: message)
                }
            } catch {
                displayError = DisplayError(message: "文字起こしに失敗しました: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 翻訳

    private func requestTranslation() {
        if translationConfig == nil {
            translationConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: translateSource),
                target: Locale.Language(identifier: translateSource == "en" ? "ja" : "en")
            )
        } else {
            translationConfig?.invalidate()
        }
    }

    private func performTranslation(session: TranslationSession) async {
        guard !segments.isEmpty else { return }
        isTranslating = true
        defer { isTranslating = false }
        do {
            try await session.prepareTranslation()
            for index in segments.indices where !segments[index].text.isEmpty {
                let response = try await session.translate(segments[index].text)
                segments[index].translatedText = response.targetText
            }
        } catch {
            displayError = DisplayError(message: "翻訳に失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - 書き出し

    private func exportSRT(mode: SubtitleExportMode) {
        sanitizeAndSortSegments()
        let srt = SRTExporter.makeSRT(segments: segments, mode: mode)
        let baseName = (videoName as NSString).deletingPathExtension
        let fileName = (baseName.isEmpty ? "subtitles" : baseName) + "_subtitles.srt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try srt.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
            showShare = true
        } catch {
            displayError = DisplayError(message: "SRTの書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    private func displayText(for segment: SubtitleSegment, mode: SubtitleExportMode) -> String {
        switch mode {
        case .original:
            return segment.text
        case .translated:
            return segment.translatedText.isEmpty ? segment.text : segment.translatedText
        case .bilingual:
            return segment.translatedText.isEmpty
                ? segment.text
                : segment.text + "\n" + segment.translatedText
        }
    }

    private func runBurnIn() {
        guard let videoURL else { return }
        sanitizeAndSortSegments()
        let mode = burnInMode
        let cutEnabled = silenceCutEnabled
        let strength = silenceStrength
        let sourceSegments = segments
        isBurningIn = true
        Task {
            defer { isBurningIn = false }
            do {
                var sourceURL = videoURL
                var burnSegments = sourceSegments
                if cutEnabled {
                    // 無音カット「する」の場合は、先に無音を詰めた動画を作り、
                    // 字幕もカット後のタイミングに付け替えてから焼き込む
                    let cut = try await SilenceCutter.exportCutVideo(
                        videoURL: videoURL,
                        strength: strength
                    )
                    sourceURL = cut.outputURL
                    burnSegments = SilenceCutter.remapSegments(
                        sourceSegments,
                        keepRanges: cut.keepRanges
                    )
                }
                let url = try await BurnInExporter.export(
                    videoURL: sourceURL,
                    segments: burnSegments,
                    displayText: { displayText(for: $0, mode: mode) }
                )
                shareURL = url
                showShare = true
            } catch {
                displayError = DisplayError(message: "焼き込み書き出しに失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func runSilenceCut() {
        guard let videoURL else { return }
        isCuttingSilence = true
        cutSummary = nil
        Task {
            defer { isCuttingSilence = false }
            do {
                let result = try await SilenceCutter.exportCutVideo(
                    videoURL: videoURL,
                    strength: silenceStrength
                )
                if applyCutToSubtitles {
                    segments = SilenceCutter.remapSegments(segments, keepRanges: result.keepRanges)
                }
                cutSummary = String(
                    format: "%.1f秒 → %.1f秒（無音を %.1f秒カット）",
                    result.originalDuration, result.newDuration, result.removedDuration
                )
                shareURL = result.outputURL
                showShare = true
            } catch {
                displayError = DisplayError(message: error.localizedDescription)
            }
        }
    }
}

/// UIActivityViewController の SwiftUI ラッパー（共有シート）
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
