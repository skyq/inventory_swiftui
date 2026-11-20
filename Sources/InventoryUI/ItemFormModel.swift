import AppKit
import Foundation
import InventoryCore

public enum ItemFormMode: Sendable, Equatable {
  case create(placeId: String?)
  case edit(ItemDetails)

  public var editingDetails: ItemDetails? {
    if case .edit(let details) = self { return details }
    return nil
  }
}

public struct ItemFormPresentation: Identifiable {
  public let id = UUID()
  public let mode: ItemFormMode

  public init(mode: ItemFormMode) {
    self.mode = mode
  }
}

public enum ItemFormAlert: Identifiable {
  case failure(String)

  public var id: String {
    switch self {
    case .failure(let message): return "failure-\(message)"
    }
  }
}

/// Состояние модальной формы вещи. Файлы появляются только при сохранении.
@MainActor
public final class ItemFormModel: ObservableObject {
  public let mode: ItemFormMode

  @Published public var name: String
  @Published public var description: String
  @Published public var notes: String
  @Published public var quantity: Int
  @Published public var placeId: String?
  @Published public var statusId: String?
  @Published public var tagInput = ""

  @Published public private(set) var placeChoices: [PlaceParentChoice] = []
  @Published public private(set) var activeStatuses: [Status] = []
  @Published public private(set) var selectedTags: [String] = []
  @Published public private(set) var tagSuggestions: [TagSuggestion] = []
  @Published public private(set) var isProcessingPhoto = false
  @Published public private(set) var isSaving = false
  @Published public private(set) var didSave = false
  @Published public private(set) var previewImage: NSImage?
  @Published public var alert: ItemFormAlert?

  private let items: any ItemService
  private let tags: any TagService
  private let statuses: any StatusService
  private let places: any PlaceService
  private let images: any ImageProcessor
  private let dialogs: any FileDialogs
  private let photos: any PhotoStore

  private var preparedPhoto: ProcessedPhoto?
  private var existingThumbURL: URL?
  private var referencesLoaded = false

  public init(
    mode: ItemFormMode,
    items: any ItemService,
    tags: any TagService,
    statuses: any StatusService,
    places: any PlaceService,
    images: any ImageProcessor,
    dialogs: any FileDialogs,
    photos: any PhotoStore
  ) {
    self.mode = mode
    self.items = items
    self.tags = tags
    self.statuses = statuses
    self.places = places
    self.images = images
    self.dialogs = dialogs
    self.photos = photos

    switch mode {
    case .create(let placeId):
      self.name = ""
      self.description = ""
      self.notes = ""
      self.quantity = 1
      self.placeId = placeId
      self.statusId = nil
    case .edit(let details):
      self.name = details.item.name
      self.description = details.item.description
      self.notes = details.item.notes
      self.quantity = details.item.quantity
      self.placeId = details.item.placeId
      self.statusId = details.item.statusId
      self.selectedTags = details.tags.map(\.name)
      self.existingThumbURL = try? photos.fileURL(for: details.item.thumbFile)
    }
  }

  public var isEditing: Bool {
    mode.editingDetails != nil
  }

  public var title: String {
    isEditing ? L10n.string("items.editTitle") : L10n.string("items.newTitle")
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var nameIsTooLong: Bool {
    trimmedName.count > NameKey.maxLength
  }

  public var hasPhoto: Bool {
    preparedPhoto != nil || existingThumbURL != nil
  }

  public var canSave: Bool {
    !trimmedName.isEmpty
      && !nameIsTooLong
      && quantity >= 1
      && hasPhoto
      && !isProcessingPhoto
      && !isSaving
  }

  /// Статус в режиме редактирования только для чтения.
  public var readOnlyStatusName: String? {
    guard let details = mode.editingDetails else { return nil }
    let suffix = details.status.isArchived ? " (\(L10n.string("gallery.archived")))" : ""
    return details.status.name + suffix
  }

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

    let placesService = places
    let statusesService = statuses
    let tagsService = tags

    async let placesResult = AsyncCore.run { try placesService.all() }
    async let statusesResult = AsyncCore.run { try statusesService.list() }
    async let tagsResult = AsyncCore.run { try tagsService.suggest("", limit: 20) }

    switch await placesResult {
    case .success(let all):
      let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
      placeChoices =
        all
        .map { PlaceParentChoice(id: $0.id, path: pathString(for: $0, byId: byId)) }
        .sorted { NaturalSort.compare($0.path, $1.path) < 0 }
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }

    switch await statusesResult {
    case .success(let list):
      activeStatuses = list
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }

    switch await tagsResult {
    case .success(let list):
      tagSuggestions = list.filter { !selectedTags.contains($0.name) }
    case .failure:
      tagSuggestions = []
    }
  }

  // MARK: - Теги

