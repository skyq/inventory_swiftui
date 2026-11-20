import Foundation
import InventoryCore
import Testing

@Suite("Статусы: чтение")
struct StatusServiceTests {
  @Test("list по умолчанию без архивных, get возвращает архивный")
  func readsStatuses() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let all = try session.statuses.list(includeArchived: true)
    #expect(all.count == SeedData.statusNames.count)
    let archived = try #require(all.dropFirst().first)
    try session.database.write { db in
      try db.execute(
        sql: "UPDATE statuses SET is_archived = 1 WHERE id = ?",
        arguments: [archived.id]
      )
    }

    let active = try session.statuses.list()
    #expect(!active.contains { $0.id == archived.id })
    #expect(try session.statuses.get(archived.id).isArchived)
  }

  @Test("Отсутствующий статус — validationNotFound")
  func missingStatus() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }
    do {
      _ = try session.statuses.get("missing")
      Issue.record("Ожидалась ошибка")
    } catch let error as AppException {
      #expect(error.code == .validationNotFound)
      #expect(error.string("entity") == "status")
    }
  }
}
