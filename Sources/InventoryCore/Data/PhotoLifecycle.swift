import Foundation

/// Согласование файлов и SQL: новые файлы пишутся до commit,
/// старые удаляются только после успешного commit.
///
/// Вся операция удерживает `StoreWriteGate`, чтобы снимок для экспорта не
/// оказался между записью файла и commit либо между commit и удалением старого
/// файла.
public final class PhotoLifecycle: Sendable {
  private let photos: any PhotoStore
  private let logger: any AppLogger
  private let gate: StoreWriteGate

  public init(
    photos: any PhotoStore,
    logger: any AppLogger,
    gate: StoreWriteGate = StoreWriteGate()
  ) {
    self.photos = photos
    self.logger = logger
    self.gate = gate
  }

  public func deleteAfterCommit(_ photo: StoredPhoto) {
    gate.performWrite {
      photos.delete(photo)
    }
  }

  public func replace<T>(
    prepared: ProcessedPhoto?,
    previous: StoredPhoto?,
    apply: (StoredPhoto?) throws -> T
  ) throws -> T {
    try gate.performWrite {
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
}
