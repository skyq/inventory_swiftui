import Foundation

/// Согласование файлов и SQL: новые файлы пишутся до commit,
/// старые удаляются только после успешного commit.
public final class PhotoLifecycle: Sendable {
  private let photos: any PhotoStore
  private let logger: any AppLogger

  public init(photos: any PhotoStore, logger: any AppLogger) {
    self.photos = photos
    self.logger = logger
  }

  public func deleteAfterCommit(_ photo: StoredPhoto) {
    photos.delete(photo)
  }

  public func replace<T>(
    prepared: ProcessedPhoto?,
    previous: StoredPhoto?,
    apply: (StoredPhoto?) throws -> T
  ) throws -> T {
    guard let prepared else {
      return try apply(previous)
    }

    let stored = try photos.store(prepared)

    let result: T
    do {
      result = try apply(stored)
    } catch {
      photos.delete(stored)
      throw error
    }

    if let previous, previous.photoFile != stored.photoFile {
      photos.delete(previous)
    }
    return result
  }
}
