import Foundation

/// Держит индекс поиска актуальным. Документы пересобираются из базы после
/// каждого опубликованного события (события выходят только после commit),
/// в индекс попадают только изменившиеся документы (T04.05).
public final class SearchIndexCoordinator: SearchService, @unchecked Sendable {
  private let builder: SearchDocumentBuilder
  private let index: SearchIndex
  private let mutations: MutationBus
  private let logger: any AppLogger
  private let queue = DispatchQueue(label: "app.inventory.search-index")
  private let changeBus = SearchChangeBus()
  private let stateLock = NSLock()

  private var documents: [String: SearchDocument] = [:]
  private var listenerId: UUID?
  private var closed = false

  public init(
    database: InventoryDatabase,
    mutations: MutationBus,
    logger: any AppLogger = NullLogger()
  ) {
    self.builder = SearchDocumentBuilder(database: database)
    self.index = SearchIndex()
    self.mutations = mutations
    self.logger = logger
  }

  public var changes: AsyncStream<Void> { changeBus.stream }

  /// Строит индекс после открытия хранилища и подписывается на изменения.
  public func start() {
    stateLock.lock()
    if closed {
      stateLock.unlock()
      return
    }
    stateLock.unlock()

    queue.sync { [self] in
      rebuildLocked()
    }

    let id = mutations.addListener { [weak self] _ in
      self?.enqueueRefresh()
    }

    stateLock.lock()
    if closed {
      stateLock.unlock()
      mutations.removeListener(id)
    } else {
      listenerId = id
      stateLock.unlock()
    }
  }

  public func search(_ query: String) -> [SearchHit] {
    index.search(query)
  }

  public func rebuild() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        rebuildLocked()
        continuation.resume()
      }
    }
  }

  public func waitForIdle() async {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume()
      }
    }
  }

  public func close() {
    stateLock.lock()
    if closed {
      stateLock.unlock()
      return
    }
    closed = true
    let id = listenerId
    listenerId = nil
    stateLock.unlock()

    if let id {
      mutations.removeListener(id)
    }
    changeBus.close()
  }

  // MARK: - Обновление индекса

  private func enqueueRefresh() {
    queue.async { [weak self] in
      self?.refreshLocked()
    }
  }

  private func rebuildLocked() {
    do {
      let loaded = try builder.buildAll()
      documents = Dictionary(uniqueKeysWithValues: loaded.map { ($0.itemId, $0) })
      index.rebuild(loaded)
      changeBus.yield()
    } catch {
      logger.error(
        "search index rebuild failed",
        error: String(describing: error),
        data: nil
      )
    }
  }

  private func refreshLocked() {
    do {
      let loaded = try builder.buildAll()
      let current = Dictionary(uniqueKeysWithValues: loaded.map { ($0.itemId, $0) })
      let changed = loaded.filter { documents[$0.itemId] != $0 }
      let removed = Set(documents.keys).subtracting(current.keys)
      guard !changed.isEmpty || !removed.isEmpty else { return }

      index.update(changed, removedItemIds: removed)
      documents = current
      changeBus.yield()
    } catch {
      logger.error(
        "search index update failed",
        error: String(describing: error),
        data: nil
      )
    }
  }
}

/// Поток уведомлений об изменении индекса. Подписчики перечитывают выдачу.
final class SearchChangeBus: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
  private var closed = false

  var stream: AsyncStream<Void> {
    AsyncStream { continuation in
      let id = UUID()
      lock.lock()
      if closed {
        lock.unlock()
        continuation.finish()
        return
      }
      continuations[id] = continuation
      lock.unlock()

      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        lock.lock()
        continuations[id] = nil
        lock.unlock()
      }
    }
  }

  func yield() {
    lock.lock()
    let targets = continuations.values
    lock.unlock()
    for continuation in targets {
      continuation.yield(())
    }
  }

  func close() {
    lock.lock()
    closed = true
    let targets = continuations.values
    continuations.removeAll()
    lock.unlock()
    for continuation in targets {
      continuation.finish()
    }
  }
}
