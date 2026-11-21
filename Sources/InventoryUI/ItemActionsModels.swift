import Foundation
import InventoryCore

/// Быстрая смена статуса без обхода истории.
@MainActor
public final class ChangeStatusModel: ObservableObject {
  public let item: ItemDetails
  @Published public private(set) var statuses: [Status] = []
  @Published public var statusId: String?
  @Published public var comment = ""
  @Published public private(set) var isLoading = true
  @Published public private(set) var isSaving = false
  @Published public private(set) var didSave = false
  @Published public var alertMessage: String?

  private let actions: any ItemActions
  private let statusesService: any StatusService

  public init(
    item: ItemDetails,
    actions: any ItemActions,
    statuses: any StatusService
  ) {
    self.item = item
    self.actions = actions
    self.statusesService = statuses
  }

  public var canSave: Bool {
    guard let statusId else { return false }
    return statusId != item.item.statusId && !isLoading && !isSaving
  }

  public func load() async {
    let service = statusesService
    let result = await AsyncCore.run { try service.list() }
    isLoading = false
    switch result {
    case .success(let list):
      statuses = list.filter { $0.id != item.item.statusId }
      statusId = statuses.first?.id
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
    }
  }

  public func save() async {
    guard canSave, let statusId else { return }
    isSaving = true
    let command = ChangeStatusCommand(
      itemId: item.item.id,
      toStatusId: statusId,
      comment: comment
    )
    let service = actions
    let result = await AsyncCore.run { try service.changeStatus(command) }
    isSaving = false
    switch result {
    case .success:
      didSave = true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
    }
  }
}

/// Передача: человек (существующий или новый), комментарий, статус и место.
@MainActor
public final class GiveModel: ObservableObject {
  public let item: ItemDetails
  @Published public private(set) var people: [Person] = []
  @Published public private(set) var statuses: [Status] = []
  @Published public private(set) var isLoading = true
  @Published public private(set) var isSaving = false
  @Published public private(set) var didSave = false
  @Published public var pendingDuplicate = false
  @Published public var alertMessage: String?

  @Published public var selectedPersonId: String?
  @Published public var isCreatingPerson = false
  @Published public var newPersonName = ""
  @Published public var newPersonPhone = ""
  @Published public var newPersonNotes = ""
  @Published public var comment = ""
  @Published public var changeStatus = true
  @Published public var statusId: String?
  @Published public var clearPlace = true

  private let actions: any ItemActions
  private let peopleService: any PeopleService
  private let statusesService: any StatusService
  private let settingsService: any StatusSettingsService

  public init(
    item: ItemDetails,
    actions: any ItemActions,
    people: any PeopleService,
    statuses: any StatusService,
    settings: any StatusSettingsService
  ) {
    self.item = item
    self.actions = actions
    self.peopleService = people
    self.statusesService = statuses
    self.settingsService = settings
  }

  public var canSave: Bool {
    guard !isLoading, !isSaving else { return false }
    let hasPerson =
      isCreatingPerson
      ? !newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      : selectedPersonId != nil
    if !hasPerson { return false }
    if changeStatus && statusId == nil { return false }
    return true
  }

  public var statusIsCurrent: Bool {
    changeStatus && statusId == item.item.statusId
  }

  public func load() async {
    let peopleService = peopleService
    let statusesService = statusesService
    let settingsService = settingsService

    async let peopleResult = AsyncCore.run {
      try peopleService.list(includeArchived: false)
    }
    async let statusesResult = AsyncCore.run {
      try statusesService.list(includeArchived: false)
    }
    async let settingsResult = AsyncCore.run {
      try settingsService.settings()
    }

    let loadedPeople = await peopleResult
    let loadedStatuses = await statusesResult
    let loadedSettings = await settingsResult
    isLoading = false

    switch loadedPeople {
    case .success(let list):
      people = list
      selectedPersonId = list.first?.id
      if list.isEmpty { isCreatingPerson = true }
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
    }

    switch loadedStatuses {
    case .success(let list):
      statuses = list
    case .failure(let error):
      alertMessage = alertMessage ?? ErrorPresenter.message(for: error)
    }

    switch loadedSettings {
    case .success(let settings):
      statusId =
        statuses.first { $0.id == settings.transferStatusId }?.id
        ?? statuses.first?.id
    case .failure(let error):
      statusId = statuses.first?.id
      alertMessage = alertMessage ?? ErrorPresenter.message(for: error)
    }
  }

  public func save(duplicateConfirmed: Bool = false) async {
    guard canSave else { return }
    isSaving = true

    let person: PersonChoice
    if isCreatingPerson {
      person = .new(
        name: newPersonName,
        phone: newPersonPhone,
        notes: newPersonNotes,
        duplicateConfirmed: duplicateConfirmed
      )
    } else if let selectedPersonId {
      person = .existing(id: selectedPersonId)
    } else {
      isSaving = false
      return
    }

    let command = GiveCommand(
      itemId: item.item.id,
      person: person,
      comment: comment,
      changeStatus: changeStatus,
      statusId: changeStatus ? statusId : nil,
      clearPlace: clearPlace
    )
    let service = actions
    let result = await AsyncCore.run { try service.give(command) }
    isSaving = false

    switch result {
    case .success:
      didSave = true
    case .failure(let error):
      if error.code == .personNameDuplicate {
        pendingDuplicate = true
      } else {
        alertMessage = ErrorPresenter.message(for: error)
      }
    }
  }

