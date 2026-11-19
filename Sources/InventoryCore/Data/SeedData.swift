import Foundation
import GRDB

/// Начальные данные создаются один раз для нового хранилища.
public enum SeedData {
  public static let statusNames: [String] = [
    "В наличии",
    "Одолжил",
    "Отдал",
    "Продал",
    "Выбросил",
    "Потерял",
    "В ремонте",
  ]

  public static let defaultStatusName = "В наличии"
  public static let transferStatusName = "Отдал"
  public static let returnStatusName = "В наличии"

  /// Идемпотентно: повторный запуск не дублирует статусы и настройки.
  public static func applyIfNeeded(
    _ db: Database,
    clock: any Clock,
    ids: any IdGenerator
  ) throws {
    let statusCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statuses") ?? 0
    let settingsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings") ?? 0
    guard statusCount == 0 && settingsCount == 0 else { return }

    let now = clock.nowMilliseconds()
    var statusIds: [String: String] = [:]
    for (index, name) in statusNames.enumerated() {
      let id = ids.next()
      statusIds[name] = id
      try db.execute(
        sql:
          "INSERT INTO statuses (id, name, is_archived, sort_order, created_at) VALUES (?, ?, 0, ?, ?)",
        arguments: [id, name, index, now]
      )
    }

    let settings: [String: String] = [
      "default_status_id": statusIds[defaultStatusName] ?? "",
      "transfer_status_id": statusIds[transferStatusName] ?? "",
      "return_status_id": statusIds[returnStatusName] ?? "",
    ]
    for key in settings.keys.sorted() {
      try db.execute(
        sql: "INSERT INTO settings (key, value) VALUES (?, ?)",
        arguments: [key, settings[key]]
      )
    }
  }
}
