import Foundation
import GRDB

/// Убирает файлы фото, не упомянутые ни вещами, ни местами.
/// Вызывается только на безопасном старте: после lock, integrity_check и схемы.
public final class OrphanPhotoCleaner: Sendable {
  private let db: InventoryDatabase
  private let photos: any PhotoStore
  private let logger: any AppLogger

  public init(database: InventoryDatabase, photos: any PhotoStore, logger: any AppLogger) {
    self.db = database
    self.photos = photos
    self.logger = logger
  }

  public func cleanup() {
    do {
      let references = try db.read { database in
        var result: Set<String> = []
        let rows = try Row.fetchAll(
          database,
          sql: """
            SELECT photo_file, thumb_file FROM items
            UNION ALL
            SELECT photo_file, thumb_file FROM places
            """
        )
        for row in rows {
          let photo: String = row["photo_file"]
          let thumb: String = row["thumb_file"]
          if !photo.isEmpty { result.insert(photo) }
          if !thumb.isEmpty { result.insert(thumb) }
        }
        return result
      }
      photos.cleanupOrphans(referencedRelativePaths: references)
    } catch {
      // Очистка не должна мешать запуску; файлы удалятся при следующем старте.
      logger.warning(
        "orphan photo cleanup skipped",
        error: String(describing: error),
        data: nil
      )
    }
  }
}
