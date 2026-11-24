//
//  PictureStore.swift
//  Markwright
//
//  Turns a chosen picture into something Markdown can reference: a file in a "<Document>-images"
//  folder beside the document when that folder is writable, otherwise an embedded data URL.
//  Shared by the Mac and the iPad, so both save pictures the same way.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum PictureStore {

    struct Stored {
        let source: String
        let alt: String
        let embedded: Bool
    }

    /// Image bytes ready to store: a photo scaled down and saved as JPEG, a small PNG kept as it is.
    struct Prepared {
        let data: Data
        let ext: String
        let alt: String
        let fileName: String
    }

    static let maxPixelSize = 1600

    static func prepare(data: Data, suggestedName: String?, type: UTType?) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let baseName = (suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "")
            .trimmingCharacters(in: .whitespaces)
        let alt = baseName.isEmpty ? "Image" : baseName

        let sourceType = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) ?? type
        let isPNG = sourceType?.conforms(to: .png) == true
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let fitsAsIs = max(width, height) <= maxPixelSize && orientation == 1
        let payload: Data
        let ext: String
        if isPNG, fitsAsIs, data.count < 2_000_000 {
            payload = data
            ext = "png"
        } else if let jpeg = jpeg(from: source) {
            payload = jpeg
            ext = "jpg"
        } else {
            payload = data
            ext = sourceType?.preferredFilenameExtension ?? "img"
        }
        let stamp = formatter.string(from: Date())
        let safe = ImageFolderLinks.safeName(baseName)
        let fileName = (safe.isEmpty ? "image" : safe) + "-" + stamp + "." + ext
        return Prepared(data: payload, ext: ext, alt: alt, fileName: fileName)
    }

    /// Upright, at most `maxPixelSize` on its longest side, JPEG at 85%.
    private static func jpeg(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Saves the picture beside the document. Throws when the folder isn't writable.
    /// `text` is the document's Markdown, so a document that already links into a picture folder keeps using it.
    static func storeBeside(_ prepared: Prepared, documentURL: URL, text: String) throws -> Stored {
        let hasGrant = FolderAccess.begin(documentURL.deletingLastPathComponent())
        do {
            let relative = try writeBeside(documentURL, folderName: pictureFolder(for: documentURL, text: text),
                                           fileName: prepared.fileName, data: prepared.data)
            Diagnostics.log("image saved: \(relative) (folder grant: \(hasGrant))")
            return Stored(source: relative, alt: prepared.alt, embedded: false)
        } catch {
            Diagnostics.log("image not saved beside \(documentURL.path) (folder grant: \(hasGrant)): \(error)")
            throw error
        }
    }

    /// "<Document>-images", unless the text already links only into some other picture folder.
    static func pictureFolder(for documentURL: URL, text: String) -> String {
        let own = ImageFolderLinks.folderName(forDocumentNamed: documentURL.deletingPathExtension().lastPathComponent)
        let linked = ImageFolderLinks.linkedFolders(in: text)
        return linked.isEmpty || linked.contains(own) ? own : linked[0]
    }

    /// Embeds the picture in the Markdown itself (the editor folds the payload out of view).
    static func embed(_ prepared: Prepared) -> Stored {
        let mime = prepared.ext == "png" ? "image/png" : "image/jpeg"
        return Stored(source: "data:\(mime);base64," + prepared.data.base64EncodedString(), alt: prepared.alt, embedded: true)
    }

    /// The path of a picture relative to the document's folder when it is already inside it
    /// (so it can be linked as it is), otherwise nil.
    static func pathInsideDocumentFolder(_ picture: URL, documentURL: URL?) -> String? {
        guard let documentURL else { return nil }
        let folder = Document.stablePath(documentURL.deletingLastPathComponent())
        let path = Document.stablePath(picture)
        guard path.hasPrefix(folder + "/") else { return nil }
        return String(path.dropFirst(folder.count + 1))
    }

    /// Writes into `folderName` next to the document under a name not already used there, and
    /// returns the relative path. Fails when the folder isn't writable (iCloud Drive and other
    /// providers, and the Mac's sandbox, only grant the document itself).
    private static func writeBeside(_ documentURL: URL, folderName: String, fileName: String, data: Data) throws -> String {
        let folder = documentURL.deletingLastPathComponent().appending(path: folderName, directoryHint: .isDirectory)
        let name = ImageFolderLinks.uniqueFileName(fileName) {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
        let target = folder.appending(path: name)
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .withoutOverwriting)
            } catch {
                writeError = error
            }
        }
        if let error = writeError ?? coordinatorError { throw error }
        return folderName + "/" + name
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
