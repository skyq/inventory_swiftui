import Foundation
import InventoryCore

/// Текущая длительная операция с данными: показывается модальным окном с прогрессом.
public struct DataActivity: Equatable, Sendable {
  public let title: String
  public let fraction: Double?

  public init(title: String, fraction: Double?) {
    self.title = title
    self.fraction = fraction
  }
}

/// Проверенный архив, ожидающий подтверждения числа вещей.
public struct PendingImport: Identifiable {
  public let id = UUID()
  public let validated: ValidatedBackup
  public let currentItemCount: Int

  public init(validated: ValidatedBackup, currentItemCount: Int) {
    self.validated = validated
    self.currentItemCount = currentItemCount
  }
}

/// Выбор новой папки данных, ожидающий подтверждения.
public struct PendingFolderChange: Identifiable {
  public enum Kind: Sendable {
    case move
    case open
  }

  public let id = UUID()
  public let kind: Kind
  public let url: URL
  public let cloudProvider: String?

  public init(kind: Kind, url: URL, cloudProvider: String?) {
    self.kind = kind
    self.url = url
    self.cloudProvider = cloudProvider
  }
}

/// Операции раздела «Данные»: экспорт, импорт, откат, перенос и копии безопасности.
/// Тяжёлая работа идёт вне главного потока; интерфейс блокируется модальным прогрессом.
@MainActor
extension AppModel {
  @discardableResult
  public func exportBackup(to directory: URL) async -> URL? {
    guard let session else { return nil }
    let maintenance = self.maintenance
    let progress = progressReporter()
    dataActivity = DataActivity(title: L10n.string("data.activity.export"), fraction: nil)
    let result = await AsyncCore.run {
      try maintenance.export(session: session, to: directory, progress: progress)
    }
    dataActivity = nil
    switch result {
    case .success(let url):
      refreshDataState()
      return url
    case .failure(let error):
      session.logger.error("backup export failed", error: String(describing: error), data: nil)
      alert = .failure(ErrorPresenter.message(for: error))
      return nil
    }
  }

  public func chooseImportArchive() async {
    guard let url = dialogs.chooseArchiveFile() else { return }
    await prepareImport(archiveAt: url)
  }

  /// Проверяет выбранный архив и открывает подтверждение. Доступ к файлу должен быть открыт вызывающим.
  public func prepareImport(archiveAt url: URL) async {
    guard let session else { return }
    let maintenance = self.maintenance
    dataActivity = DataActivity(title: L10n.string("data.activity.check"), fraction: nil)
    let result = await AsyncCore.run {
      try maintenance.prepareImport(archive: url)
    }
    dataActivity = nil
    switch result {
    case .success(let validated):
      let current = (try? session.items.list(GalleryQuery(showHidden: true)).count) ?? 0
      pendingImport = PendingImport(validated: validated, currentItemCount: current)
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }
  }

  public func cancelImport() {
    pendingImport?.validated.discard()
    pendingImport = nil
  }

  public func confirmImport() async {
    guard let pending = pendingImport, let session else { return }
    pendingImport = nil
    let validated = pending.validated
    let count = validated.itemCount
    await runDataOperation(title: L10n.string("data.activity.import")) { maintenance, progress in
      maintenance.importBackup(
        validated, confirmedItemCount: count, session: session, progress: progress)
    }
  }

  public func rollbackLastImport() async {
    guard let session else { return }
    pendingRollback = false
    await runDataOperation(title: L10n.string("data.activity.rollback")) { maintenance, _ in
      maintenance.rollbackImport(session: session)
    }
  }

  public func chooseMoveDestination() {
    guard let url = dialogs.chooseDirectory(startingAt: currentDirectoryHint()) else { return }
    requestFolderChange(.move, url: url)
  }

  public func chooseOpenFolder() {
    guard let url = dialogs.chooseDirectory(startingAt: currentDirectoryHint()) else { return }
    requestFolderChange(.open, url: url)
  }

  /// Открывает подтверждение переноса или переключения папки. Доступ к папке должен быть открыт вызывающим.
  public func requestFolderChange(_ kind: PendingFolderChange.Kind, url: URL) {
    pendingFolderChange = PendingFolderChange(
      kind: kind,
      url: url,
      cloudProvider: StorageLocationWarning.cloudProviderName(for: url.path)
    )
  }

