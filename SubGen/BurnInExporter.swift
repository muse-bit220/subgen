import AVFoundation
import Foundation
import UIKit

/// 字幕を動画に焼き込んで MP4 に書き出す
enum BurnInExporter {
    /// - Parameters:
    ///   - videoURL: 元動画
    ///   - segments: 字幕セグメント列
    ///   - displayText: セグメントから表示文字列を作るクロージャ（原文/翻訳/両方の切替用）
    static func export(
        videoURL: URL,
        segments: [SubtitleSegment],
        displayText: @escaping (SubtitleSegment) -> String
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw BurnInError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        // 回転を含む実表示サイズと、原点を左下にそろえた変換を求める
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw BurnInError.invalidSize
        }
        var finalTransform = transform
        if transformedRect.origin.x != 0 || transformedRect.origin.y != 0 {
            finalTransform = transform.concatenating(
                CGAffineTransform(translationX: -transformedRect.origin.x, y: -transformedRect.origin.y)
            )
        }

        // MARK: 字幕レイヤー構築

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let fontSize = min(max(renderSize.height * 0.045, 16), 72)
        let font = UIFont.boldSystemFont(ofSize: fontSize)
        let maxTextWidth = renderSize.width * 0.92
        let horizontalPadding = fontSize * 0.6
        let verticalPadding = fontSize * 0.35
        let bottomMargin = renderSize.height * 0.055

        for segment in segments {
            let text = displayText(segment)
            guard !text.isEmpty else { continue }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
            ]
            let bounding = (text as NSString).boundingRect(
                with: CGSize(width: maxTextWidth - horizontalPadding * 2, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            let layerWidth = min(ceil(bounding.width) + horizontalPadding * 2, maxTextWidth)
            let layerHeight = ceil(bounding.height) + verticalPadding * 2

            let textLayer = CATextLayer()
            textLayer.string = NSAttributedString(string: text, attributes: attributes)
            textLayer.alignmentMode = .center
            textLayer.isWrapped = true
            textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            textLayer.cornerRadius = fontSize * 0.22
            textLayer.contentsScale = 2.0
            textLayer.frame = CGRect(
                x: (renderSize.width - layerWidth) / 2,
                y: bottomMargin,
                width: layerWidth,
                height: layerHeight
            )
            // 表示タイミングは、レイヤー自身の beginTime / duration ではなく
            // 不透明度アニメーションで制御する。書き出し（オフライン描画）では
            // レイヤーのタイミング指定が評価されず字幕が一切出なかったため、
            // AVFoundation の公式サンプル等で実績のある方式に変更した。
            textLayer.opacity = 0
            let visibility = CAKeyframeAnimation(keyPath: "opacity")
            visibility.values = [0.0, 1.0, 1.0, 0.0]
            visibility.keyTimes = [0.0, 0.03, 0.97, 1.0]
            visibility.beginTime = AVCoreAnimationBeginTimeAtZero + segment.start
            visibility.duration = max(segment.duration, 0.1)
            visibility.fillMode = .both
            visibility.isRemovedOnCompletion = false
            textLayer.add(visibility, forKey: "subtitleVisibility")
            parentLayer.addSublayer(textLayer)
        }

        // MARK: コンポジション & 書き出し

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitled-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw BurnInError.sessionUnavailable
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = composition
        await session.export()

        guard session.status == .completed else {
            if let error = session.error { throw error }
            throw BurnInError.exportFailed
        }
        return outputURL
    }

    enum BurnInError: LocalizedError {
        case noVideoTrack
        case invalidSize
        case sessionUnavailable
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "動画トラックが見つかりませんでした"
            case .invalidSize:
                return "動画のサイズが不正です"
            case .sessionUnavailable:
                return "書き出しセッションを作成できませんでした"
            case .exportFailed:
                return "字幕焼き込み動画の書き出しに失敗しました"
            }
        }
    }
}
