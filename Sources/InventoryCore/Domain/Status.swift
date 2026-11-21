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

/// Значения трёх настроек статусов. Всегда указывают на активные статусы.
public struct StatusSettings: Sendable, Equatable {
  public let defaultStatusId: String
  public let transferStatusId: String
  public let returnStatusId: String

  public init(defaultStatusId: String, transferStatusId: String, returnStatusId: String) {
    self.defaultStatusId = defaultStatusId
    self.transferStatusId = transferStatusId
    self.returnStatusId = returnStatusId
  }

  public var statusIds: Set<String> {
    [defaultStatusId, transferStatusId, returnStatusId]
  }
}

public protocol StatusService: Sendable {
  /// Только активные по умолчанию. Порядок: sortOrder, естественное имя, id.
  func list(includeArchived: Bool) throws -> [Status]
  /// Возвращает и архивный статус: он нужен для read-only карточки и формы.
  func get(_ id: String) throws -> Status
  func create(name: String) throws -> Status
  func rename(_ id: String, to name: String) throws -> Status
  /// Если статус используется в настройках, замена обязательна и должна быть активной.
  func archive(_ id: String, replacementId: String?) throws -> Status
  /// Настройки при восстановлении не возвращаются автоматически.
  func restore(_ id: String) throws -> Status
  var changes: AsyncStream<MutationEvent> { get }
}

extension StatusService {
  public func list() throws -> [Status] {
    try list(includeArchived: false)
  }

  public func archive(_ id: String) throws -> Status {
    try archive(id, replacementId: nil)
  }
}

/// Настройки default/transfer/return_status_id в таблице settings.
public protocol StatusSettingsService: Sendable {
  func settings() throws -> StatusSettings
  /// Все три id должны существовать и быть активными.
  func update(_ settings: StatusSettings) throws
}