  public func exportWithDialog() async {
    guard let directory = dialogs.chooseDirectory(startingAt: currentDirectoryHint()) else {
      return
    }
    await exportBackup(to: directory)
  }

  public func confirmFolderChange(_ change: PendingFolderChange) async {
    guard let session else { return }
    pendingFolderChange = nil
    switch change.kind {
    case .move:
      let url = change.url
      await runDataOperation(title: L10n.string("data.activity.move")) { maintenance, progress in
        maintenance.moveStore(session: session, to: url, progress: progress)
      }
    case .open:
      let path = change.url.path
      await runDataOperation(title: L10n.string("data.activity.open")) { maintenance, _ in
        maintenance.switchStore(session: session, to: path)
      }
    }
  }

  public func clearSafetyCopy(_ kind: SafetyKind) async {
    guard let session else { return }
    pendingSafetyClear = nil
    let maintenance = self.maintenance
    let result = await AsyncCore.run {
      try maintenance.clearSafetyCopy(kind, session: session)
    }
    switch result {
    case .success:
      refreshDataState()
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }
  }

  /// Статусы для окна настроек: только активные для выбора.
  public func statusSettingsSnapshot() -> (statuses: [Status], settings: StatusSettings)? {
    guard let session else { return nil }
    guard let statuses = try? session.statuses.list(includeArchived: false),
      let settings = try? session.statusSettings.settings()
    else { return nil }
    return (statuses, settings)
  }

  public func saveStatusSettings(_ settings: StatusSettings) async {
    guard let session else { return }
    let result = await AsyncCore.run { try session.statusSettings.update(settings) }
    switch result {
    case .success:
      break
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }
  }

  public func setBackupReminderEnabled(_ enabled: Bool) {
    BackupReminder.setEnabled(enabled, in: preferences)
    refreshDataState()
  }

  public var backupReminderEnabled: Bool {
    BackupReminder.isEnabled(preferences)
  }

  public var lastBackupExportDate: Date? {
    BackupReminder.lastExport(in: preferences).map {
      Date(timeIntervalSince1970: Double($0) / 1000)
    }
  }

  /// Пересчитывает размер копий и признак напоминания. Файловые операции — вне главного потока.
  public func refreshDataState() {
    guard let session else { return }
    let enabled = BackupReminder.isEnabled(preferences)
    let last = BackupReminder.lastExport(in: preferences)
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    reminderDue = BackupReminder.isDue(enabled: enabled, lastExportMs: last, now: now)

    let maintenance = self.maintenance
    let layout = session.layout
    Task {
      let usage = await Task.detached(priority: .utility) {
        maintenance.safetyUsage(layout: layout)
      }.value
      self.safetyUsage = usage
    }
  }

  // MARK: - Общие шаги

  /// Выполняет операцию, которая закрывает и заново открывает хранилище.
  func runDataOperation(
    title: String,
    _ work:
      @escaping @Sendable (StorageMaintenance, @escaping StorageMaintenance.Progress)
      -> MaintenanceOutcome
  ) async {
    let maintenance = self.maintenance
    let progress = progressReporter()
    dataActivity = DataActivity(title: title, fraction: nil)
    let outcome = await Task.detached(priority: .userInitiated) {
      work(maintenance, progress)
    }.value
    dataActivity = nil
    applyMaintenanceOutcome(outcome)
  }

  private func applyMaintenanceOutcome(_ outcome: MaintenanceOutcome) {
    guard let opened = outcome.session else {
      session = nil
      storePath = nil
      loadState = .failed(
        outcome.error ?? AppException(.storageUnavailable, debugMessage: "store not opened"))
      return
    }
    attach(opened)
    loadState = .ready
    if let error = outcome.error {
      alert = .failure(ErrorPresenter.message(for: error))
    }
    Task {
      await browser?.start()
      if let gallery {
        await gallery.start()
      }
    }
    refreshDataState()
  }

  private func progressReporter() -> StorageMaintenance.Progress {
    let model = self
    return { title, fraction in
      Task { @MainActor in
        model.reportProgress(title: title, fraction: fraction)
      }
    }
  }

  func reportProgress(title: String, fraction: Double?) {
    guard dataActivity != nil else { return }
    dataActivity = DataActivity(title: title, fraction: fraction)
  }
}
