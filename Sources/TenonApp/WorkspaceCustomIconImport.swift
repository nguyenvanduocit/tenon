// @domain: workspace-model
import Foundation
import ImageIO
import TenonCore
import UniformTypeIdentifiers

/// A bounded boundary between arbitrary image bytes and durable workspace state.
enum WorkspaceCustomIconImportError: LocalizedError, Sendable, Equatable {
    case unreadable
    case sourceTooLarge
    case dimensionsTooLarge
    case unsupportedImage
    case normalizedImageTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The selected image couldn't be read."
        case .sourceTooLarge:
            "Choose an image smaller than 8 MB."
        case .dimensionsTooLarge:
            "Choose an image smaller than 64 megapixels."
        case .unsupportedImage:
            "Choose an image format macOS can decode."
        case .normalizedImageTooLarge:
            "The image couldn't be reduced to a safe workspace icon."
        }
    }
}

enum WorkspaceCustomIconImport {
    static let maximumSourceBytes = 8 * 1_024 * 1_024
    static let maximumPixelCount = 64 * 1_024 * 1_024
    static let maximumDimension = 16_384
    static let renderedPixelSize = 64

    @concurrent
    static func icon(from url: URL) async throws -> WorkspaceCustomIcon {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WorkspaceCustomIconImportError.unreadable
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
        } catch {
            throw WorkspaceCustomIconImportError.unreadable
        }
        return try await icon(from: data)
    }

    @concurrent
    static func icon(from data: Data) async throws -> WorkspaceCustomIcon {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw WorkspaceCustomIconImportError.unsupportedImage }
        guard data.count <= maximumSourceBytes else {
            throw WorkspaceCustomIconImportError.sourceTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            throw WorkspaceCustomIconImportError.unsupportedImage
        }
        guard width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              width <= maximumPixelCount / height
        else {
            throw WorkspaceCustomIconImportError.dimensionsTooLarge
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: renderedPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw WorkspaceCustomIconImportError.unsupportedImage
        }
        try Task.checkCancellation()

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WorkspaceCustomIconImportError.unsupportedImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let icon = WorkspaceCustomIcon(pngData: encoded as Data)
        else {
            throw WorkspaceCustomIconImportError.normalizedImageTooLarge
        }
        return icon
    }
}
