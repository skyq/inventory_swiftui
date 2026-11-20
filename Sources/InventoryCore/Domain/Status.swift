import Foundation

public struct Status: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let isArchived: Bool
  public let sortOrder: Int
  public let createdAt: Int64

  public init(
    id: String,
    name: String,
    isArchived: Bool,
    sortOrder: Int,
    createdAt: Int64
  ) {
    self.id = id
    self.name = name
    self.isArchived = isArchived
    self.sortOrder = sortOrder
    self.createdAt = createdAt
  }
}

/// Чтение статусов на этапе 2; создание, переименование и архивация — этап 3.
public protocol StatusService: Sendable {
  /// Только активные по умолчанию. Порядок: sortOrder, естественное имя, id.
  func list(includeArchived: Bool) throws -> [Status]
  /// Возвращает и архивный статус: он нужен для read-only карточки и формы.
  func get(_ id: String) throws -> Status
  var changes: AsyncStream<MutationEvent> { get }
}

extension StatusService {
  public func list() throws -> [Status] {
    try list(includeArchived: false)
  }
}
