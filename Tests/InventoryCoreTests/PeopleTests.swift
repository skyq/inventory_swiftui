import Foundation
import InventoryCore
import Testing

@Suite("Люди: справочник и архив")
struct PeopleTests {
  @Test("Дубль имени требует явного подтверждения")
  func duplicateRequiresConfirmation() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try session.people.create(PersonCreate(name: "  Анна "))
    #expect(first.name == "Анна")

    do {
      _ = try session.people.create(PersonCreate(name: "АННА"))
      Issue.record("Ожидалось предупреждение о дубле")
    } catch let error as AppException {
      #expect(error.code == .personNameDuplicate)
    }

    let duplicate = try session.people.create(
      PersonCreate(name: "анна", phone: "+7 900"), duplicateConfirmed: true)
    #expect(duplicate.name == "анна")
    #expect(try session.people.list().count == 2)

    do {
      _ = try session.people.update(
        PersonUpdate(id: duplicate.id, name: "Анна", phone: "", notes: ""))
      Issue.record("Переименование в существующее имя требует подтверждения")
    } catch let error as AppException {
      #expect(error.code == .personNameDuplicate)
    }
  }

  @Test("Архивный человек не предлагается, но остаётся в истории")
  func archiveKeepsHistory() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let person = try session.people.create(PersonCreate(name: "Борис"))
    let item = try TestSupport.createItem(session, name: "Палатка")
    _ = try session.actions.give(
      GiveCommand(
        itemId: item.item.id,
        person: .existing(id: person.id),
        comment: "на выходные"
      )
    )

    let archived = try session.people.archive(person.id)
    #expect(archived.isArchived)
    #expect(try session.people.list().isEmpty)
    #expect(try session.people.list(includeArchived: true).count == 1)

    let history = try session.history.personHistory(personId: person.id)
    #expect(history.count == 1)
    #expect(history.first?.itemName == "Палатка")

    // Переименование меняет отображение старой истории по id.
    _ = try session.people.update(
      PersonUpdate(id: person.id, name: "Борис Иванов", phone: "", notes: ""))
    let itemHistory = try session.history.itemHistory(itemId: item.item.id)
    #expect(itemHistory.first?.personName == "Борис Иванов")

    // Архивный человек не участвует в новой передаче.
    do {
      _ = try session.actions.give(
        GiveCommand(itemId: item.item.id, person: .existing(id: person.id))
      )
      Issue.record("Архивный человек не должен предлагаться для новой передачи")
    } catch let error as AppException {
      #expect(error.code == .personArchived)
    }

    let restored = try session.people.restore(person.id)
    #expect(!restored.isArchived)
  }

  @Test("Последний получатель по give определяется по дате")
  func findsLastGivenPerson() throws {
    let clock = MutableTestClock()
    let (session, root) = try TestSupport.makeSession(clock: clock)
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try session.people.create(PersonCreate(name: "Первый"))
    let second = try session.people.create(PersonCreate(name: "Второй"))
    let item = try TestSupport.createItem(session, name: "Фонарь")
    #expect(try session.people.lastGivenPersonId(itemId: item.item.id) == nil)

    _ = try session.actions.give(
      GiveCommand(itemId: item.item.id, person: .existing(id: first.id)))
    clock.advance(by: 1000)
    _ = try session.actions.give(
      GiveCommand(itemId: item.item.id, person: .existing(id: second.id)))
    #expect(try session.people.lastGivenPersonId(itemId: item.item.id) == second.id)
  }

  @Test("Пустое и длинное имя отклоняются")
  func validatesName() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    do {
      _ = try session.people.create(PersonCreate(name: "  "))
      Issue.record("Ожидалась ошибка пустого имени")
    } catch let error as AppException {
      #expect(error.code == .validationRequired)
    }
    do {
      _ = try session.people.create(
        PersonCreate(name: String(repeating: "я", count: NameKey.maxLength + 1)))
      Issue.record("Ожидалась ошибка длины")
    } catch let error as AppException {
      #expect(error.code == .validationTooLong)
    }
  }
}
