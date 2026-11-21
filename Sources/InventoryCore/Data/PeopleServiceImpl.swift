import Foundation
import GRDB

public final class PeopleServiceImpl: PeopleService, @unchecked Sendable {
  private let db: InventoryDatabase
  private let clock: any Clock
  private let ids: any IdGenerator
  private let mutations: MutationBus

  public init(
    database: InventoryDatabase,
    clock: any Clock,
    ids: any IdGenerator,
    mutations: MutationBus
  ) {
    self.db = database
    self.clock = clock
    self.ids = ids
    self.mutations = mutations
  }

  public var changes: AsyncStream<MutationEvent> { mutations.events }

  public func list(includeArchived: Bool) throws -> [Person] {
    try db.read { database in
      try PeopleRepository.all(database, includeArchived: includeArchived)
    }
  }

  public func get(_ id: String) throws -> Person {
    let person = try db.read { database in
      try PeopleRepository.findOne(database, id: id)
    }
    guard let person else { throw notFound(id) }
    return person
  }

  public func create(_ input: PersonCreate, duplicateConfirmed: Bool) throws -> Person {
    let key = try NameKey.parse(input.name, field: "personName")
    let person = try db.write { database -> Person in
      if let existing = try PeopleRepository.findOne(database, nameKey: key.value) {
        guard duplicateConfirmed else {
          throw duplicateError(existing)
        }
      }
      let now = clock.nowMilliseconds()
      let person = Person(
        id: ids.next(),
        name: key.displayName,
        phone: input.phone,
        notes: input.notes,
        isArchived: false,
        createdAt: now,
        updatedAt: now
      )
      try PeopleRepository.insert(database, person: person)
      return person
    }
    mutations.emit(.peopleChanged(personIds: [person.id], kind: .created))
    return person
  }

  public func update(_ input: PersonUpdate, duplicateConfirmed: Bool) throws -> Person {
    let key = try NameKey.parse(input.name, field: "personName")
    let person = try db.write { database -> Person in
      guard try PeopleRepository.findOne(database, id: input.id) != nil else {
        throw notFound(input.id)
      }
      if let existing = try PeopleRepository.findOne(
        database, nameKey: key.value, excluding: input.id
      ) {
        guard duplicateConfirmed else {
          throw duplicateError(existing)
        }
      }
      try PeopleRepository.update(
        database,
        id: input.id,
        name: key.displayName,
        phone: input.phone,
        notes: input.notes,
        updatedAt: clock.nowMilliseconds()
      )
      return try requirePerson(database, id: input.id)
    }
    mutations.emit(.peopleChanged(personIds: [person.id], kind: .updated))
    return person
  }

  public func archive(_ id: String) throws -> Person {
    let person = try db.write { database -> Person in
      guard let existing = try PeopleRepository.findOne(database, id: id) else {
        throw notFound(id)
      }
      guard !existing.isArchived else {
        throw AppException(.personArchived, params: ["personId": .string(id)])
      }
      try PeopleRepository.setArchived(
        database, id: id, archived: true, updatedAt: clock.nowMilliseconds())
      return try requirePerson(database, id: id)
    }
    mutations.emit(.peopleChanged(personIds: [person.id], kind: .updated))
    return person
  }

  public func restore(_ id: String) throws -> Person {
    let person = try db.write { database -> Person in
      guard let existing = try PeopleRepository.findOne(database, id: id) else {
        throw notFound(id)
      }
      guard existing.isArchived else { return existing }
      try PeopleRepository.setArchived(
        database, id: id, archived: false, updatedAt: clock.nowMilliseconds())
      return try requirePerson(database, id: id)
    }
    mutations.emit(.peopleChanged(personIds: [person.id], kind: .updated))
    return person
  }

  public func lastGivenPersonId(itemId: String) throws -> String? {
    try db.read { database in
      guard try ItemRepository.findOne(database, id: itemId) != nil else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("item"), "id": .string(itemId)]
        )
      }
      return try PeopleRepository.lastGivenPersonId(database, itemId: itemId)
    }
  }

  // MARK: - Внутренние шаги

  private func requirePerson(_ db: Database, id: String) throws -> Person {
    guard let person = try PeopleRepository.findOne(db, id: id) else {
      throw notFound(id)
    }
    return person
  }

  private func notFound(_ id: String) -> AppException {
    AppException(
      .validationNotFound,
      params: ["entity": .string("person"), "id": .string(id)]
    )
  }

  private func duplicateError(_ person: Person) -> AppException {
    AppException(
      .personNameDuplicate,
      params: ["personId": .string(person.id), "name": .string(person.name)]
    )
  }
}
