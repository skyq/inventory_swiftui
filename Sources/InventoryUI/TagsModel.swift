import Foundation
import InventoryCore

public enum TagSortMode: String, CaseIterable, Identifiable, Sendable, Equatable {
  case name
  case count

  public var id: String { rawValue }
}

/// Предложение объединить тег после конфликта переименования (ТЗ §6.3).
public struct TagMergeSuggestion: Identifiable, Sendable, Equatable {
  public let sourceId: String
  public let sourceName: String
  public let targetId: String
  public let targetName: String
  public let resultName: String

  public var id: String { "\(sourceId)->\(targetId)" }
}

@MainActor
public final class TagsModel: ObservableObject {
  @Published public private(set) var tags: [TagSuggestion] = []
  @Published public var sortMode: TagSortMode = .name
  @Published public var selectedTagId: String? {
    didSet {
      guard selectedTagId != oldValue else { return }
      if selectedTagId == nil {
        selectedTag = nil
      } else if let id = selectedTagId {
        selectedTag = tags.first { $0.id == id }
      }
    }
  }
  @Published public private(set) var selectedTag: TagSuggestion?
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: AppException?
  @Published public var alertMessage: String?
  @Published public var renameSuggestion: TagMergeSuggestion?

  private let tagsService: any TagService
  private let items: any ItemService
  private var observationTasks: [Task<Void, Never>] = []
  private var started = false

  public init(tags: any TagService, items: any ItemService) {
    self.tagsService = tags
    self.items = items
  }

  deinit {
    for task in observationTasks { task.cancel() }
  }

  public var sortedTags: [TagSuggestion] {
    switch sortMode {
    case .name:
      return tags.sorted { left, right in
        let byName = NaturalSort.compare(left.name, right.name)
        return byName != 0 ? byName < 0 : left.id < right.id
      }
    case .count:
      return tags.sorted { left, right in
        if left.itemCount != right.itemCount { return left.itemCount > right.itemCount }
        let byName = NaturalSort.compare(left.name, right.name)
        return byName != 0 ? byName < 0 : left.id < right.id
      }
    }
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
    let service = tagsService
    let result = await AsyncCore.run { try service.listWithCounts() }
    isLoading = false
    switch result {
    case .success(let loaded):
      tags = loaded
      loadError = nil
      if let selectedTagId {
        selectedTag = loaded.first { $0.id == selectedTagId }
        if selectedTag == nil { self.selectedTagId = nil }
      }
    case .failure(let error):
      tags = []
      loadError = error
    }
  }

  public func rename(_ id: String, to name: String) async -> Bool {
    let service = tagsService
    let result = await AsyncCore.run { try service.rename(id, to: name) }
    switch result {
    case .success:
      await reload()
      return true
    case .failure(let error):
      if error.code == .tagNameConflict, let targetId = error.string("tagId") {
        let source = tags.first { $0.id == id }
        let target = tags.first { $0.id == targetId }
        renameSuggestion = TagMergeSuggestion(
          sourceId: id,
          sourceName: source?.name ?? name,
          targetId: targetId,
          targetName: target?.name ?? "",
          resultName: name
        )
      } else {
        alertMessage = ErrorPresenter.message(for: error)
      }
      return false
    }
  }

  public func confirmRenameMerge() async {
    guard let suggestion = renameSuggestion else { return }
    renameSuggestion = nil
    _ = await merge(
      sourceId: suggestion.sourceId,
      into: suggestion.targetId,
      resultName: suggestion.resultName
    )
  }

  public func merge(sourceId: String, into targetId: String, resultName: String?) async -> Bool {
    let service = tagsService
    let result = await AsyncCore.run {
      try service.merge(sourceId, into: targetId, resultName: resultName)
    }
    switch result {
    case .success(let tag):
      await reload()
      selectedTagId = tag.id
      return true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
      return false
    }
  }

  public func delete(_ id: String) async -> Bool {
    let service = tagsService
    let result = await AsyncCore.run { try service.delete(id) }
    switch result {
    case .success:
      if selectedTagId == id { selectedTagId = nil }
      await reload()
      return true
    case .failure(let error):
      alertMessage = ErrorPresenter.message(for: error)
      return false
    }
  }

  private func observe() {
    observationTasks.append(
      Task { [weak self] in
        guard let stream = self?.tagsService.changes else { return }
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
          guard let self else { return }
          await self.reload()
        }
      }
    )
  }
}
