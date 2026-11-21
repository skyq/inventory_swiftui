import Foundation

public enum HistoryEventKind: String, Sendable, CaseIterable {
  case statusChange = "status"
  case give = "give"
  case returnTransfer = "return"
}

/// Событие единой ленты вещи. Имена статуса и человека читаются по текущим id.
public struct ItemHistoryEntry: Identifiable, Sendable, Equatable {
  public let id: String
  public let kind: HistoryEventKind
  public let occurredAt: Int64
  public let comment: String
  public let fromStatusName: String?
  public let toStatusName: String?
  public let personId: String?
  public let personName: String?

  public init(
    id: String,
    kind: HistoryEventKind,
    occurredAt: Int64,
    comment: String,
    fromStatusName: String? = nil,
    toStatusName: String? = nil,
    personId: String? = nil,
    personName: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.occurredAt = occurredAt
    self.comment = comment
    self.fromStatusName = fromStatusName
    self.toStatusName = toStatusName
    self.personId = personId
    self.personName = personName
  }
}

/// Передача или возврат в карточке человека.
public struct PersonHistoryEntry: Identifiable, Sendable, Equatable {
  public let id: String
  public let kind: HistoryEventKind
  public let occurredAt: Int64
  public let comment: String
  public let itemId: String
  public let itemName: String

  public init(
    id: String,
    kind: HistoryEventKind,
    occurredAt: Int64,
    comment: String,
    itemId: String,
    itemName: String
  ) {
    self.id = id
    self.kind = kind
    self.occurredAt = occurredAt
    self.comment = comment
    self.itemId = itemId
    self.itemName = itemName
  }
}

/// Только чтение: изменения истории не предусмотрены ни кодом, ни SQL-триггерами.
public protocol HistoryReadService: Sendable {
  /// Смена статусов и передачи/возвраты, новые сверху.
  func itemHistory(itemId: String) throws -> [ItemHistoryEntry]
  /// Передачи и возвраты человека, новые сверху.
  func personHistory(personId: String) throws -> [PersonHistoryEntry]
}
