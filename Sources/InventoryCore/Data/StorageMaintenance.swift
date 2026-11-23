import Foundation
import GRDB

/// Результат операции с данными. При ошибке сессия всё равно возвращается,
/// если хранилище удалось открыть заново: пользователь остаётся в рабочем состоянии.
public struct MaintenanceOutcome: Sendable {
  public let session: StorageSession?
  public let error: AppException?
}

public struct SafetyUsage: Sendable, Equatable {
  public let beforeImportBytes: Int64?
  public let beforeMigrationBytes: Int64?
  public let rollbackDiagnosticBytes: Int64?

  public init(
    beforeImportBytes: Int64?,
    beforeMigrationBytes: Int64?,
    rollbackDiagnosticBytes: Int64?
  ) {
    self.beforeImportBytes = beforeImportBytes
    self.beforeMigrationBytes = beforeMigrationBytes
    self.rollbackDiagnosticBytes = rollbackDiagnosticBytes
  }

  public var hasBeforeImport: Bool { beforeImportBytes != nil }
  public var totalBytes: Int64 {
    (beforeImportBytes ?? 0) + (beforeMigrationBytes ?? 0) + (rollbackDiagnosticBytes ?? 0)
  }
}

public enum SafetyKind: Sendable, Hashable, Identifiable {
  case beforeImport
  case beforeMigration

  public var id: SafetyKind { self }
}

/// Этап протокола, на котором тест может имитировать сбой или прерывание.
public typealias MaintenanceCheckpoint = @Sendable (RecoveryPhase) throws -> Void

/// Экспорт, импорт, откат, перенос и переключение хранилища по RECOVERY_PROTOCOL.
///
/// Файловые операции выполняются при закрытой сессии и под `StorageLock`.
/// Вызывающий обязан запускать их вне главного потока.
public final class StorageMaintenance: @unchecked Sendable {
  public typealias Progress = @Sendable (String, Double?) -> Void

  private let coordinator: StorageCoordinator
  private let preferences: any PreferencesStore
  private let clock: any Clock
  private let ids: any IdGenerator
  private let fileManager: FileManager
  private let logger: any AppLogger
  private let temporaryRoot: URL
  private let appVersion: String
  private let checkpoint: MaintenanceCheckpoint?

  init(
    coordinator: StorageCoordinator,
    preferences: any PreferencesStore,
    clock: any Clock,
    ids: any IdGenerator,
    logger: any AppLogger,
    appVersion: String,
    fileManager: FileManager,
    temporaryRoot: URL?,
    checkpoint: MaintenanceCheckpoint?
  ) {
    self.coordinator = coordinator
    self.preferences = preferences
    self.clock = clock
    self.ids = ids
    self.logger = logger
    self.appVersion = appVersion
    self.fileManager = fileManager
    self.temporaryRoot = temporaryRoot ?? fileManager.temporaryDirectory
    self.checkpoint = checkpoint
  }

  // MARK: - Экспорт

  /// Пишет `Inventory-YYYY-MM-DD.inventory.zip` в выбранную папку. Дата последнего
  /// экспорта обновляется только после успешной публикации файла (T05.14).
  public func export(
    session: StorageSession,
    to directory: URL,
    progress: Progress? = nil
  ) throws -> URL {
    progress?("Снимок данных", nil)
    let snapshot = try BackupSnapshotService(
      database: session.database,
      layout: session.layout,
      gate: session.writeGate,
      clock: clock,
      fileManager: fileManager,
      temporaryRoot: temporaryRoot
    ).makeSnapshot()
    defer { snapshot.discard(fileManager: fileManager) }

    let url = try BackupCodec.exportV1(
      snapshot: snapshot,
      to: directory,
      appVersion: appVersion,
      fileManager: fileManager,
      progress: { value in
        progress?("Упаковка архива", value.fraction)
      }
    )
    preferences.setInt(Int(snapshot.createdAt), forKey: PreferenceKeys.backupLastExportMs)
    logger.info("backup exported", data: ["path": url.path])
    return url
  }

