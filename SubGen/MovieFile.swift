import AVFoundation
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// PhotosPicker から動画を受け取るための Transferable ラッパー。
/// 受け取ったファイルはテンポラリへコピーして保持する。
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return MovieFile(url: copyURL)
        }
    }
}
