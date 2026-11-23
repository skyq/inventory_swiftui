import Foundation

/// Восстановление незавершённой операции при открытии (RECOVERY_PROTOCOL §6).
/// Вызывается под `StorageLock`, до открытия БД и рабочих запросов.
enum StartupRecovery {
  static func run(layout: StoreLayout, fileManager: FileManager, logger: AppLogger) throws {
    let journal = RecoveryJournal(layout: layout, fileManager: fileManager)
    guard let record = try journal.read() else { return }

    switch record.operation {
    case .importData:
      try recoverImport(record, layout: layout, journal: journal, fileManager: fileManager)
    case .importRollback:
      try recoverRollback(record, layout: layout, journal: journal, fileManager: fileManager)
    case .move:
      try recoverMove(record, journal: journal, fileManager: fileManager)
    case .switch, .migration:
      try journal.remove()
    }
    logger.warning(
      "unfinished operation recovered",
      error: nil,
      data: [
        "operation": record.operation.rawValue,
        "phase": record.phase.rawValue,
        "path": layout.rootPath,
      ]
    )
  }

  private static func recoverImport(
    _ record: RecoveryRecord,
    layout: StoreLayout,
    journal: RecoveryJournal,
    fileManager: FileManager
  ) throws {
    let staging = layout.tmpURL.appendingPathComponent("import-\(record.opId)")
    let old = layout.tmpURL.appendingPathComponent("old-\(record.opId)")
    let newBackup = layout.safetyURL.appendingPathComponent("before-import.new")

    switch record.phase {
    case .done:
      try finishImportBackup(layout: layout, fileManager: fileManager)
    case .swapStarted, .verifying, .restoring:
      let source: URL
      if fileManager.fileExists(atPath: newBackup.path) {
        source = newBackup
      } else if fileManager.fileExists(atPath: layout.beforeImportURL.path) {
        source = layout.beforeImportURL
      } else if fileManager.fileExists(atPath: old.path) {
        source = old
      } else {
        throw AppException(
          .migrationFailed,
          params: ["path": .string(layout.rootPath)],
          debugMessage: "import interrupted and no copy to restore from"
        )
      }
      try RecoveryFiles.restore(from: source, into: layout, fileManager: fileManager)
    default:
      break
    }

    try? fileManager.removeItem(at: staging)
    try? fileManager.removeItem(at: old)
    try? fileManager.removeItem(at: newBackup)
    try journal.remove()
  }

  private static func recoverRollback(
    _ record: RecoveryRecord,
    layout: StoreLayout,
    journal: RecoveryJournal,
    fileManager: FileManager
  ) throws {
    switch record.phase {
    case .restoring, .verifying:
      try RecoveryFiles.restore(
        from: layout.beforeImportURL, into: layout, fileManager: fileManager)
    default:
      break
    }
    try journal.remove()
  }

  private static func recoverMove(
    _ record: RecoveryRecord,
    journal: RecoveryJournal,
    fileManager: FileManager
  ) throws {
    if let staging = record.staging {
      try? fileManager.removeItem(atPath: staging)
    }
    try journal.remove()
  }

  /// Финал импорта: новая копия «до импорта» становится единственной.
  /// Идемпотентно: вызывается и при обычном завершении, и при восстановлении `done`.
  static func finishImportBackup(layout: StoreLayout, fileManager: FileManager) throws {
    let newBackup = layout.safetyURL.appendingPathComponent("before-import.new")
    guard fileManager.fileExists(atPath: newBackup.path) else { return }
    if fileManager.fileExists(atPath: layout.beforeImportURL.path) {
      try fileManager.removeItem(at: layout.beforeImportURL)
    }
    try fileManager.moveItem(at: newBackup, to: layout.beforeImportURL)
  }
}
