import AppKit
import Foundation
import InventoryCore

public struct PlaceParentChoice: Identifiable, Sendable, Equatable {
  public let id: String
  public let path: String
}

public enum PlaceFormAlert: Identifiable {
  case duplicate(String)
  case failure(String)

  public var id: String {
    switch self {
    case .duplicate(let name): return "duplicate-\(name)"
    case .failure(let message): return "failure-\(message)"
    }
  }
}

/// Состояние модальной формы места. Файлы фото создаются только при сохранении.
@MainActor
public final class PlaceFormModel: ObservableObject {
  public let mode: PlaceFormMode
  @Published public var name: String
  @Published public var description: String
  @Published public var parentId: String?
  @Published public private(set) var parentChoices: [PlaceParentChoice] = []
  @Published public private(set) var isProcessingPhoto = false
  @Published public private(set) var isSaving = false
  @Published public private(set) var didSave = false
  @Published public private(set) var previewImage: NSImage?
  @Published public var alert: PlaceFormAlert?

  private let places: any PlaceService
  private let images: any ImageProcessor
  private let dialogs: any FileDialogs
  private let photos: any PhotoStore
  private let existingThumbURL: URL?
  private var preparedPhoto: ProcessedPhoto?
  private var referencesLoaded = false

  public init(
    mode: PlaceFormMode,
    places: any PlaceService,
    images: any ImageProcessor,
    dialogs: any FileDialogs,
    photos: any PhotoStore
  ) {
    self.mode = mode
    self.places = places
    self.images = images
    self.dialogs = dialogs
    self.photos = photos

    switch mode {
    case .create(let parentId):
      self.name = ""
      self.description = ""
      self.parentId = parentId
      self.existingThumbURL = nil
    case .edit(let place):
      self.name = place.name
      self.description = place.description
      self.parentId = place.parentId
      self.existingThumbURL = place.thumbFile.flatMap { try? photos.fileURL(for: $0) }
    }
  }

  public var title: String {
    switch mode {
    case .create: return L10n.string("placeForm.newTitle")
    case .edit: return L10n.string("placeForm.editTitle")
    }
  }

  public var isEditing: Bool {
    mode.editingPlace != nil
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var hasPhoto: Bool {
    preparedPhoto != nil || existingThumbURL != nil
  }

  public var canSave: Bool {
    !trimmedName.isEmpty
      && trimmedName.count <= NameKey.maxLength
      && hasPhoto
      && !isProcessingPhoto
      && !isSaving
  }

  public var nameIsTooLong: Bool {
    trimmedName.count > NameKey.maxLength
  }

  /// Загружает варианты родителя и превью текущего фото.
  public func loadReferences() async {
    guard !referencesLoaded else { return }
    referencesLoaded = true

    if let existingThumbURL,
      let data = try? await Task.detached(
        priority: .userInitiated,
        operation: {
          try Data(contentsOf: existingThumbURL)
        }
      ).value
    {
      previewImage = NSImage(data: data)
    }

    let service = places
    let editingId = mode.editingPlace?.id
    let allResult = await AsyncCore.run { try service.all() }
    let invalidResult = await AsyncCore.run { try service.invalidParentIds(for: editingId) }

    switch allResult {
    case .success(let all):
      let invalid: Set<String>
      switch invalidResult {
      case .success(let ids): invalid = ids
      case .failure(let error):
        invalid = []
        alert = .failure(ErrorPresenter.message(for: error))
      }
      let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
      parentChoices =
        all
        .filter { !invalid.contains($0.id) }
        .map { PlaceParentChoice(id: $0.id, path: pathString(for: $0, byId: byId)) }
        .sorted { NaturalSort.compare($0.path, $1.path) < 0 }
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }
  }

  /// Отмена диалога не меняет текущее фото.
  public func choosePhoto() async {
    guard !isProcessingPhoto else { return }
    guard let url = dialogs.chooseImageFile() else { return }

    isProcessingPhoto = true
    defer { isProcessingPhoto = false }

    do {
      let data = try await Task.detached(
        priority: .userInitiated,
        operation: {
          try Data(contentsOf: url)
        }
      ).value
      let processed = try await images.process(
        PhotoInput(bytes: data, sourceName: url.lastPathComponent)
      )
      preparedPhoto = processed
      previewImage = NSImage(data: processed.thumbBytes) ?? NSImage(data: processed.photoBytes)
    } catch let error as AppException {
      alert = .failure(ErrorPresenter.message(for: error))
    } catch {
      alert = .failure(L10n.string("error.photoReadFailed"))
    }
  }

  public func save(duplicateConfirmed: Bool = false) async {
    guard !isSaving else { return }
    guard !trimmedName.isEmpty else {
      alert = .failure(L10n.string("places.nameRequired"))
      return
    }
    guard trimmedName.count <= NameKey.maxLength else {
      alert = .failure(L10n.format("places.nameMaxLength", NameKey.maxLength))
      return
    }
    guard hasPhoto else {
      alert = .failure(L10n.string("places.photoRequired"))
      return
    }

    isSaving = true
    let name = trimmedName
    let description = self.description
    let parentId = self.parentId
    let photo = preparedPhoto
    let service = places

    let result: Result<Place, AppException>
    switch mode {
    case .create:
      let input = PlaceCreate(
        name: name,
        description: description,
        parentId: parentId,
        photo: photo
      )
      result = await AsyncCore.run {
        try service.create(input, duplicateConfirmed: duplicateConfirmed)
      }
    case .edit(let place):
      let input = PlaceDetailsUpdate(
        id: place.id,
        name: name,
        description: description,
        parentId: parentId,
        newPhoto: photo
      )
      result = await AsyncCore.run {
        try service.updateDetails(input, duplicateConfirmed: duplicateConfirmed)
      }
    }

    isSaving = false

    switch result {
    case .success:
      didSave = true
    case .failure(let error):
      if error.code == .duplicateName && !duplicateConfirmed {
        alert = .duplicate(name)
      } else {
        alert = .failure(ErrorPresenter.message(for: error))
      }
    }
  }

  private func pathString(for place: Place, byId: [String: Place]) -> String {
    var names: [String] = []
    var visited: Set<String> = []
    var current: Place? = place
    while let cursor = current, visited.insert(cursor.id).inserted {
      names.append(cursor.name)
      current = cursor.parentId.flatMap { byId[$0] }
    }
    return names.reversed().joined(separator: " / ")
  }
}
