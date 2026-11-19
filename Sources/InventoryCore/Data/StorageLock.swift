import Darwin
import Foundation

/// Эксклюзивная блокировка папки данных: `flock` на `<root>/.inventory.lock`
/// плюс реестр канонических путей внутри процесса.
public final class StorageLock: @unchecked Sendable {
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var activePaths: Set<String> = []

  private let path: String
  private var descriptor: Int32
  private let releaseLock = NSLock()
  private var released = false

  private init(path: String, descriptor: Int32) {
    self.path = path
    self.descriptor = descriptor
  }

  public static func acquire(layout: StoreLayout, fileManager: FileManager = .default) throws
    -> StorageLock
  {
    let canonical = layout.rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let lockPath = canonical.appendingPathComponent(".inventory.lock").path

    registryLock.lock()
    if activePaths.contains(canonical.path) {
      registryLock.unlock()
      throw AppException(
        .storageBusy,
        params: ["path": .string(canonical.path)],
        debugMessage: "store is already open in this process"
      )
    }
    // Резервируем путь до flock, иначе два потока могут пройти проверку одновременно.
    activePaths.insert(canonical.path)
    registryLock.unlock()

    func releaseReservation() {
      Self.registryLock.lock()
      Self.activePaths.remove(canonical.path)
      Self.registryLock.unlock()
    }

    do {
      try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
    } catch {
      releaseReservation()
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(canonical.path)],
        debugMessage: "cannot create store directory: \(error)"
      )
    }

    let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else {
      releaseReservation()
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(canonical.path)],
        debugMessage: "cannot open lock file: errno \(errno)"
      )
    }

    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      close(descriptor)
      releaseReservation()
      if code == EWOULDBLOCK || code == EAGAIN {
        throw AppException(
          .storageBusy,
          params: ["path": .string(canonical.path)],
          debugMessage: "store is locked by another process"
        )
      }
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(canonical.path)],
        debugMessage: "flock failed: errno \(code)"
      )
    }

    return StorageLock(path: canonical.path, descriptor: descriptor)
  }

  public func release() {
    releaseLock.lock()
    defer { releaseLock.unlock() }
    guard !released else { return }
    released = true
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1

    Self.registryLock.lock()
    Self.activePaths.remove(path)
    Self.registryLock.unlock()
  }

  deinit {
    release()
  }
}
