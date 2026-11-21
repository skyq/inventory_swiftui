import Foundation

public enum MutationKind: String, Sendable {
  case created
  case updated
  case moved
  case deleted
}

public enum MutationEvent: Sendable, Equatable {
  case placesChanged(affectedIds: Set<String>, parentId: String?, kind: MutationKind)
  case itemsChanged(itemIds: Set<String>, kind: MutationKind)
  case statusesChanged(statusIds: Set<String>, kind: MutationKind)
  case tagsChanged(tagIds: Set<String>, kind: MutationKind)
  case peopleChanged(personIds: Set<String>, kind: MutationKind)
}

/// Публикует события после успешного commit. Подписчики сами перечитывают данные.
public final class MutationBus: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<MutationEvent>.Continuation] = [:]
  private var listeners: [UUID: @Sendable (MutationEvent) -> Void] = [:]
  private var closed = false

  public init() {}

  public var events: AsyncStream<MutationEvent> {
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
        self.lock.lock()
        self.continuations[id] = nil
        self.lock.unlock()
      }
    }
  }

  public func emit(_ event: MutationEvent) {
    lock.lock()
    let targets = continuations.values
    let callbacks = listeners.values
    lock.unlock()
    for continuation in targets {
      continuation.yield(event)
    }
    for callback in callbacks {
      callback(event)
    }
  }

  /// Синхронный слушатель. Вызывается после успешного commit, сразу после
  /// публикации события. Возвращённый id нужен для отписки.
  @discardableResult
  public func addListener(_ listener: @escaping @Sendable (MutationEvent) -> Void) -> UUID {
    let id = UUID()
    lock.lock()
    if !closed {
      listeners[id] = listener
    }
    lock.unlock()
    return id
  }

  public func removeListener(_ id: UUID) {
    lock.lock()
    listeners[id] = nil
    lock.unlock()
  }

  public func close() {
    lock.lock()
    closed = true
    let targets = continuations.values
    continuations.removeAll()
    listeners.removeAll()
    lock.unlock()
    for continuation in targets {
      continuation.finish()
    }
  }
}
