import Foundation
import GRDB

public final class HistoryReadServiceImpl: HistoryReadService, @unchecked Sendable {
  private let db: InventoryDatabase

  public init(database: InventoryDatabase) {
    self.db = database
  }

  public func itemHistory(itemId: String) throws -> [ItemHistoryEntry] {
    try db.read { database in
      guard try ItemRepository.findOne(database, id: itemId) != nil else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("item"), "id": .string(itemId)]
        )
      }

      let statusChanges = try Row.fetchAll(
        database,
        sql: """
          SELECT sc.id, sc.created_at, sc.comment,
                 fs.name AS from_name, ts.name AS to_name
          FROM status_changes sc
          JOIN statuses fs ON fs.id = sc.from_status_id
          JOIN statuses ts ON ts.id = sc.to_status_id
          WHERE sc.item_id = ?
          """,
        arguments: [itemId]
      ).map { row in
        ItemHistoryEntry(
          id: row["id"],
          kind: .statusChange,
          occurredAt: row["created_at"],
          comment: row["comment"],
          fromStatusName: row["from_name"],
          toStatusName: row["to_name"]
        )
      }

      let transfers = try Row.fetchAll(
        database,
        sql: """
          SELECT t.id, t.kind, t.created_at, t.comment, p.id AS person_id, p.name AS person_name
          FROM transfers t
          JOIN people p ON p.id = t.person_id
          WHERE t.item_id = ?
          """,
        arguments: [itemId]
      ).map { row -> ItemHistoryEntry in
        let kind: String = row["kind"]
        return ItemHistoryEntry(
          id: row["id"],
          kind: kind == "give" ? .give : .returnTransfer,
          occurredAt: row["created_at"],
          comment: row["comment"],
          personId: row["person_id"],
          personName: row["person_name"]
        )
      }

      return (statusChanges + transfers).sorted(by: itemOrder)
    }
  }

  public func personHistory(personId: String) throws -> [PersonHistoryEntry] {
    try db.read { database in
      guard
        try Bool.fetchOne(
          database,
          sql: "SELECT 1 FROM people WHERE id = ?",
          arguments: [personId]
        ) != nil
      else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("person"), "id": .string(personId)]
        )
      }

      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT t.id, t.kind, t.created_at, t.comment, i.id AS item_id, i.name AS item_name
          FROM transfers t
          JOIN items i ON i.id = t.item_id
          WHERE t.person_id = ?
          """,
        arguments: [personId]
      )
      return rows.map { row in
        let kind: String = row["kind"]
        return PersonHistoryEntry(
          id: row["id"],
          kind: kind == "give" ? .give : .returnTransfer,
          occurredAt: row["created_at"],
          comment: row["comment"],
          itemId: row["item_id"],
          itemName: row["item_name"]
        )
      }
      .sorted(by: personOrder)
    }
  }

  /// Новые сверху; при равных миллисекундах передача/возврат выше смены статуса,
  /// затем id ASC — детерминированный порядок (D12).
  private func itemOrder(_ left: ItemHistoryEntry, _ right: ItemHistoryEntry) -> Bool {
    if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
    let leftRank = left.kind == .statusChange ? 1 : 0
    let rightRank = right.kind == .statusChange ? 1 : 0
    if leftRank != rightRank { return leftRank < rightRank }
    return left.id < right.id
  }

  private func personOrder(_ left: PersonHistoryEntry, _ right: PersonHistoryEntry) -> Bool {
    if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
    return left.id < right.id
  }
}
