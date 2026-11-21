import Foundation
import InventoryCore
import Testing

@Suite("История: единая лента")
struct HistoryTests {
  @Test("Смешанная лента содержит статусы и передачи, новые сверху")
  func mixesEventsNewestFirst() throws {
    let clock = MutableTestClock()
    let (session, root) = try TestSupport.makeSession(clock: clock)
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let person = try session.people.create(PersonCreate(name: "Анна"))
    let item = try TestSupport.createItem(session, name: "Куртка")
    let other = try TestSupport.statusId(session, named: "В ремонте")

    clock.advance(by: 1000)
    _ = try session.actions.changeStatus(
      ChangeStatusCommand(itemId: item.item.id, toStatusId: other, comment: "ремонт"))
    clock.advance(by: 1000)
    _ = try session.actions.give(
      GiveCommand(
        itemId: item.item.id, person: .existing(id: person.id), comment: "отдал",
        changeStatus: false))
    clock.advance(by: 1000)
    _ = try session.actions.returnItem(
      ReturnCommand(itemId: item.item.id, personId: person.id, comment: "вернул"))

    let events = try session.history.itemHistory(itemId: item.item.id)
    #expect(events.map(\.kind) == [.returnTransfer, .give, .statusChange])
    #expect(events[0].comment == "вернул")
    #expect(events[1].personName == "Анна")
    #expect(events[2].fromStatusName == SeedData.defaultStatusName)
    #expect(events[2].toStatusName == "В ремонте")
  }

  @Test("При равных миллисекундах порядок детерминирован (D12)")
  func ordersTiesDeterministically() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let person = try session.people.create(PersonCreate(name: "Анна"))
    let item = try TestSupport.createItem(session, name: "Куртка")
    _ = try session.actions.give(
      GiveCommand(itemId: item.item.id, person: .existing(id: person.id)))

    let first = try session.history.itemHistory(itemId: item.item.id)
    let second = try session.history.itemHistory(itemId: item.item.id)
    #expect(first.map(\.id) == second.map(\.id))
    // Передача выше смены статуса при одинаковом времени.
    #expect(first.first?.kind == .give)

    let repeated = try session.history.itemHistory(itemId: item.item.id)
    #expect(repeated.map(\.id) == first.map(\.id))
  }

  @Test("Архивация не скрывает события, переименование отражается")
  func archivedEntitiesRemainVisible() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let person = try session.people.create(PersonCreate(name: "Анна"))
    let item = try TestSupport.createItem(session, name: "Куртка")
    _ = try session.actions.give(
      GiveCommand(itemId: item.item.id, person: .existing(id: person.id)))

    _ = try session.people.update(
      PersonUpdate(id: person.id, name: "Анна Петрова", phone: "", notes: ""))
    _ = try session.people.archive(person.id)
    let events = try session.history.itemHistory(itemId: item.item.id)
    #expect(events.first?.personName == "Анна Петрова")

    let personEvents = try session.history.personHistory(personId: person.id)
    #expect(personEvents.count == 1)
    #expect(personEvents.first?.itemName == "Куртка")
  }

  @Test("История отсутствующей вещи и человека — validationNotFound")
  func missingEntities() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    do {
      _ = try session.history.itemHistory(itemId: "missing")
      Issue.record("Ожидалась ошибка")
    } catch let error as AppException {
      #expect(error.code == .validationNotFound)
    }
    do {
      _ = try session.history.personHistory(personId: "missing")
      Issue.record("Ожидалась ошибка")
    } catch let error as AppException {
      #expect(error.code == .validationNotFound)
    }
  }
}