  public func saveDuplicate() async {
    pendingDuplicate = false
    await save(duplicateConfirmed: true)
  }
}

public enum ReturnPlaceMode: String, CaseIterable, Identifiable, Sendable, Equatable {
  case keep
  case clear
  case place

  public var id: String { rawValue }
}

/// Возврат: последний получатель, комментарий, место и статус.
@MainActor
public final class ReturnModel: ObservableObject {
  public let item: ItemDetails
  @Published public private(set) var people: [Person] = []
  @Published public private(set) var statuses: [Status] = []
  @Published public private(set) var placeChoices: [PlaceParentChoice] = []
  @Published public private(set) var isLoading = true
  @Published public private(set) var isSaving = false
  @Published public private(set) var didSave = false
  @Published public var alertMessage: String?

  @Published public var selectedPersonId: String?
  @Published public var comment = ""
  @Published public var statusId: String?
  @Published public var placeMode: ReturnPlaceMode = .keep
  @Published public var placeId: String?

  private let actions: any ItemActions
  private let peopleService: any PeopleService
  private let statusesService: any StatusService
  private let settingsService: any StatusSettingsService
  private let placesService: any PlaceService
  private let history: any HistoryReadService

  public init(
    item: ItemDetails,
    actions: any ItemActions,
    people: any PeopleService,
    statuses: any StatusService,
    settings: any StatusSettingsService,
    places: any PlaceService,
    history: any HistoryReadService
  ) {
    self.item = item
    self.actions = actions
    self.peopleService = people
    self.statusesService = statuses
    self.settingsService = settings
    self.placesService = places
    self.history = history
  }

  public var canSave: Bool {
    guard !isLoading, !isSaving, selectedPersonId != nil else { return false }
    if placeMode == .place && placeId == nil { return false }
    return true
  }

  public func load() async {
    let peopleService = peopleService
    let statusesService = statusesService
    let settingsService = settingsService
    let placesService = placesService
    let historyService = history
    let itemId = item.item.id

    async let peopleResult = AsyncCore.run {
      try peopleService.list(includeArchived: true)
    }
    async let statusesResult = AsyncCore.run {
      try statusesService.list(includeArchived: false)
    }
    async let settingsResult = AsyncCore.run {
      try settingsService.settings()
    }
    async let placesResult = AsyncCore.run {
      try placesService.all()
    }
    async let historyResult = AsyncCore.run {
      try historyService.itemHistory(itemId: itemId)
    }
    async let lastGivenResult = AsyncCore.run {
      try peopleService.lastGivenPersonId(itemId: itemId)
    }

    let loadedPeople = await peopleResult
    let loadedStatuses = await statusesResult
    let loadedSettings = await settingsResult
    let loadedPlaces = await placesResult
    let loadedHistory = await historyResult
    let loadedLastGiven = await lastGivenResult
    isLoading = false

    var historyPersonIds: Set<String> = []
    if case .success(let events) = loadedHistory {
      historyPersonIds = Set(events.compactMap(\.personId))
    }

    switch loadedPeople {
    case .success(let list):
      // Активные плюс архивные участники истории этой вещи (D03).
      people = list.filter { !$0.isArchived || historyPersonIds.contains($0.id) }
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
    }

    switch loadedLastGiven {
    case .success(let id):
      selectedPersonId = id.flatMap { id in people.contains { $0.id == id } ? id : nil }
    case .failure:
      selectedPersonId = nil
    }
    if selectedPersonId == nil {
      selectedPersonId = people.first?.id
    }

    switch loadedStatuses {
    case .success(let list):
      statuses = list
    case .failure(let error):
      alertMessage = alertMessage ?? ErrorPresenter.message(for: error)
    }

    switch loadedSettings {
    case .success(let settings):
      if settings.returnStatusId != item.item.statusId,
        statuses.contains(where: { $0.id == settings.returnStatusId })
      {
        statusId = settings.returnStatusId
      } else {
        statusId = nil
      }
    case .failure(let error):
      alertMessage = alertMessage ?? ErrorPresenter.message(for: error)
    }

    switch loadedPlaces {
    case .success(let all):
      let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
      placeChoices =
        all
        .map { PlaceParentChoice(id: $0.id, path: pathString(for: $0, byId: byId)) }
        .sorted { NaturalSort.compare($0.path, $1.path) < 0 }
    case .failure(let error):
      alertMessage = alertMessage ?? ErrorPresenter.message(for: error)
    }
  }

  public func save() async {
    guard canSave, let selectedPersonId else { return }
    let place: ReturnPlaceChange
    switch placeMode {
    case .keep: place = .keep
    case .clear: place = .clear
    case .place:
      guard let placeId else { return }
      place = .place(placeId)
    }

    isSaving = true
    let command = ReturnCommand(
      itemId: item.item.id,
      personId: selectedPersonId,
      comment: comment,
      statusId: statusId,
      place: place
    )
    let service = actions
    let result = await AsyncCore.run { try service.returnItem(command) }
    isSaving = false
    switch result {
    case .success:
      didSave = true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
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
