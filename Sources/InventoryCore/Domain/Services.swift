import Foundation

public protocol PlaceService: Sendable {
  func create(_ input: PlaceCreate, duplicateConfirmed: Bool) throws -> Place
  func get(_ id: String) throws -> Place
  func updateDetails(_ input: PlaceDetailsUpdate, duplicateConfirmed: Bool) throws -> Place
  func move(_ id: String, newParentId: String?) throws -> Place
  func deleteEmpty(_ id: String) throws
  func children(of parentId: String?) throws -> [Place]
  func descendants(of id: String) throws -> [Place]
  func path(to id: String) throws -> PlacePath
  func all() throws -> [Place]
  /// Недоступные родители для формы: само место и все потомки.
  func invalidParentIds(for placeId: String?) throws -> Set<String>
  var changes: AsyncStream<MutationEvent> { get }
}

extension PlaceService {
  public func create(_ input: PlaceCreate) throws -> Place {
    try create(input, duplicateConfirmed: false)
  }

  public func updateDetails(_ input: PlaceDetailsUpdate) throws -> Place {
    try updateDetails(input, duplicateConfirmed: false)
  }
}

@MainActor
public protocol FileDialogs: Sendable {
  /// nil — пользователь отменил выбор.
  func chooseDirectory(startingAt url: URL?) -> URL?
  /// nil — пользователь отменил выбор.
  func chooseImageFile() -> URL?
}
