import Foundation
import InventoryCore

/// Справочник людей и история выбранного человека.
@MainActor
public final class PeopleModel: ObservableObject {
  @Published public private(set) var people: [Person] = []
  @Published public var includeArchived = false {
    didSet {
      guard includeArchived != oldValue else { return }
      Task { await reload() }
    }
  }
  @Published public var selectedPersonId: String? {
    didSet {
      guard selectedPersonId != oldValue else { return }
      Task { await loadSelected() }
    }
  }
  @Published public private(set) var selectedPerson: Person?
  @Published public private(set) var selectedHistory: [PersonHistoryEntry] = []
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: AppException?
  @Published public var alertMessage: String?

  private let peopleService: any PeopleService
  private let history: any HistoryReadService
  private let items: any ItemService
  private var observationTasks: [Task<Void, Never>] = []
  private var started = false

  public init(
    people: any PeopleService,
    history: any HistoryReadService,
    items: any ItemService
  ) {
    self.peopleService = people
    self.history = history
    self.items = items
  }

  deinit {
    for task in observationTasks { task.cancel() }
  }

  public var activeCount: Int {
    people.filter { !$0.isArchived }.count
  }

  public func start() async {
    if !started {
      started = true
      observe()
    }
    await reload()
  }

  public func reload() async {
    isLoading = true
    let service = peopleService
    let includeArchived = includeArchived
    let result = await AsyncCore.run {
      try service.list(includeArchived: includeArchived)
    }
    isLoading = false
    switch result {
    case .success(let loaded):
      people = loaded
      loadError = nil
      if let selectedPersonId,
        !loaded.contains(where: { $0.id == selectedPersonId })
      {
        self.selectedPersonId = nil
        selectedPerson = nil
        selectedHistory = []
      } else if selectedPersonId != nil {
        await loadSelected()
      }
    case .failure(let error):
      people = []
      loadError = error
    }
  }

  public func select(_ id: String?) async {
    selectedPersonId = id
    await loadSelected()
  }

  public func makeFormModel(for mode: PersonFormMode) -> PersonFormModel {
    PersonFormModel(mode: mode, people: peopleService)
  }

  public func archiveSelected() async {
    guard let selectedPerson else { return }
    let service = peopleService
    let result = await AsyncCore.run { try service.archive(selectedPerson.id) }
    switch result {
    case .success:
      await reload()
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
    }
  }

  public func restoreSelected() async {
    guard let selectedPerson else { return }
    let service = peopleService
    let result = await AsyncCore.run { try service.restore(selectedPerson.id) }
    switch result {
    case .success:
      await reload()
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
    }
  }

  // MARK: - Внутренние шаги

  private func observe() {
    observationTasks.append(
      Task { [weak self] in
        guard let stream = self?.peopleService.changes else { return }
        for await _ in stream {
          guard let self else { return }
          await self.reload()
        }
      }
    )
    observationTasks.append(
      Task { [weak self] in
        guard let stream = self?.items.changes else { return }
        for await _ in stream {
          guard let self, self.selectedPersonId != nil else { return }
          await self.loadSelected()
        }
      }
    )
  }

  private func loadSelected() async {
    guard let selectedPersonId else {
      selectedPerson = nil
      selectedHistory = []
      return
    }
    let peopleService = peopleService
    let historyService = history
    async let personResult = AsyncCore.run { try peopleService.get(selectedPersonId) }
    async let historyResult = AsyncCore.run {
      try historyService.personHistory(personId: selectedPersonId)
    }
    let loadedPerson = await personResult
    let loadedHistory = await historyResult

    guard self.selectedPersonId == selectedPersonId else { return }
    switch loadedPerson {
    case .success(let person):
      selectedPerson = person
    case .failure(let error):
      selectedPerson = nil
      if error.code != .validationNotFound {
        alertMessage = ErrorPresenter.message(for: error)
      }
    }
    switch loadedHistory {
    case .success(let entries):
      selectedHistory = entries
    case .failure:
      selectedHistory = []
    }
  }
}

public enum PersonFormMode: Sendable, Equatable {
  case create
  case edit(Person)

  public var editingPerson: Person? {
    if case .edit(let person) = self { return person }
    return nil
  }
}

public struct PersonFormPresentation: Identifiable {
  public let id = UUID()
  public let mode: PersonFormMode

  public init(mode: PersonFormMode) {
    self.mode = mode
  }
}

@MainActor
public final class PersonFormModel: ObservableObject {
  public let mode: PersonFormMode
  @Published public var name: String
  @Published public var phone: String
  @Published public var notes: String
  @Published public private(set) var isSaving = false
  @Published public private(set) var didSave = false
  @Published public var pendingDuplicate = false
  @Published public var alertMessage: String?

  private let people: any PeopleService

  public init(mode: PersonFormMode, people: any PeopleService) {
    self.mode = mode
    self.people = people
    switch mode {
    case .create:
      self.name = ""
      self.phone = ""
      self.notes = ""
    case .edit(let person):
      self.name = person.name
      self.phone = person.phone
      self.notes = person.notes
    }
  }

  public var title: String {
    mode.editingPerson == nil
      ? L10n.string("people.newTitle")
      : L10n.string("people.editTitle")
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var nameIsTooLong: Bool {
    trimmedName.count > NameKey.maxLength
  }

  public var canSave: Bool {
    !trimmedName.isEmpty && !nameIsTooLong && !isSaving
  }

  public func save() async {
    await perform(duplicateConfirmed: false)
  }

  public func saveDuplicate() async {
    pendingDuplicate = false
    await perform(duplicateConfirmed: true)
  }

  private func perform(duplicateConfirmed: Bool) async {
    guard canSave else { return }
    if trimmedName.isEmpty {
      alertMessage = L10n.string("people.nameRequired")
      return
    }
    if nameIsTooLong {
      alertMessage = L10n.format("people.nameMaxLength", NameKey.maxLength)
      return
    }

    isSaving = true
    let service = people
    let name = trimmedName
    let phone = self.phone
    let notes = self.notes

    let result: Result<Person, AppException>
    switch mode {
    case .create:
      result = await AsyncCore.run {
        try service.create(
          PersonCreate(name: name, phone: phone, notes: notes),
          duplicateConfirmed: duplicateConfirmed
        )
      }
    case .edit(let person):
      result = await AsyncCore.run {
        try service.update(
          PersonUpdate(id: person.id, name: name, phone: phone, notes: notes),
          duplicateConfirmed: duplicateConfirmed
        )
      }
    }
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
}
