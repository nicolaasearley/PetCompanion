import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// Client-side photo prep for Life milestone uploads (DM §10 / tech arch §10).
///
/// Re-encodes to JPEG (strips EXIF GPS as a side effect of re-encode), caps the
/// long edge, and keeps capture time when ImageIO can read it.
enum LifePhotoEncoder {
    static let maxLongEdge: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.82
    static let maxBytes = 10_485_760

    struct PreparedPhoto {
        let jpegData: Data
        let captureTime: Date?
    }

    /// PhotosPicker transferable that imports any image content type as raw bytes.
    struct ImportedImage: Transferable {
        let data: Data

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(importedContentType: .image) { data in
                ImportedImage(data: data)
            }
        }
    }

    static func prepare(from data: Data) -> PreparedPhoto? {
        let captureTime = readCaptureTime(from: data)
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let resized = resize(image, maxLongEdge: maxLongEdge)
        guard var jpeg = resized.jpegData(compressionQuality: jpegQuality) else { return nil }
        var quality = jpegQuality
        while jpeg.count > maxBytes, quality > 0.4 {
            quality -= 0.1
            guard let next = resized.jpegData(compressionQuality: quality) else { break }
            jpeg = next
        }
        guard jpeg.count <= maxBytes else { return nil }
        return PreparedPhoto(jpegData: jpeg, captureTime: captureTime)
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    private static func resize(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxLongEdge, longest > 0 else { return image }
        let scale = maxLongEdge / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    #endif

    private static func readCaptureTime(from data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw =
            (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let raw else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }
}