  public func refreshTagSuggestions() async {
    let query = TagKey.normalize(tagInput)
    let service = tags
    let result = await AsyncCore.run { try service.suggest(query, limit: 8) }
    // Пока запрос выполнялся, пользователь мог изменить ввод.
    guard TagKey.normalize(tagInput) == query, case .success(let list) = result else { return }
    let selectedKeys = Set(selectedTags.map(TagKey.normalize))
    tagSuggestions = list.filter { !selectedKeys.contains(TagKey.normalize($0.name)) }
  }

  public func addTagFromInput() {
    let raw = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return }
    do {
      let key = try TagKey.parse(raw)
      if !selectedTags.contains(where: { TagKey.normalize($0) == key.value }) {
        selectedTags.append(key.displayName)
        selectedTags.sort { NaturalSort.compare($0, $1) < 0 }
      }
      tagInput = ""
      tagSuggestions = []
    } catch let error as AppException {
      alert = .failure(ErrorPresenter.message(for: error))
    } catch {
      alert = .failure(L10n.string("error.internalError"))
    }
  }

  public func selectTagSuggestion(_ suggestion: TagSuggestion) {
    if !selectedTags.contains(where: { TagKey.normalize($0) == TagKey.normalize(suggestion.name) })
    {
      selectedTags.append(suggestion.name)
      selectedTags.sort { NaturalSort.compare($0, $1) < 0 }
    }
    tagInput = ""
    tagSuggestions = []
  }

  public func removeTag(_ name: String) {
    selectedTags.removeAll { $0 == name }
  }

  // MARK: - Фото

  public func choosePhoto() async {
    guard !isProcessingPhoto else { return }
    guard let url = dialogs.chooseImageFile() else { return }
    do {
      let processed = try await PhotoPipeline.process(url: url, images: images)
      preparedPhoto = processed
      previewImage = NSImage(data: processed.thumbBytes) ?? NSImage(data: processed.photoBytes)
    } catch let error as AppException {
      alert = .failure(ErrorPresenter.message(for: error))
    } catch {
      alert = .failure(L10n.string("error.photoReadFailed"))
    }
  }

  /// Cmd+V и кнопка «Вставить»: читает системный буфер обмена.
  public func pastePhoto() async {
    guard !isProcessingPhoto else { return }
    guard let clipboard = PhotoClipboard.read() else {
      alert = .failure(L10n.string("items.pasteEmpty"))
      return
    }
    await applyPhoto(data: clipboard.data, sourceName: clipboard.sourceName)
  }

  public func acceptDrop(providers: [NSItemProvider]) async -> Bool {
    guard !isProcessingPhoto else { return false }
    guard let dropped = await PhotoDrop.load(providers) else { return false }
    await applyPhoto(data: dropped.data, sourceName: dropped.name)
    return true
  }

  private func applyPhoto(data: Data, sourceName: String?) async {
    isProcessingPhoto = true
    defer { isProcessingPhoto = false }
    do {
      let processed = try await PhotoPipeline.process(
        data: data,
        sourceName: sourceName,
        images: images
      )
      preparedPhoto = processed
      previewImage = NSImage(data: processed.thumbBytes) ?? NSImage(data: processed.photoBytes)
    } catch let error as AppException {
      alert = .failure(ErrorPresenter.message(for: error))
    } catch {
      alert = .failure(L10n.string("error.photoReadFailed"))
    }
  }

  // MARK: - Сохранение

  public func save() async {
    guard !isSaving else { return }
    guard !trimmedName.isEmpty else {
      alert = .failure(L10n.string("items.nameRequired"))
      return
    }
    guard trimmedName.count <= NameKey.maxLength else {
      alert = .failure(L10n.format("items.nameMaxLength", NameKey.maxLength))
      return
    }
    guard quantity >= 1 else {
      alert = .failure(L10n.string("items.quantityRange"))
      return
    }
    if !isEditing && preparedPhoto == nil {
      alert = .failure(L10n.string("items.photoRequired"))
      return
    }

    if !tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      addTagFromInput()
      if alert != nil { return }
    }

    let tagNames = selectedTags
    let trimmedName = self.trimmedName
    let description = self.description
    let notes = self.notes
    let quantity = self.quantity
    let placeId = self.placeId
    let photo = preparedPhoto
    let service = items

    isSaving = true
    let result: Result<ItemDetails, AppException>
    switch mode {
    case .create:
      let input = ItemCreate(
        name: trimmedName,
        description: description,
        notes: notes,
        quantity: quantity,
        placeId: placeId,
        statusId: statusId,
        tags: tagNames,
        photo: photo
      )
      result = await AsyncCore.run { try service.create(input) }
    case .edit(let details):
      let input = ItemDetailsUpdate(
        id: details.item.id,
        name: trimmedName,
        description: description,
        notes: notes,
        quantity: quantity,
        placeId: placeId,
        tags: tagNames,
        newPhoto: photo
      )
      result = await AsyncCore.run { try service.updateDetails(input) }
    }
    isSaving = false

    switch result {
    case .success:
      didSave = true
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
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
