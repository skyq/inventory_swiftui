import Foundation
import GRDB

public final class StatusServiceImpl: StatusService, StatusSettingsService, @unchecked Sendable {
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

  public func list(includeArchived: Bool) throws -> [Status] {
    try db.read { database in
      try StatusRepository.list(database, includeArchived: includeArchived)
    }
  }

  public func get(_ id: String) throws -> Status {
    let status = try db.read { database in
      try StatusRepository.findOne(database, id: id)
    }
    guard let status else {
      throw AppException(
        .validationNotFound,
        params: ["entity": .string("status"), "id": .string(id)]
      )
    }
    return status
  }

  public func create(name: String) throws -> Status {
    let key = try NameKey.parse(name, field: "statusName")
    let status = try db.write { database -> Status in
      try ensureNameAvailable(database, key: key, except: nil)
      let status = Status(
        id: ids.next(),
        name: key.displayName,
        isArchived: false,
        sortOrder: try StatusRepository.nextSortOrder(database),
        createdAt: clock.nowMilliseconds()
      )
      try StatusRepository.insert(database, status: status)
      return status
    }
    mutations.emit(.statusesChanged(statusIds: [status.id], kind: .created))
    return status
  }

  public func rename(_ id: String, to name: String) throws -> Status {
    let key = try NameKey.parse(name, field: "statusName")
    let status = try db.write { database -> Status in
      guard try StatusRepository.findOne(database, id: id) != nil else {
        throw notFound(id)
      }
      try ensureNameAvailable(database, key: key, except: id)
      try StatusRepository.rename(database, id: id, name: key.displayName)
      return try requireStatus(database, id: id)
    }
    mutations.emit(.statusesChanged(statusIds: [status.id], kind: .updated))
    return status
  }

  public func archive(_ id: String, replacementId: String?) throws -> Status {
    let status = try db.write { database -> Status in
      guard let existing = try StatusRepository.findOne(database, id: id) else {
        throw notFound(id)
      }
      guard !existing.isArchived else {
        throw AppException(.statusArchived, params: ["statusId": .string(id)])
      }

      let settings = try StatusRepository.settings(database)
      let usesStatus =
        settings.defaultStatusId == id || settings.transferStatusId == id
        || settings.returnStatusId == id

      if usesStatus {
        guard let replacementId else {
          throw AppException(.statusInUse, params: ["statusId": .string(id)])
        }
        guard replacementId != id else {
          throw AppException(.statusInUse, params: ["statusId": .string(id)])
        }
        let replacement = try requireStatus(database, id: replacementId)
        guard !replacement.isArchived else {
          throw AppException(.statusArchived, params: ["statusId": .string(replacementId)])
        }
        if settings.defaultStatusId == id {
          try StatusRepository.setSetting(
            database, key: "default_status_id", value: replacementId)
        }
        if settings.transferStatusId == id {
          try StatusRepository.setSetting(
            database, key: "transfer_status_id", value: replacementId)
        }
        if settings.returnStatusId == id {
          try StatusRepository.setSetting(
            database, key: "return_status_id", value: replacementId)
        }
      }

      try StatusRepository.setArchived(database, id: id, archived: true)
      return try requireStatus(database, id: id)
    }
    mutations.emit(.statusesChanged(statusIds: [status.id], kind: .updated))
    return status
  }

  public func restore(_ id: String) throws -> Status {
    let status = try db.write { database -> Status in
      guard let existing = try StatusRepository.findOne(database, id: id) else {
        throw notFound(id)
      }
      guard existing.isArchived else { return existing }
      try StatusRepository.setArchived(database, id: id, archived: false)
      return try requireStatus(database, id: id)
    }
    mutations.emit(.statusesChanged(statusIds: [status.id], kind: .updated))
    return status
  }

  public func setHidden(_ id: String, hidden: Bool) throws -> Status {
    let status = try db.write { database -> Status in
      guard let existing = try StatusRepository.findOne(database, id: id) else {
        throw notFound(id)
      }
      guard existing.isHidden != hidden else { return existing }
      try StatusRepository.setHidden(database, id: id, hidden: hidden)
      return try requireStatus(database, id: id)
    }
    mutations.emit(.statusesChanged(statusIds: [status.id], kind: .updated))
    return status
  }

  public func settings() throws -> StatusSettings {
    try db.read { database in
      try StatusRepository.settings(database)
    }
  }

  public func update(_ settings: StatusSettings) throws {
    let allIds = [
      settings.defaultStatusId, settings.transferStatusId, settings.returnStatusId,
    ]
    try db.write { database in
      for id in allIds {
        let status = try requireStatus(database, id: id)
        guard !status.isArchived else {
          throw AppException(.statusArchived, params: ["statusId": .string(id)])
        }
      }
      try StatusRepository.setSetting(
        database, key: "default_status_id", value: settings.defaultStatusId)
      try StatusRepository.setSetting(
        database, key: "transfer_status_id", value: settings.transferStatusId)
      try StatusRepository.setSetting(
        database, key: "return_status_id", value: settings.returnStatusId)
    }
    mutations.emit(
      .statusesChanged(
        statusIds: Set(allIds),
        kind: .updated
      )
    )
  }

  // MARK: - Внутренние шаги

  private func ensureNameAvailable(_ db: Database, key: NameKey, except id: String?) throws {
    guard let existing = try StatusRepository.findOne(db, nameKey: key.value) else { return }
    if existing.id == id { return }
    throw AppException(
      .statusNameDuplicate,
      params: ["statusId": .string(existing.id), "name": .string(key.displayName)]
    )
  }

  private func requireStatus(_ db: Database, id: String) throws -> Status {
    guard let status = try StatusRepository.findOne(db, id: id) else {
      throw notFound(id)
    }
    return status
  }

  private func notFound(_ id: String) -> AppException {
    AppException(
      .validationNotFound,
      params: ["entity": .string("status"), "id": .string(id)]
    )
  }
}
