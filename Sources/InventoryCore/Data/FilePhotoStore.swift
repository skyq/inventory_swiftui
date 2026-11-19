import Foundation

public final class FilePhotoStore: PhotoStore, @unchecked Sendable {
  public let layout: StoreLayout
  private let ids: any IdGenerator
  private let logger: any AppLogger
  private let fileManager: FileManager

  public init(
    layout: StoreLayout,
    ids: any IdGenerator,
    logger: any AppLogger,
    fileManager: FileManager = .default
  ) {
    self.layout = layout
    self.ids = ids
    self.logger = logger
    self.fileManager = fileManager
  }

  public func store(_ photo: ProcessedPhoto) throws -> StoredPhoto {
    do {
      try fileManager.createDirectory(at: layout.photosURL, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: layout.thumbsURL, withIntermediateDirectories: true)
    } catch {
      throw AppException(
        .photoWriteFailed,
        params: ["path": .string(layout.rootPath)],
        debugMessage: "failed to create photo directories: \(error)"
      )
    }

    let base = ids.next()
    let photoFile = "photos/\(base).jpg"
    let thumbFile = "thumbs/\(base).jpg"
    let photoURL = try layout.fileURL(forRelativePath: photoFile)
    let thumbURL = try layout.fileURL(forRelativePath: thumbFile)

    do {
      try photo.photoBytes.write(to: photoURL, options: .atomic)
    } catch {
      throw AppException(
        .photoWriteFailed,
        params: ["path": .string(photoFile)],
        debugMessage: "failed to write photo: \(error)"
      )
    }

    do {
      try photo.thumbBytes.write(to: thumbURL, options: .atomic)
    } catch {
      try? fileManager.removeItem(at: photoURL)
      throw AppException(
        .photoWriteFailed,
        params: ["path": .string(thumbFile)],
        debugMessage: "failed to write thumbnail: \(error)"
      )
    }

    return StoredPhoto(photoFile: photoFile, thumbFile: thumbFile)
  }

  public func deleteFiles(photoFile: String, thumbFile: String) {
    for relative in [photoFile, thumbFile] where !relative.isEmpty {
      guard let url = try? layout.fileURL(forRelativePath: relative) else { continue }
      do {
        if fileManager.fileExists(atPath: url.path) {
          try fileManager.removeItem(at: url)
        }
      } catch {
        logger.warning(
          "failed to delete photo file",
          error: String(describing: error),
          data: ["file": relative]
        )
      }
    }
  }

  public func fileURL(for relativePath: String) throws -> URL {
    try layout.fileURL(forRelativePath: relativePath)
  }

  public func cleanupOrphans(referencedRelativePaths: Set<String>) {
    for (directory, prefix) in [(layout.photosURL, "photos"), (layout.thumbsURL, "thumbs")] {
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }

      for url in entries {
        let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isFile else { continue }
        let relative = "\(prefix)/\(url.lastPathComponent)"
        guard !referencedRelativePaths.contains(relative) else { continue }
        do {
          try fileManager.removeItem(at: url)
        } catch {
          logger.warning(
            "failed to delete orphan photo",
            error: String(describing: error),
            data: ["file": relative]
          )
        }
      }
    }
  }
}
