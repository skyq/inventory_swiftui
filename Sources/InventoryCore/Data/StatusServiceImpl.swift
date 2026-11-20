import Foundation
import GRDB

public final class StatusServiceImpl: StatusService, @unchecked Sendable {
  private let db: InventoryDatabase
  private let mutations: MutationBus

  public init(database: InventoryDatabase, mutations: MutationBus) {
    self.db = database
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
}
