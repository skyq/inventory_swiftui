import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Статусы: справочник и настройки")
struct StatusManagementTests {
  @Test("Создание и переименование с регистронезависимой уникальностью")
  func createsAndRenames() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let created = try session.statuses.create(name: "  Новый статус ")
    #expect(created.name == "Новый статус")
    #expect(!created.isArchived)
    let all = try session.statuses.list(includeArchived: true)
    #expect(all.last?.id == created.id)

    do {
      _ = try session.statuses.create(name: "новый СТАТУС")
      Issue.record("Ожидалась ошибка дубля")
    } catch let error as AppException {
      #expect(error.code == .statusNameDuplicate)
    }

    let other = try session.statuses.create(name: "Ёмкость")
    // Для статусов ё и е — разные имена (D07): переименование допустимо.
    let renamedY = try session.statuses.rename(other.id, to: "емкость")
    #expect(renamedY.name == "емкость")

    let renamed = try session.statuses.rename(created.id, to: "  Переименован ")
    #expect(renamed.name == "Переименован")
    #expect(try session.statuses.get(created.id).name == "Переименован")
  }

  @Test("Пустое и слишком длинное имя отклоняются")
  func validatesName() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    do {
      _ = try session.statuses.create(name: "   ")
      Issue.record("Ожидалась ошибка пустого имени")
    } catch let error as AppException {
      #expect(error.code == .validationRequired)
    }

    do {
      _ = try session.statuses.create(
        name: String(repeating: "я", count: NameKey.maxLength + 1))
      Issue.record("Ожидалась ошибка длины")
    } catch let error as AppException {
      #expect(error.code == .validationTooLong)
    }
  }

  @Test("Архивация статуса в настройках требует замену и меняет все три настройки")
  func archivesUsedStatusWithReplacement() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let defaultId = try TestSupport.statusId(session, named: SeedData.defaultStatusName)
    let replacementId = try TestSupport.statusId(session, named: "В ремонте")
    try session.statusSettings.update(
      StatusSettings(
        defaultStatusId: defaultId,
        transferStatusId: defaultId,
        returnStatusId: defaultId
      )
    )
    let item = try TestSupport.createItem(session, name: "Куртка")

    do {
      _ = try session.statuses.archive(defaultId)
      Issue.record("Статус из настроек нельзя архивировать без замены")
    } catch let error as AppException {
      #expect(error.code == .statusInUse)
    }
    #expect(!(try session.statuses.get(defaultId).isArchived))

    let archived = try session.statuses.archive(defaultId, replacementId: replacementId)
    #expect(archived.isArchived)

    let settings = try session.statusSettings.settings()
    #expect(settings.defaultStatusId == replacementId)
    #expect(settings.transferStatusId == replacementId)
    #expect(settings.returnStatusId == replacementId)

    // Вещь сохраняет архивный статус, фильтр продолжает его видеть.
    let details = try session.items.get(item.item.id)
    #expect(details.item.statusId == defaultId)
    #expect(details.status.isArchived)

    let restored = try session.statuses.restore(defaultId)
    #expect(!restored.isArchived)
    #expect(try session.statusSettings.settings().defaultStatusId == replacementId)
  }

  @Test("Неиспользуемый статус архивируется без замены")
  func archivesUnusedStatus() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let id = try TestSupport.statusId(session, named: "Потерял")
    let archived = try session.statuses.archive(id)
    #expect(archived.isArchived)
    #expect(try session.statuses.list().allSatisfy { $0.id != id })
    #expect(try session.statuses.list(includeArchived: true).contains { $0.id == id })
  }

  @Test("Настройки принимают только существующие активные статусы")
  func validatesSettings() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let active = try TestSupport.statusId(session, named: SeedData.defaultStatusName)
    do {
      try session.statusSettings.update(
        StatusSettings(
          defaultStatusId: active,
          transferStatusId: active,
          returnStatusId: "missing"
        )
      )
      Issue.record("Ожидалась ошибка отсутствующего статуса")
    } catch let error as AppException {
      #expect(error.code == .validationNotFound)
    }

    let archived = try session.statuses.archive(
      try TestSupport.statusId(session, named: "Выбросил")
    )
    do {
      try session.statusSettings.update(
        StatusSettings(
          defaultStatusId: active,
          transferStatusId: archived.id,
          returnStatusId: active
        )
      )
      Issue.record("Ожидалась ошибка архивного статуса")
    } catch let error as AppException {
      #expect(error.code == .statusArchived)
    }
  }

  @Test("Сбой обновления настроек не меняет ни одну из трёх")
  func settingsUpdateIsAtomic() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let before = try session.statusSettings.settings()
    let active = try TestSupport.statusId(session, named: SeedData.defaultStatusName)
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_settings BEFORE UPDATE ON settings
          BEGIN SELECT RAISE(ABORT, 'boom'); END;
          """)
    }

    do {
      try session.statusSettings.update(
        StatusSettings(
          defaultStatusId: active,
          transferStatusId: active,
          returnStatusId: active
        )
      )
      Issue.record("Ожидалась ошибка записи")
    } catch {
      // Ожидаемо: транзакция откатилась.
    }
    #expect(try session.statusSettings.settings() == before)
  }
}
