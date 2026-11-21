import Foundation
import InventoryCore

public enum StatusSettingSlot: String, CaseIterable, Identifiable, Sendable, Equatable {
  case defaultStatus
  case transferStatus
  case returnStatus

  public var id: String { rawValue }
}

/// Справочник статусов и три настройки по умолчанию.
@MainActor
public final class StatusesModel: ObservableObject {
  @Published public private(set) var statuses: [Status] = []
  @Published public private(set) var settings: StatusSettings?
  @Published public var includeArchived = false {
    didSet {
      guard includeArchived != oldValue else { return }
      Task { await reload() }
    }
  }
  @Published public var selectedStatusId: String? {
    didSet {
      guard selectedStatusId != oldValue else { return }
      if selectedStatusId == nil {
        selectedStatus = nil
      } else if let id = selectedStatusId {
        selectedStatus = statuses.first { $0.id == id }
      }
    }
  }
  @Published public private(set) var selectedStatus: Status?
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: AppException?
  @Published public var alertMessage: String?

  private let statusesService: any StatusService
  private let settingsService: any StatusSettingsService
  private var observationTask: Task<Void, Never>?
  private var started = false

  public init(
    statuses: any StatusService,
    settings: any StatusSettingsService
  ) {
    self.statusesService = statuses
    self.settingsService = settings
  }

  deinit {
    observationTask?.cancel()
  }

  public var activeStatuses: [Status] {
    statuses.filter { !$0.isArchived }
  }

  public var archivedStatuses: [Status] {
    statuses.filter(\.isArchived)
  }

  public func start() async {
    if !started {
      started = true
      observationTask = Task { [weak self] in
        guard let stream = self?.statusesService.changes else { return }
        for await _ in stream {
          guard let self else { return }
          await self.reload()
        }
      }
    }
    await reload()
  }

  public func reload() async {
    isLoading = true
    let statusesService = statusesService
    let settingsService = settingsService
    async let statusesResult = AsyncCore.run {
      try statusesService.list(includeArchived: true)
    }
    async let settingsResult = AsyncCore.run {
      try settingsService.settings()
    }
    let loadedStatuses = await statusesResult
    let loadedSettings = await settingsResult
    isLoading = false

    switch loadedStatuses {
    case .success(let list):
      statuses = list
      loadError = nil
      if let selectedStatusId {
        selectedStatus = list.first { $0.id == selectedStatusId }
      }
    case .failure(let error):
      statuses = []
      loadError = error
    }
    switch loadedSettings {
    case .success(let value):
      settings = value
    case .failure(let error):
      loadError = loadError ?? error
    }
  }

  public func create(name: String) async -> Status? {
    let service = statusesService
    let result = await AsyncCore.run { try service.create(name: name) }
    switch result {
    case .success(let status):
      await reload()
      selectedStatusId = status.id
      return status
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
      return nil
    }
  }

  public func rename(_ id: String, to name: String) async -> Bool {
    let service = statusesService
    let result = await AsyncCore.run { try service.rename(id, to: name) }
    switch result {
    case .success:
      await reload()
      return true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
      return false
    }
  }

  public func archive(_ id: String, replacementId: String?) async -> Bool {
    let service = statusesService
    let result = await AsyncCore.run {
      try service.archive(id, replacementId: replacementId)
    }
    switch result {
    case .success:
      await reload()
      selectedStatusId = id
      return true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
      return false
    }
  }

  public func restore(_ id: String) async -> Bool {
    let service = statusesService
    let result = await AsyncCore.run { try service.restore(id) }
    switch result {
    case .success:
      await reload()
      return true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
      return false
    }
  }

  public func updateSettings(
    defaultStatusId: String,
    transferStatusId: String,
    returnStatusId: String
  ) async -> Bool {
    let service = settingsService
    let value = StatusSettings(
      defaultStatusId: defaultStatusId,
      transferStatusId: transferStatusId,
      returnStatusId: returnStatusId
    )
    let result = await AsyncCore.run { try service.update(value) }
    switch result {
    case .success:
      await reload()
      return true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
      return false
    }
  }

  public func settingsSlots(using id: String) -> [StatusSettingSlot] {
    guard let settings else { return [] }
    var slots: [StatusSettingSlot] = []
    if settings.defaultStatusId == id { slots.append(.defaultStatus) }
    if settings.transferStatusId == id { slots.append(.transferStatus) }
    if settings.returnStatusId == id { slots.append(.returnStatus) }
    return slots
  }

  public func replacementCandidates(excluding id: String) -> [Status] {
    activeStatuses.filter { $0.id != id }
  }

  public func statusId(for slot: StatusSettingSlot) -> String? {
    guard let settings else { return nil }
    switch slot {
    case .defaultStatus: return settings.defaultStatusId
    case .transferStatus: return settings.transferStatusId
    case .returnStatus: return settings.returnStatusId
    }
  }
}
