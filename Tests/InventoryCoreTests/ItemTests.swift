import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Вещи: создание, редактирование и фото")
struct ItemTests {
  @Test("Валидации имени, количества, фото и места")
  func validatesCreateFields() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    expectCode(.validationRequired) {
      _ = try session.items.create(
        ItemCreate(name: "Лампа", placeId: nil, statusId: nil, photo: nil)
      )
    }
    expectCode(.validationRequired) {
      _ = try session.items.create(
        ItemCreate(name: "  ", placeId: nil, statusId: nil, photo: TestSupport.makePhoto())
      )
    }
    expectCode(.validationTooLong) {
      _ = try session.items.create(
        ItemCreate(
          name: String(repeating: "Я", count: NameKey.maxLength + 1),
          placeId: nil,
          statusId: nil,
          photo: TestSupport.makePhoto()
        )
      )
    }
    expectCode(.validationOutOfRange) {
      _ = try session.items.create(
        ItemCreate(
          name: "Лампа", quantity: 0, placeId: nil, statusId: nil, photo: TestSupport.makePhoto())
      )
    }
    expectCode(.validationNotFound) {
      _ = try session.items.create(
        ItemCreate(name: "Лампа", placeId: "missing", statusId: nil, photo: TestSupport.makePhoto())
      )
    }
    #expect(try TestSupport.rowCount(session.database, table: "items") == 0)
  }

  @Test("По умолчанию берётся default_status_id, место может быть NULL")
  func assignsDefaultStatus() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let defaultId = try session.database.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'default_status_id'")
    }
    let details = try session.items.create(
      ItemCreate(name: "Лампа", placeId: nil, statusId: nil, photo: TestSupport.makePhoto())
    )
    #expect(details.status.id == defaultId)
    #expect(details.item.statusId == defaultId)
    #expect(details.item.placeId == nil)
    #expect(details.placePath.isEmpty)
    #expect(try TestSupport.rowCount(session.database, table: "status_changes") == 0)
  }

  @Test("Архивный статус нельзя назначить новой вещи")
  func rejectsArchivedStatus() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let statuses = try session.statuses.list()
    let archived = try #require(statuses.dropFirst().first)
    try session.database.write { db in
      try db.execute(
        sql: "UPDATE statuses SET is_archived = 1 WHERE id = ?",
        arguments: [archived.id]
      )
    }

    expectCode(.statusArchived) {
      _ = try session.items.create(
        ItemCreate(
          name: "Лампа",
          placeId: nil,
          statusId: archived.id,
          photo: TestSupport.makePhoto()
        )
      )
    }
  }

  @Test("Сбой SQL при создании убирает новые фото и теги")
  func rollsBackCreate() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_items BEFORE INSERT ON items
          BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
          """)
    }

    #expect(throws: DatabaseError.self) {
      _ = try session.items.create(
        ItemCreate(
          name: "Лампа",
          placeId: nil,
          statusId: nil,
          tags: ["Свет"],
          photo: TestSupport.makePhoto()
        )
      )
    }

    #expect(try TestSupport.rowCount(session.database, table: "items") == 0)
    #expect(try TestSupport.rowCount(session.database, table: "tags") == 0)
    #expect(try TestSupport.rowCount(session.database, table: "item_tags") == 0)
    let photos = try FileManager.default.contentsOfDirectory(atPath: session.layout.photosURL.path)
    let thumbs = try FileManager.default.contentsOfDirectory(atPath: session.layout.thumbsURL.path)
    #expect(photos.isEmpty)
    #expect(thumbs.isEmpty)
  }

  @Test("Обычное редактирование не меняет статус и историю")
  func updateDoesNotChangeStatus() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let place = try session.places.create(
      PlaceCreate(name: "Дом", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let created = try session.items.create(
      ItemCreate(
        name: "Лампа",
        description: "старое",
        notes: "заметка",
        quantity: 2,
        placeId: place.id,
        statusId: nil,
        tags: ["Свет"],
        photo: TestSupport.makePhoto()
      )
    )

    let updated = try session.items.updateDetails(
      ItemDetailsUpdate(
        id: created.item.id,
        name: "Настольная лампа",
        description: "новое",
        notes: "другая заметка",
        quantity: 3,
        placeId: nil,
        tags: ["Свет", "Дом"],
        newPhoto: nil
      )
    )

    #expect(updated.item.name == "Настольная лампа")
    #expect(updated.item.description == "новое")
    #expect(updated.item.notes == "другая заметка")
    #expect(updated.item.quantity == 3)
    #expect(updated.item.placeId == nil)
    #expect(updated.item.statusId == created.item.statusId)
    #expect(updated.status.id == created.status.id)
    #expect(updated.tags.map(\.name) == ["Дом", "Свет"])
    #expect(try TestSupport.rowCount(session.database, table: "status_changes") == 0)
  }

  @Test("Замена фото обновляет БД и удаляет старую пару")
  func replacesPhoto() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let created = try session.items.create(
      ItemCreate(name: "Лампа", placeId: nil, statusId: nil, photo: TestSupport.makePhoto())
    )
    let oldPhoto = created.item.photoFile
    let oldThumb = created.item.thumbFile

    let updated = try session.items.updateDetails(
      ItemDetailsUpdate(
        id: created.item.id,
        name: created.item.name,
        description: "",
        notes: "",
        quantity: 1,
        placeId: nil,
        tags: [],
        newPhoto: TestSupport.makePhoto()
      )
    )

    #expect(updated.item.photoFile != oldPhoto)
    #expect(updated.item.thumbFile != oldThumb)
    #expect(
      FileManager.default.fileExists(atPath: session.layout.rootPath + "/" + updated.item.photoFile)
    )
    #expect(!FileManager.default.fileExists(atPath: session.layout.rootPath + "/" + oldPhoto))
    #expect(!FileManager.default.fileExists(atPath: session.layout.rootPath + "/" + oldThumb))
  }

  @Test("Сбой SQL при замене фото оставляет старое фото и старые поля")
  func rollsBackPhotoAndFields() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let created = try session.items.create(
      ItemCreate(name: "Лампа", placeId: nil, statusId: nil, photo: TestSupport.makePhoto())
    )
    let oldPhoto = created.item.photoFile
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_items BEFORE UPDATE ON items
          BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
          """)
    }

    #expect(throws: DatabaseError.self) {
      _ = try session.items.updateDetails(
        ItemDetailsUpdate(
          id: created.item.id,
          name: "Новое имя",
          description: "",
          notes: "",
          quantity: 1,
          placeId: nil,
          tags: ["Новый"],
          newPhoto: TestSupport.makePhoto()
        )
      )
    }

    let stored = try session.items.get(created.item.id)
    #expect(stored.item.name == "Лампа")
    #expect(stored.item.photoFile == oldPhoto)
    #expect(FileManager.default.fileExists(atPath: session.layout.rootPath + "/" + oldPhoto))
    let photos = try FileManager.default.contentsOfDirectory(atPath: session.layout.photosURL.path)
    #expect(photos.count == 1)
    #expect(try TestSupport.rowCount(session.database, table: "tags") == 0)
  }

  @Test("Отсутствующая вещь даёт validationNotFound")
  func missingItem() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }
    expectCode(.validationNotFound) {
      _ = try session.items.get("missing")
    }
  }

  private func expectCode(_ code: AppErrorCode, _ body: () throws -> Void) {
    do {
      try body()
      Issue.record("Ожидалась ошибка \(code.rawValue)")
    } catch let error as AppException {
      #expect(error.code == code)
    } catch {
      Issue.record("Неожиданная ошибка: \(error)")
    }
  }
}