  // MARK: - Импорт

  /// Проверяет архив без изменения хранилища. Результат нужен для подтверждения
  /// числа вещей; вызывающий обязан вызвать `discard()`, если импорт не выполняется.
  public func prepareImport(archive: URL) throws -> ValidatedBackup {
    let staged = try BackupArchiveReader(
      temporaryRoot: temporaryRoot, fileManager: fileManager
    ).stage(archiveAt: archive)
    do {
      return try BackupFormatRegistry.validate(staged)
    } catch {
      staged.discard(fileManager: fileManager)
      throw error
    }
  }

  /// Полная замена данных после подтверждения числа вещей (T05.08).
  public func importBackup(
    _ validated: ValidatedBackup,
    confirmedItemCount: Int,
    session: StorageSession,
    progress: Progress? = nil
  ) -> MaintenanceOutcome {
    let layout = session.layout
    guard validated.itemCount == confirmedItemCount else {
      return MaintenanceOutcome(
        session: session,
        error: AppException(
          .importFailed,
          debugMessage: "confirmed item count does not match the archive"
        )
      )
    }

    session.close()
    var failure: AppException?
    do {
      try withLock(layout) {
        try performImport(validated, layout: layout, progress: progress)
      }
    } catch let error as AppException {
      failure = error
    } catch {
      failure = AppException(.importFailed, debugMessage: "import failed: \(error)")
    }
    validated.discard(fileManager: fileManager)
    return reopen(layout, failure: failure)
  }

  private func performImport(
    _ validated: ValidatedBackup,
    layout: StoreLayout,
    progress: Progress?
  ) throws {
    let journal = RecoveryJournal(layout: layout, fileManager: fileManager)
    let opId = ids.next()
    let staging = layout.tmpURL.appendingPathComponent("import-\(opId)")
    let old = layout.tmpURL.appendingPathComponent("old-\(opId)")
    let newBackup = layout.safetyURL.appendingPathComponent("before-import.new")
    let started = clock.nowMilliseconds()

    func mark(_ phase: RecoveryPhase) throws {
      try journal.write(
        RecoveryRecord(
          operation: .importData, opId: opId, phase: phase,
          startedAt: started, updatedAt: clock.nowMilliseconds(),
          root: layout.rootPath, backup: layout.beforeImportURL.path,
          staging: staging.path, details: ["items_count": validated.itemCount]))
      try checkpoint?(phase)
    }

    var swapped = false
    var committed = false
    do {
      try mark(.validating)
      progress?("Подготовка данных", 0.1)
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
      _ = try StagedDatabaseBuilder.build(
        from: validated, at: staging.appendingPathComponent("inventory.db"))
      try RecoveryCopy.copyFiles(
        from: validated.staged.directoryURL.appendingPathComponent("photos"),
        to: staging.appendingPathComponent("photos"))
      try RecoveryCopy.copyFiles(
        from: validated.staged.directoryURL.appendingPathComponent("thumbs"),
        to: staging.appendingPathComponent("thumbs"))

      progress?("Копия текущих данных", 0.3)
      try fileManager.createDirectory(at: newBackup, withIntermediateDirectories: true)
      try RecoveryCopy.databaseCopy(
        from: layout.databasePath, to: newBackup.appendingPathComponent("inventory.db"))
      try RecoveryCopy.copyFiles(
        from: layout.photosURL, to: newBackup.appendingPathComponent("photos"))
      try RecoveryCopy.copyFiles(
        from: layout.thumbsURL, to: newBackup.appendingPathComponent("thumbs"))
      try mark(.snapshotDone)

      try verifyStaging(staging, validated: validated)
      try mark(.stagingReady)

      progress?("Замена данных", 0.6)
      try mark(.swapStarted)
      try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
      swapped = true
      try swapIn(staging: staging, old: old, layout: layout)

      progress?("Проверка", 0.9)
      try mark(.verifying)
      try verifyStore(layout, validated: validated)

      try mark(.done)
      committed = true
      do {
        try StartupRecovery.finishImportBackup(layout: layout, fileManager: fileManager)
      } catch {
        logger.error("import backup rotation deferred to next start", error: "\(error)", data: nil)
      }
      try? fileManager.removeItem(at: staging)
      try? fileManager.removeItem(at: old)
      try? journal.remove()
      logger.info("import completed", data: ["items": "\(validated.itemCount)"])
    } catch {
      if swapped && !committed {
        logger.error("import failed after swap, restoring", error: "\(error)", data: nil)
        try? RecoveryFiles.restore(from: newBackup, into: layout, fileManager: fileManager)
      }
      try? fileManager.removeItem(at: staging)
      try? fileManager.removeItem(at: old)
      try? fileManager.removeItem(at: newBackup)
      try? journal.remove()
      throw error
    }
  }

