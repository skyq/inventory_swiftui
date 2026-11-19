import Foundation

public struct PhotoInput: Sendable {
  public let bytes: Data
  public let sourceName: String?
  public let mimeHint: String?

  public init(bytes: Data, sourceName: String? = nil, mimeHint: String? = nil) {
    self.bytes = bytes
    self.sourceName = sourceName
    self.mimeHint = mimeHint
  }
}

/// Результат обработки. Оригинал не изменяется.
public struct ProcessedPhoto: Sendable, Equatable {
  public let photoBytes: Data
  public let thumbBytes: Data
  public let width: Int
  public let height: Int
  public let thumbWidth: Int
  public let thumbHeight: Int
  public let originalWidth: Int
  public let originalHeight: Int

  public init(
    photoBytes: Data,
    thumbBytes: Data,
    width: Int,
    height: Int,
    thumbWidth: Int,
    thumbHeight: Int,
    originalWidth: Int,
    originalHeight: Int
  ) {
    self.photoBytes = photoBytes
    self.thumbBytes = thumbBytes
    self.width = width
    self.height = height
    self.thumbWidth = thumbWidth
    self.thumbHeight = thumbHeight
    self.originalWidth = originalWidth
    self.originalHeight = originalHeight
  }
}

public struct StoredPhoto: Sendable, Equatable {
  /// Относительный путь от корня хранилища: `photos/<uuid>.jpg`.
  public let photoFile: String
  /// Относительный путь от корня хранилища: `thumbs/<uuid>.jpg`.
  public let thumbFile: String

  public init(photoFile: String, thumbFile: String) {
    self.photoFile = photoFile
    self.thumbFile = thumbFile
  }
}

public protocol ImageProcessor: Sendable {
  func process(_ input: PhotoInput) async throws -> ProcessedPhoto
}

public protocol PhotoStore: Sendable {
  var layout: StoreLayout { get }
  func store(_ photo: ProcessedPhoto) throws -> StoredPhoto
  func delete(_ photo: StoredPhoto)
  func deleteFiles(photoFile: String, thumbFile: String)
  func fileURL(for relativePath: String) throws -> URL
  func cleanupOrphans(referencedRelativePaths: Set<String>)
}

extension PhotoStore {
  public func delete(_ photo: StoredPhoto) {
    deleteFiles(photoFile: photo.photoFile, thumbFile: photo.thumbFile)
  }
}
