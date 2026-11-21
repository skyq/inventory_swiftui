import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Действия с вещью: статус, передача, возврат")
struct ItemActionsTests {
  @Test("Смена статуса пишет историю и не меняет количество и место")
  func changesStatus() throws {
    let clock = MutableTestClock()
    let (session, root) = try TestSupport.makeSession(clock: clock)
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let place = try TestSupport.createPlace(session, name: "Шкаф")
    let item = try TestSupport.createItem(session, name: "Куртка", placeId: place.id)
    let target = try TestSupport.statusId(session, named: "В ремонте")

    clock.advance(by: 500)
    let updated = try session.actions.changeStatus(
      ChangeStatusCommand(itemId: item.item.id, toStatusId: target, comment: "порвалась")
    )
    #expect(updated.item.statusId == target)
    #expect(updated.item.quantity == 1)
    #expect(updated.item.placeId == place.id)

    let history = try session.history.itemHistory(itemId: item.item.id)
    #expect(history.count == 1)
    let event = try #require(history.first)
    #expect(event.kind == .statusChange)
    #expect(event.fromStatusName == SeedData.defaultStatusName)
    #expect(event.toStatusName == "В ремонте")
    #expect(event.comment == "порвалась")
    #expect(event.occurredAt == clock.nowMilliseconds())
  }

  @Test("Тот же и архивный статус отклоняются")
  func rejectsInvalidStatusChange() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")

    do {
      _ = try session.actions.changeStatus(
        ChangeStatusCommand(itemId: item.item.id, toStatusId: item.item.statusId))
      Issue.record("Смена на тот же статус запрещена")
    } catch let error as AppException {
      #expect(error.code == .statusUnchanged)
    }

