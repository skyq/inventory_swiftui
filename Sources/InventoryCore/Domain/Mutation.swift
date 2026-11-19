import Foundation

public enum MutationKind: String, Sendable {
  case created
  case updated
  case moved
  case deleted
}

public enum MutationEvent: Sendable, Equatable {
  case placesChanged(affectedIds: Set<String>, parentId: String?, kind: MutationKind)
}

/// Публикует события после успешного commit. Подписчики сами перечитывают данные.
public final class MutationBus: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<MutationEvent>.Continuation] = [:]
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
    lock.unlock()
    for continuation in targets {
      continuation.yield(event)
    }
  }

  public func close() {
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