  private func verifyStaging(_ staging: URL, validated: ValidatedBackup) throws {
    for path in validated.staged.filePaths {
      let url = staging.appendingPathComponent(path)
      guard fileManager.fileExists(atPath: url.path) else {
        throw AppException(
          .backupIntegrityFailed,
          params: ["path": .string(path)],
          debugMessage: "staging photo missing before swap"
        )
      }
    }
  }

  private func swapIn(staging: URL, old: URL, layout: StoreLayout) throws {
    for name in RecoveryFiles.databaseNames {
      let live = layout.rootURL.appendingPathComponent(name)
      if fileManager.fileExists(atPath: live.path) {
        try fileManager.moveItem(at: live, to: old.appendingPathComponent(name))
      }
    }
    for name in ["photos", "thumbs"] {
      let live = layout.rootURL.appendingPathComponent(name, isDirectory: true)
      if fileManager.fileExists(atPath: live.path) {
        try fileManager.moveItem(at: live, to: old.appendingPathComponent(name))
      }
    }
    try fileManager.moveItem(
      at: staging.appendingPathComponent("inventory.db"), to: layout.databaseURL)
    try fileManager.moveItem(at: staging.appendingPathComponent("photos"), to: layout.photosURL)
    try fileManager.moveItem(at: staging.appendingPathComponent("thumbs"), to: layout.thumbsURL)
  }

  private func verifyStore(_ layout: StoreLayout, validated: ValidatedBackup) throws {
    let queue = try DatabaseQueue(
      path: layout.databasePath, configuration: InventoryDatabase.makeConfiguration())
    defer { try? queue.close() }
    let (integrity, version, items) = try queue.read { db -> (String?, Int, Int) in
      (
        try String.fetchOne(db, sql: "PRAGMA integrity_check"),
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0
      )
    }
    guard integrity == "ok", version == Schema.version, items == validated.itemCount else {
      throw AppException(
        .importFailed,
        debugMessage:
          "imported store failed verification: \(integrity ?? "-") v\(version) items=\(items)"
      )
    }
  }

  // MARK: - Откат импорта (T05.09)

  public func rollbackImport(session: StorageSession) -> MaintenanceOutcome {
    let layout = session.layout
    guard fileManager.fileExists(atPath: layout.beforeImportURL.path) else {
      return MaintenanceOutcome(
        session: session,
        error: AppException(
          .validationNotFound,
          params: ["entity": .string("importBackup")],
          debugMessage: "no before-import copy to roll back to"
        )
      )
    }

    session.close()
    var failure: AppException?
    do {
      try withLock(layout) {
        try performRollback(layout: layout)
      }
    } catch let error as AppException {
      failure = error
    } catch {
      failure = AppException(.rollbackFailed, debugMessage: "rollback failed: \(error)")
    }
    return reopen(layout, failure: failure)
  }

