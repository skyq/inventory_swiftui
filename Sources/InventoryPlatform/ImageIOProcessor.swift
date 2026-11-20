import CoreGraphics
import Foundation
import ImageIO
import InventoryCore
import UniformTypeIdentifiers

/// Обработка фото через ImageIO: формат по содержимому, EXIF, белый фон,
/// ресайз ≤2560 px и превью ≈400 px. Работа идёт вне главного потока.
public struct ImageIOProcessor: ImageProcessor {
  public static let maxSourceSide = 12_000
  public static let maxPhotoSide = 2_560
  public static let maxThumbSide = 400
  public static let jpegQuality = 0.9

  public init() {}

  public func process(_ input: PhotoInput) async throws -> ProcessedPhoto {
    try await Task.detached(priority: .userInitiated) {
      try Self.processSync(input)
    }.value
  }

  static func processSync(_ input: PhotoInput) throws -> ProcessedPhoto {
    guard !input.bytes.isEmpty else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(input.sourceName ?? "")]
      )
    }

    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard
      let source = CGImageSourceCreateWithData(input.bytes as CFData, sourceOptions as CFDictionary)
    else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(input.sourceName ?? "")],
        debugMessage: "CGImageSource is nil"
      )
    }

    guard let typeIdentifier = CGImageSourceGetType(source) as String?,
      let type = UTType(typeIdentifier)
    else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(input.sourceName ?? "")],
        debugMessage: "image type is unknown"
      )
    }

    guard isAllowed(type) else {
      throw AppException(
        .photoUnsupportedFormat,
        params: ["sourceName": .string(input.sourceName ?? "")]
      )
    }

    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let originalWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let originalHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      originalWidth > 0, originalHeight > 0
    else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(input.sourceName ?? "")],
        debugMessage: "image dimensions are unavailable"
      )
    }

    if max(originalWidth, originalHeight) > maxSourceSide {
      throw AppException(
        .photoTooLarge,
        params: [
          "width": .int(originalWidth),
          "height": .int(originalHeight),
          "max": .int(Self.maxSourceSide),
        ]
      )
    }

    let photo = try render(
      source: source,
      maxSide: min(max(originalWidth, originalHeight), Self.maxPhotoSide),
      sourceName: input.sourceName
    )
    let thumb = try render(
      source: source,
      maxSide: min(max(originalWidth, originalHeight), Self.maxThumbSide),
      sourceName: input.sourceName
    )

    let photoBytes = try encodeJPEG(photo)
    let thumbBytes = try encodeJPEG(thumb)

    return ProcessedPhoto(
      photoBytes: photoBytes,
      thumbBytes: thumbBytes,
      width: photo.width,
      height: photo.height,
      thumbWidth: thumb.width,
      thumbHeight: thumb.height,
      originalWidth: originalWidth,
      originalHeight: originalHeight
    )
  }

  private static func isAllowed(_ type: UTType) -> Bool {
    type.conforms(to: .jpeg)
      || type.conforms(to: .png)
      || type.conforms(to: .webP)
      || type.conforms(to: .heic)
      || type.conforms(to: .heif)
  }

  private static func render(
    source: CGImageSource,
    maxSide: Int,
    sourceName: String?
  ) throws -> CGImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxSide,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(sourceName ?? "")],
        debugMessage: "cannot decode image"
      )
    }
    return try flattenedOnWhite(image, sourceName: sourceName)
  }

  /// Прозрачность заменяется белым фоном; изображение не растягивается.
  private static func flattenedOnWhite(_ image: CGImage, sourceName: String?) throws -> CGImage {
    let width = image.width
    let height = image.height
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(sourceName ?? "")],
        debugMessage: "sRGB color space is unavailable"
      )
    }
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(sourceName ?? "")],
        debugMessage: "cannot create bitmap context"
      )
    }

    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(rect)
    context.interpolationQuality = .high
    context.draw(image, in: rect)

    guard let flattened = context.makeImage() else {
      throw AppException(
        .photoCorrupt,
        params: ["sourceName": .string(sourceName ?? "")],
        debugMessage: "cannot render flattened image"
      )
    }
    return flattened
  }

  private static func encodeJPEG(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw AppException(.photoWriteFailed, debugMessage: "cannot create JPEG destination")
    }
    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: jpegQuality
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw AppException(.photoWriteFailed, debugMessage: "cannot encode JPEG")
    }
    return data as Data
  }
}
