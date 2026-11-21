import Foundation
import GRDB

public final class ItemActionServiceImpl: ItemActions, @unchecked Sendable {
  private let db: InventoryDatabase
  private let items: any ItemService
  private let clock: any Clock
  private let ids: any IdGenerator
  private let mutations: MutationBus

  public init(
    database: InventoryDatabase,
    items: any ItemService,
    clock: any Clock,
    ids: any IdGenerator,
    mutations: MutationBus
  ) {
    self.db = database
    self.items = items
    self.clock = clock
    self.ids = ids
    self.mutations = mutations
  }

  public func changeStatus(_ command: ChangeStatusCommand) throws -> ItemDetails {
    try db.write { database in
      let item = try requireItem(database, id: command.itemId)
      let target = try requireStatus(database, id: command.toStatusId)
      guard !target.isArchived else {
        throw AppException(.statusArchived, params: ["statusId": .string(target.id)])
      }
      guard target.id != item.item.statusId else {
        throw AppException(.statusUnchanged, params: ["statusId": .string(target.id)])
      }

      let now = clock.nowMilliseconds()
      let historyId = ids.next()
      try database.execute(
        sql: """
          INSERT INTO status_changes
            (id, item_id, from_status_id, to_status_id, comment, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [historyId, item.item.id, item.item.statusId, target.id, command.comment, now]
      )
      try database.execute(
        sql: "UPDATE items SET status_id = ?, updated_at = ? WHERE id = ?",
        arguments: [target.id, now, item.item.id]
      )
    }
    mutations.emit(.itemsChanged(itemIds: [command.itemId], kind: .updated))
    return try items.get(command.itemId)
  }

  public func give(_ command: GiveCommand) throws -> ItemDetails {
    var createdPersonId: String?
    try db.write { database in
      let item = try requireItem(database, id: command.itemId)
      let now = clock.nowMilliseconds()
      let personId = try resolvePerson(
        database,
        choice: command.person,
        now: now,
        createdPersonId: &createdPersonId
      )

      let targetStatus: Status?
      if command.changeStatus {
        let statusId: String?
        if let requested = command.statusId {
          statusId = requested
        } else {
          statusId = try StatusRepository.setting(database, key: "transfer_status_id")
        }
        guard let statusId, !statusId.isEmpty else {
          throw AppException(
            .validationNotFound,
            params: ["entity": .string("status"), "id": .string("transfer_status_id")]
          )
        }
        let status = try requireStatus(database, id: statusId)
        guard !status.isArchived else {
          throw AppException(.statusArchived, params: ["statusId": .string(status.id)])
        }
        targetStatus = status
      } else {
        targetStatus = nil
      }

      try insertTransfer(
        database,
        itemId: item.item.id,
        kind: "give",
        personId: personId,
        comment: command.comment,
        createdAt: now
      )

      let statusChanged = targetStatus.map { $0.id != item.item.statusId } ?? false
      if statusChanged, let targetStatus {
        try insertStatusChange(
          database,
          itemId: item.item.id,
          fromStatusId: item.item.statusId,
          toStatusId: targetStatus.id,
          comment: "",
          createdAt: now
        )
        try database.execute(
          sql: "UPDATE items SET status_id = ?, updated_at = ? WHERE id = ?",
          arguments: [targetStatus.id, now, item.item.id]
        )
      }

      if command.clearPlace {
        try database.execute(
          sql: "UPDATE items SET place_id = NULL, updated_at = ? WHERE id = ?",
          arguments: [now, item.item.id]
        )
      } else if !statusChanged {
        try database.execute(
          sql: "UPDATE items SET updated_at = ? WHERE id = ?",
          arguments: [now, item.item.id]
        )
      }
    }

    mutations.emit(.itemsChanged(itemIds: [command.itemId], kind: .updated))
    if let createdPersonId {
      mutations.emit(.peopleChanged(personIds: [createdPersonId], kind: .created))
    }
    return try items.get(command.itemId)
  }

  public func returnItem(_ command: ReturnCommand) throws -> ItemDetails {
    try db.write { database in
      let item = try requireItem(database, id: command.itemId)
      guard
        let person = try PeopleRepository.findOne(database, id: command.personId)
      else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("person"), "id": .string(command.personId)]
        )
      }
      if person.isArchived,
        try !PeopleRepository.hasTransfer(
          database, itemId: item.item.id, personId: person.id
        )
      {
        // D03: архивный человек допустим только из истории этой вещи.
        throw AppException(.personArchived, params: ["personId": .string(person.id)])
      }

      let targetStatus: Status?
      if let statusId = command.statusId {
        let status = try requireStatus(database, id: statusId)
        guard !status.isArchived else {
          throw AppException(.statusArchived, params: ["statusId": .string(status.id)])
        }
        targetStatus = status
      } else {
        targetStatus = nil
      }

      let newPlaceId: String?
      let changesPlace: Bool
      switch command.place {
      case .keep:
        newPlaceId = item.item.placeId
        changesPlace = false
      case .clear:
        newPlaceId = nil
        changesPlace = true
      case .place(let placeId):
        guard try PlaceRepository.findOne(database, id: placeId) != nil else {
          throw AppException(
            .validationNotFound,
            params: ["entity": .string("place"), "id": .string(placeId)]
          )
        }
        newPlaceId = placeId
        changesPlace = placeId != item.item.placeId
      }

      let now = clock.nowMilliseconds()
      try insertTransfer(
        database,
        itemId: item.item.id,
        kind: "return",
        personId: person.id,
        comment: command.comment,
        createdAt: now
      )

      let statusChanged = targetStatus.map { $0.id != item.item.statusId } ?? false
      if statusChanged, let targetStatus {
        let historyId = ids.next()
        try insertStatusChange(
          database,
          historyId: historyId,
          itemId: item.item.id,
          fromStatusId: item.item.statusId,
          toStatusId: targetStatus.id,
          comment: "",
          createdAt: now
        )
        try database.execute(
          sql: "UPDATE items SET status_id = ?, updated_at = ? WHERE id = ?",
          arguments: [targetStatus.id, now, item.item.id]
        )
      }

      if changesPlace {
        try database.execute(
          sql: "UPDATE items SET place_id = ?, updated_at = ? WHERE id = ?",
          arguments: [newPlaceId, now, item.item.id]
        )
      } else if !statusChanged {
        try database.execute(
          sql: "UPDATE items SET updated_at = ? WHERE id = ?",
          arguments: [now, item.item.id]
        )
      }
    }

    mutations.emit(.itemsChanged(itemIds: [command.itemId], kind: .updated))
    return try items.get(command.itemId)
  }

  // MARK: - Внутренние шаги

  private func requireItem(_ db: Database, id: String) throws -> ItemRow {
    guard let item = try ItemRepository.findOne(db, id: id) else {
      throw AppException(
        .validationNotFound,
        params: ["entity": .string("item"), "id": .string(id)]
      )
    }
    return item
  }

  private func requireStatus(_ db: Database, id: String) throws -> Status {
    guard let status = try StatusRepository.findOne(db, id: id) else {
      throw AppException(
        .validationNotFound,
        params: ["entity": .string("status"), "id": .string(id)]
      )
    }
    return status
  }

  private func resolvePerson(
    _ db: Database,
    choice: PersonChoice,
    now: Int64,
    createdPersonId: inout String?
  ) throws -> String {
    switch choice {
    case .existing(let id):
      guard let person = try PeopleRepository.findOne(db, id: id) else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("person"), "id": .string(id)]
        )
      }
      guard !person.isArchived else {
        throw AppException(.personArchived, params: ["personId": .string(person.id)])
      }
      return person.id
    case .new(let name, let phone, let notes, let duplicateConfirmed):
      let key = try NameKey.parse(name, field: "personName")
      if let existing = try PeopleRepository.findOne(db, nameKey: key.value) {
        guard duplicateConfirmed else {
          throw AppException(
            .personNameDuplicate,
            params: ["personId": .string(existing.id), "name": .string(existing.name)]
          )
        }
      }
      let person = Person(
        id: ids.next(),
        name: key.displayName,
        phone: phone,
        notes: notes,
        isArchived: false,
        createdAt: now,
        updatedAt: now
      )
      try PeopleRepository.insert(db, person: person)
      createdPersonId = person.id
      return person.id
    }
  }

  private func insertTransfer(
    _ db: Database,
    itemId: String,
    kind: String,
    personId: String,
    comment: String,
    createdAt: Int64
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO transfers (id, item_id, kind, person_id, comment, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [ids.next(), itemId, kind, personId, comment, createdAt]
    )
  }

  private func insertStatusChange(
    _ db: Database,
    itemId: String,
    fromStatusId: String,
    toStatusId: String,
    comment: String,
    createdAt: Int64
  ) throws {
    try insertStatusChange(
      db,
      historyId: ids.next(),
      itemId: itemId,
      fromStatusId: fromStatusId,
      toStatusId: toStatusId,
      comment: comment,
      createdAt: createdAt
    )
  }

  private func insertStatusChange(
    _ db: Database,
    historyId: String,
    itemId: String,
    fromStatusId: String,
    toStatusId: String,
    comment: String,
    createdAt: Int64
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO status_changes
          (id, item_id, from_status_id, to_status_id, comment, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [historyId, itemId, fromStatusId, toStatusId, comment, createdAt]
    )
  }
}
