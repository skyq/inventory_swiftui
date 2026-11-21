import Foundation

public struct Person: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let phone: String
  public let notes: String
  public let isArchived: Bool
  public let createdAt: Int64
  public let updatedAt: Int64

  public init(
    id: String,
    name: String,
    phone: String,
    notes: String,
    isArchived: Bool,
    createdAt: Int64,
    updatedAt: Int64
  ) {
    self.id = id
    self.name = name
    self.phone = phone
    self.notes = notes
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct PersonCreate: Sendable {
  public let name: String
  public let phone: String
  public let notes: String

  public init(name: String, phone: String = "", notes: String = "") {
    self.name = name
    self.phone = phone
    self.notes = notes
  }
}

public struct PersonUpdate: Sendable {
  public let id: String
  public let name: String
  public let phone: String
  public let notes: String

  public init(id: String, name: String, phone: String, notes: String) {
    self.id = id
    self.name = name
    self.phone = phone
    self.notes = notes
  }
}

public protocol PeopleService: Sendable {
  /// Активные по умолчанию, естественная сортировка по имени.
  func list(includeArchived: Bool) throws -> [Person]
  func get(_ id: String) throws -> Person
  /// Совпадающее имя без учёта регистра требует duplicateConfirmed.
  func create(_ input: PersonCreate, duplicateConfirmed: Bool) throws -> Person
  func update(_ input: PersonUpdate, duplicateConfirmed: Bool) throws -> Person
  func archive(_ id: String) throws -> Person
  func restore(_ id: String) throws -> Person
  /// Последний получатель по give для вещи; nil — передач не было.
  func lastGivenPersonId(itemId: String) throws -> String?
  var changes: AsyncStream<MutationEvent> { get }
}

extension PeopleService {
  public func create(_ input: PersonCreate) throws -> Person {
    try create(input, duplicateConfirmed: false)
  }

  public func update(_ input: PersonUpdate) throws -> Person {
    try update(input, duplicateConfirmed: false)
  }

  public func list() throws -> [Person] {
    try list(includeArchived: false)
  }
}