    let archived = try session.statuses.archive(
      try TestSupport.statusId(session, named: "Продал"))
    do {
      _ = try session.actions.changeStatus(
        ChangeStatusCommand(itemId: item.item.id, toStatusId: archived.id))
      Issue.record("Архивный статус нельзя назначать")
    } catch let error as AppException {
      #expect(error.code == .statusArchived)
    }
  }

  @Test("Сбой между INSERT истории и UPDATE вещи откатывает оба")
  func rollsBackStatusChange() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")
    let target = try TestSupport.statusId(session, named: "В ремонте")
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_items_update BEFORE UPDATE ON items
          BEGIN SELECT RAISE(ABORT, 'boom'); END;
          """)
    }

    do {
      _ = try session.actions.changeStatus(
        ChangeStatusCommand(itemId: item.item.id, toStatusId: target))
      Issue.record("Ожидалась ошибка записи")
    } catch {}

    #expect(try session.history.itemHistory(itemId: item.item.id).isEmpty)
    #expect(try session.items.get(item.item.id).item.statusId == item.item.statusId)
  }

  @Test("Передача: все сочетания флажков статуса и места")
  func giveFlagCombinations() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let place = try TestSupport.createPlace(session, name: "Шкаф")
    let person = try session.people.create(PersonCreate(name: "Анна"))
    let transferStatus = try TestSupport.statusId(session, named: SeedData.transferStatusName)

    let combinations: [(changeStatus: Bool, clearPlace: Bool)] = [
      (true, true), (true, false), (false, true), (false, false),
    ]
    for (index, combo) in combinations.enumerated() {
      let item = try TestSupport.createItem(
        session, name: "Вещь \(index)", placeId: place.id)
      let updated = try session.actions.give(
        GiveCommand(
          itemId: item.item.id,
          person: .existing(id: person.id),
          comment: "отдал",
          changeStatus: combo.changeStatus,
          statusId: transferStatus,
          clearPlace: combo.clearPlace
        )
      )

      #expect(updated.item.quantity == 1)
      #expect(updated.item.placeId == (combo.clearPlace ? nil : place.id))
      #expect(updated.item.statusId == (combo.changeStatus ? transferStatus : item.item.statusId))

      let history = try session.history.itemHistory(itemId: item.item.id)
      #expect(history.contains { $0.kind == .give })
      #expect(
        history.contains { $0.kind == .statusChange } == combo.changeStatus)
    }
  }

  @Test("Передача с уже текущим статусом не пишет status_changes (D02)")
  func giveSameStatus() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")
    let person = try session.people.create(PersonCreate(name: "Анна"))
    let updated = try session.actions.give(
      GiveCommand(
        itemId: item.item.id,
        person: .existing(id: person.id),
        changeStatus: true,
        statusId: item.item.statusId,
        clearPlace: false
      )
    )
    #expect(updated.item.statusId == item.item.statusId)
    #expect(
      try session.history.itemHistory(itemId: item.item.id)
        .filter { $0.kind == .statusChange }.isEmpty)
  }

  @Test("Новый человек создаётся в транзакции передачи (D08)")
  func createsPersonAtomically() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")
    let updated = try session.actions.give(
      GiveCommand(
        itemId: item.item.id,
        person: .new(
          name: "Новый человек", phone: "123", notes: "из диалога",
          duplicateConfirmed: false
        )
      )
    )
    #expect(updated.item.id == item.item.id)
    let people = try session.people.list()
    #expect(people.count == 1)
    #expect(people.first?.phone == "123")
    #expect(try session.people.lastGivenPersonId(itemId: item.item.id) == people.first?.id)

    // Дубль без подтверждения отклоняется до записи передачи.
    do {
      _ = try session.actions.give(
        GiveCommand(
          itemId: item.item.id,
          person: .new(
            name: "новый человек", phone: "", notes: "", duplicateConfirmed: false)
        )
      )
      Issue.record("Ожидалось предупреждение о дубле")
    } catch let error as AppException {
      #expect(error.code == .personNameDuplicate)
    }
  }

  @Test("Ошибка после записи человека и передачи откатывает обе")
  func rollsBackGive() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_status_insert BEFORE INSERT ON status_changes
          BEGIN SELECT RAISE(ABORT, 'boom'); END;
          """)
    }

    do {
      _ = try session.actions.give(
        GiveCommand(
          itemId: item.item.id,
          person: .new(
            name: "Новый", phone: "", notes: "", duplicateConfirmed: false),
          changeStatus: true
        )
      )
      Issue.record("Ожидалась ошибка записи")
    } catch {}

    #expect(try TestSupport.rowCount(session.database, table: "transfers") == 0)
    #expect(try TestSupport.rowCount(session.database, table: "status_changes") == 0)
    #expect(try session.people.list(includeArchived: true).isEmpty)
  }

  @Test("Возврат: место по D04 и статус без лишней истории")
  func returnPlaceAndStatus() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let original = try TestSupport.createPlace(session, name: "Шкаф")
    let newPlace = try TestSupport.createPlace(session, name: "Полка")
    let person = try session.people.create(PersonCreate(name: "Анна"))
    let returnStatus = try TestSupport.statusId(session, named: SeedData.returnStatusName)

    let item = try TestSupport.createItem(session, name: "Куртка", placeId: original.id)
    _ = try session.actions.give(
      GiveCommand(
        itemId: item.item.id,
        person: .existing(id: person.id),
        changeStatus: true,
        clearPlace: true
      )
    )
    #expect(try session.items.get(item.item.id).item.placeId == nil)

    // «Оставить текущее» и текущий статус: ни места, ни истории статуса.
    let kept = try session.actions.returnItem(
      ReturnCommand(
        itemId: item.item.id,
        personId: person.id,
        statusId: nil,
        place: .keep
      )
    )
    #expect(kept.item.placeId == nil)
    #expect(
      try session.history.itemHistory(itemId: item.item.id)
        .filter { $0.kind == .statusChange }.count == 1)

    // «Без места» — явный NULL, «место» — новый id.
    let cleared = try session.actions.returnItem(
      ReturnCommand(itemId: item.item.id, personId: person.id, place: .clear))
    #expect(cleared.item.placeId == nil)

    let placed = try session.actions.returnItem(
      ReturnCommand(
        itemId: item.item.id, personId: person.id,
        statusId: returnStatus, place: .place(newPlace.id)))
    #expect(placed.item.placeId == newPlace.id)
    #expect(placed.item.statusId == returnStatus)

    let events = try session.history.itemHistory(itemId: item.item.id)
    #expect(events.filter { $0.kind == .returnTransfer }.count == 3)
    #expect(events.filter { $0.kind == .statusChange }.count == 2)
  }

  @Test("Возврат допускает архивного человека только из истории вещи (D03)")
  func returnArchivedPerson() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let person = try session.people.create(PersonCreate(name: "Борис"))
    let stranger = try session.people.create(PersonCreate(name: "Чужой"))
    let item = try TestSupport.createItem(session, name: "Палатка")
    _ = try session.actions.give(
      GiveCommand(itemId: item.item.id, person: .existing(id: person.id)))
    _ = try session.people.archive(person.id)
    _ = try session.people.archive(stranger.id)

    // Архивный участник истории этой вещи допустим.
    let returned = try session.actions.returnItem(
      ReturnCommand(itemId: item.item.id, personId: person.id))
    #expect(returned.item.id == item.item.id)

    // Архивный человек без передач по этой вещи — нет.
    do {
      _ = try session.actions.returnItem(
        ReturnCommand(itemId: item.item.id, personId: stranger.id))
      Issue.record("Архивный человек вне истории вещи недопустим")
    } catch let error as AppException {
      #expect(error.code == .personArchived)
    }

    // Возврат без открытой выдачи не запрещён.
    let free = try session.people.create(PersonCreate(name: "Свободный"))
    _ = try session.actions.returnItem(
      ReturnCommand(itemId: item.item.id, personId: free.id))
  }

  @Test("Сбой возврата откатывает transfer, историю и место")
  func rollsBackReturn() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let place = try TestSupport.createPlace(session, name: "Шкаф")
    let person = try session.people.create(PersonCreate(name: "Анна"))
    let item = try TestSupport.createItem(session, name: "Куртка", placeId: place.id)
    _ = try session.actions.give(
      GiveCommand(
        itemId: item.item.id, person: .existing(id: person.id),
        changeStatus: true, clearPlace: false))

    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_items_update BEFORE UPDATE ON items
          BEGIN SELECT RAISE(ABORT, 'boom'); END;
          """)
    }
    let before = try session.items.get(item.item.id)
    do {
      _ = try session.actions.returnItem(
        ReturnCommand(
          itemId: item.item.id, personId: person.id,
          statusId: try TestSupport.statusId(session, named: SeedData.returnStatusName),
          place: .place(place.id)
        )
      )
      Issue.record("Ожидалась ошибка записи")
    } catch {}

    let after = try session.items.get(item.item.id)
    #expect(after.item.statusId == before.item.statusId)
    #expect(after.item.placeId == before.item.placeId)
    #expect(
      try session.history.itemHistory(itemId: item.item.id)
        .filter { $0.kind == .returnTransfer }.isEmpty)
  }

  @Test("Дата берётся только из Clock")
  func usesClockForDate() throws {
    let clock = MutableTestClock(value: 1_700_000_123_456)
    let (session, root) = try TestSupport.makeSession(clock: clock)
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let person = try session.people.create(PersonCreate(name: "Анна"))
    let item = try TestSupport.createItem(session, name: "Куртка")
    _ = try session.actions.give(
      GiveCommand(itemId: item.item.id, person: .existing(id: person.id)))
    let events = try session.history.itemHistory(itemId: item.item.id)
    #expect(events.allSatisfy { $0.occurredAt == 1_700_000_123_456 })
  }
}
