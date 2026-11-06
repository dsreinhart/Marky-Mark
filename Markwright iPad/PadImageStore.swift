//
//  PadImageStore.swift
//  Markwright iPad
//
//  Turns a picked image into something Markdown can reference: a file beside the
//  document when that folder is writable, otherwise an embedded data URL.
//

import UIKit
import UniformTypeIdentifiers

@MainActor
enum PadImageStore {

    struct Stored {
        let source: String
        let alt: String
        let embedded: Bool
    }

    private static let maxPixelSize: CGFloat = 1600

    /// Image bytes prepared for storage: downscaled photo as JPEG, small PNGs kept.
    struct Prepared {
        let data: Data
        let ext: String
        let alt: String
        let fileName: String
    }

    static func prepare(data: Data, suggestedName: String?, type: UTType?) -> Prepared? {
        guard let image = UIImage(data: data) else { return nil }
        let baseName = (suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "")
            .trimmingCharacters(in: .whitespaces)
        let alt = baseName.isEmpty ? "Image" : baseName

        let isPNG = type?.conforms(to: .png) == true
        let scaled = downscale(image)
        let payload: Data
        let ext: String
        if isPNG, scaled.size == image.size, data.count < 2_000_000 {
            payload = data
            ext = "png"
        } else if let jpeg = scaled.jpegData(compressionQuality: 0.85) {
            payload = jpeg
            ext = "jpg"
        } else {
            payload = data
            ext = type?.preferredFilenameExtension ?? "img"
        }
        let stamp = Self.formatter.string(from: Date())
        let fileName = (baseName.isEmpty ? "image" : safe(baseName)) + "-" + stamp + "." + ext
        return Prepared(data: payload, ext: ext, alt: alt, fileName: fileName)
    }

    /// Tries to save the image beside the document; nil when the folder isn't writable.
    static func storeBeside(_ prepared: Prepared, documentURL: URL?) -> Stored? {
        guard let documentURL else { return nil }
        PadFolderAccess.begin(documentURL.deletingLastPathComponent())
        guard let relative = writeBeside(documentURL, fileName: prepared.fileName, data: prepared.data) else { return nil }
        return Stored(source: relative, alt: prepared.alt, embedded: false)
    }

    /// Embeds the image in the Markdown itself (the editor folds the payload out of view).
    static func embed(_ prepared: Prepared) -> Stored {
        let mime = prepared.ext == "png" ? "image/png" : "image/jpeg"
        return Stored(source: "data:\(mime);base64," + prepared.data.base64EncodedString(), alt: prepared.alt, embedded: true)
    }

    /// Writes into "<Document name>-images/" next to the document. Returns the relative path, or nil
    /// when the folder isn't writable (iCloud Drive and other providers only grant the file itself).
    private static func writeBeside(_ documentURL: URL, fileName: String, data: Data) -> String? {
        let folderName = safe(documentURL.deletingPathExtension().lastPathComponent) + "-images"
        let folder = documentURL.deletingLastPathComponent().appending(path: folderName, directoryHint: .isDirectory)
        let target = folder.appending(path: fileName)
        var succeeded = false
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                succeeded = true
            } catch {
                succeeded = false
            }
        }
        guard succeeded, coordinatorError == nil else { return nil }
        return folderName + "/" + fileName
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixelSize else { return image }
        let scale = maxPixelSize / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func safe(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