  private func performRollback(layout: StoreLayout) throws {
    let journal = RecoveryJournal(layout: layout, fileManager: fileManager)
    let opId = ids.next()
    let started = clock.nowMilliseconds()
    let diagnostic = layout.safetyURL.appendingPathComponent("before-import-rollback")

    func mark(_ phase: RecoveryPhase) throws {
      try journal.write(
        RecoveryRecord(
          operation: .importRollback, opId: opId, phase: phase,
          startedAt: started, updatedAt: clock.nowMilliseconds(),
          root: layout.rootPath, backup: layout.beforeImportURL.path))
      try checkpoint?(phase)
    }

    try mark(.started)
    try? fileManager.removeItem(at: diagnostic)
    try fileManager.createDirectory(at: diagnostic, withIntermediateDirectories: true)
    try RecoveryCopy.databaseCopy(
      from: layout.databasePath, to: diagnostic.appendingPathComponent("inventory.db"))
    try RecoveryCopy.copyFiles(
      from: layout.photosURL, to: diagnostic.appendingPathComponent("photos"))
    try RecoveryCopy.copyFiles(
      from: layout.thumbsURL, to: diagnostic.appendingPathComponent("thumbs"))
    try mark(.snapshotDone)

    try mark(.restoring)
    try RecoveryFiles.restore(from: layout.beforeImportURL, into: layout, fileManager: fileManager)

    try mark(.verifying)
    let queue = try DatabaseQueue(
      path: layout.databasePath, configuration: InventoryDatabase.makeConfiguration())
    let integrity = try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
    try queue.close()
    guard integrity == "ok" else {
      throw AppException(.storageCorrupt, debugMessage: "rolled back store is not intact")
    }

    try mark(.rolledBack)
    try journal.remove()
    logger.info("import rolled back", data: ["path": layout.rootPath])
  }

  // MARK: - Перенос данных (T05.10)

  public func moveStore(
    session: StorageSession,
    to destination: URL,
    progress: Progress? = nil
  ) -> MaintenanceOutcome {
    let source = session.layout
    let target = StoreLayout(rootURL: destination)
    let targetExisted = fileManager.fileExists(atPath: target.rootPath)
    do {
      try validateMoveTarget(source: source, target: target)
    } catch let error as AppException {
      return MaintenanceOutcome(session: session, error: error)
    } catch {
      return MaintenanceOutcome(
        session: session,
        error: AppException(.ioError, debugMessage: "\(error)")
      )
    }

    session.close()
    var failure: AppException?
    do {
      try withLock(source) {
        try performMove(from: source, to: target, progress: progress)
      }
    } catch let error as AppException {
      failure = error
    } catch {
      failure = AppException(.ioError, debugMessage: "move failed: \(error)")
    }

    if failure == nil {
      do {
        let opened = try coordinator.openExisting(target.rootPath)
        cleanupSourceJournal(source)
        logger.info("store moved", data: ["to": target.rootPath])
        return MaintenanceOutcome(session: opened, error: nil)
      } catch let error as AppException {
        failure = error
      } catch {
        failure = AppException(.storageUnavailable, debugMessage: "\(error)")
      }
    }
    cleanupTarget(target, existed: targetExisted)
    return reopen(source, failure: failure)
  }

  private func validateMoveTarget(source: StoreLayout, target: StoreLayout) throws {
    let sourcePath = source.rootURL.path
    let targetPath = target.rootURL.path
    guard sourcePath != targetPath,
      !targetPath.hasPrefix(sourcePath + "/"),
      !sourcePath.hasPrefix(targetPath + "/")
    else {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(targetPath)],
        debugMessage: "destination overlaps the active store"
      )
    }
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: targetPath, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw AppException(.storageUnavailable, params: ["path": .string(targetPath)])
      }
      let entries = try fileManager.contentsOfDirectory(atPath: targetPath)
        .filter { $0 != ".DS_Store" }
      guard entries.isEmpty else {
        throw AppException(
          .storageUnavailable,
          params: ["path": .string(targetPath), "reason": .string("not-empty")],
          debugMessage: "destination folder is not empty; refusing to overwrite"
        )
      }
    }
  }

  private func performMove(
    from source: StoreLayout,
    to target: StoreLayout,
    progress: Progress?
  ) throws {
    let journal = RecoveryJournal(layout: source, fileManager: fileManager)
    let opId = ids.next()
    let started = clock.nowMilliseconds()
    let staging = target.tmpURL.appendingPathComponent("move-\(opId)")

    func mark(_ phase: RecoveryPhase) throws {
      try journal.write(
        RecoveryRecord(
          operation: .move, opId: opId, phase: phase,
          startedAt: started, updatedAt: clock.nowMilliseconds(),
          root: source.rootPath, staging: staging.path, target: target.rootPath))
      try checkpoint?(phase)
    }

    do {
      try mark(.started)
      try target.createDirectories(fileManager: fileManager)
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

      progress?("Копия базы", 0.1)
      try RecoveryCopy.databaseCopy(
        from: source.databasePath, to: staging.appendingPathComponent("inventory.db"))
      try mark(.snapshotDone)

      progress?("Копирование фото", 0.3)
      try mark(.copying)
      try RecoveryCopy.copyFiles(
        from: source.photosURL, to: staging.appendingPathComponent("photos"))
      try RecoveryCopy.copyFiles(
        from: source.thumbsURL, to: staging.appendingPathComponent("thumbs"))

      progress?("Проверка копии", 0.7)
      try verifyCopy(staging: staging, source: source)
      try mark(.copied)

      progress?("Перенос", 0.9)
      try mark(.switching)
      try fileManager.moveItem(
        at: staging.appendingPathComponent("inventory.db"), to: target.databaseURL)
      try moveDirectoryContents(
        from: staging.appendingPathComponent("photos"), to: target.photosURL)
      try moveDirectoryContents(
        from: staging.appendingPathComponent("thumbs"), to: target.thumbsURL)
      try? fileManager.removeItem(at: staging)
    } catch {
      try? fileManager.removeItem(at: staging)
      try? journal.remove()
      throw error
    }
  }

  private func verifyCopy(staging: URL, source: StoreLayout) throws {
    let queue = try DatabaseQueue(
      path: staging.appendingPathComponent("inventory.db").path,
      configuration: InventoryDatabase.makeConfiguration())
    let (integrity, references) = try queue.read { db -> (String?, [String]) in
      var paths: [String] = []
      for row in try Row.fetchAll(
        db,
        sql:
          "SELECT photo_file, thumb_file FROM items UNION ALL SELECT photo_file, thumb_file FROM places"
      ) {
        let photo: String = row[0]
        let thumb: String = row[1]
        paths.append(photo)
        paths.append(thumb)
      }
      return (try String.fetchOne(db, sql: "PRAGMA integrity_check"), paths)
    }
    try queue.close()
    guard integrity == "ok" else {
      throw AppException(.storageCorrupt, debugMessage: "moved copy failed integrity_check")
    }
    for path in references {
      let copy = staging.appendingPathComponent(path)
      guard fileManager.fileExists(atPath: copy.path) else {
        throw AppException(
          .backupIntegrityFailed,
          params: ["path": .string(path)],
          debugMessage: "photo missing in moved copy"
        )
      }
    }
  }

  private func moveDirectoryContents(from source: URL, to target: URL) throws {
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    for name in try fileManager.contentsOfDirectory(atPath: source.path) {
      try fileManager.moveItem(
        at: source.appendingPathComponent(name), to: target.appendingPathComponent(name))
    }
  }

  private func removeMovedFiles(in target: StoreLayout) {
    for name in RecoveryFiles.databaseNames {
      try? fileManager.removeItem(at: target.rootURL.appendingPathComponent(name))
    }
    try? fileManager.removeItem(at: target.photosURL)
    try? fileManager.removeItem(at: target.thumbsURL)
  }

  /// Откатывает следы неудачного переноса: созданную папку удаляем целиком,
  /// существовавшую пустой — возвращаем в прежнее пустое состояние.
  private func cleanupTarget(_ target: StoreLayout, existed: Bool) {
    if !existed {
      try? fileManager.removeItem(at: target.rootURL)
      return
    }
    removeMovedFiles(in: target)
    for url in [target.logsURL, target.safetyURL, target.tmpURL] {
      if let entries = try? fileManager.contentsOfDirectory(atPath: url.path), entries.isEmpty {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  private func cleanupSourceJournal(_ source: StoreLayout) {
    try? RecoveryJournal(layout: source, fileManager: fileManager).remove()
  }

  // MARK: - Переключение (T05.11)

  /// Открывает существующую папку. Текущая сессия закрывается только после успеха.
  public func switchStore(session: StorageSession, to path: String) -> MaintenanceOutcome {
    do {
      let opened = try coordinator.openExisting(path)
      session.close()
      return MaintenanceOutcome(session: opened, error: nil)
    } catch let error as AppException {
      return MaintenanceOutcome(session: session, error: error)
    } catch {
      return MaintenanceOutcome(
        session: session,
        error: AppException(.storageUnavailable, debugMessage: "\(error)")
      )
    }
  }

  // MARK: - Копии безопасности

  public func safetyUsage(layout: StoreLayout) -> SafetyUsage {
    SafetyUsage(
      beforeImportBytes: sizeIfExists(layout.beforeImportURL),
      beforeMigrationBytes: sizeIfExists(layout.beforeMigrationURL),
      rollbackDiagnosticBytes: sizeIfExists(
        layout.safetyURL.appendingPathComponent("before-import-rollback"))
    )
  }

  /// Удаляет копию после подтверждения пользователя. Активный журнал блокирует очистку.
  public func clearSafetyCopy(_ kind: SafetyKind, session: StorageSession) throws {
    let layout = session.layout
    if let record = try RecoveryJournal(layout: layout, fileManager: fileManager).read(),
      !record.phase.isTerminal
    {
      throw AppException(.storageBusy, debugMessage: "operation in progress")
    }
    let url: URL
    switch kind {
    case .beforeImport:
      url = layout.beforeImportURL
      try? fileManager.removeItem(
        at: layout.safetyURL.appendingPathComponent("before-import-rollback"))
    case .beforeMigration:
      url = layout.beforeMigrationURL
    }
    do {
      if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
    } catch {
      throw AppException(.ioError, params: ["path": .string(url.path)], debugMessage: "\(error)")
    }
  }

  // MARK: - Общие шаги

  private func withLock(_ layout: StoreLayout, _ body: () throws -> Void) throws {
    let lock = try StorageLock.acquire(layout: layout, fileManager: fileManager)
    defer { lock.release() }
    try body()
  }

  /// Открывает хранилище после операции. Если и это не удалось, ошибка возвращается
  /// вместе с исходной причиной, а сессия остаётся пустой.
  private func reopen(_ layout: StoreLayout, failure: AppException?) -> MaintenanceOutcome {
    do {
      let opened = try coordinator.openExisting(layout.rootPath)
      return MaintenanceOutcome(session: opened, error: failure)
    } catch let error as AppException {
      return MaintenanceOutcome(session: nil, error: failure ?? error)
    } catch {
      return MaintenanceOutcome(
        session: nil,
        error: failure ?? AppException(.storageUnavailable, debugMessage: "\(error)")
      )
    }
  }

  private func sizeIfExists(_ url: URL) -> Int64? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true {
        total += Int64(values?.fileSize ?? 0)
      }
    }
    return total
  }
}
