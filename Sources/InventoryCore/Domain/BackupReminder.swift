import Foundation

/// Напоминание о ручной копии (ТЗ §10.2, D11): показывается, если экспорта не было
/// или последний успешный экспорт был строго более 30 суток назад.
public enum BackupReminder {
  public static let intervalMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1000

  public static func isEnabled(_ preferences: any PreferencesStore) -> Bool {
    preferences.bool(forKey: PreferenceKeys.backupReminderEnabled) ?? true
  }

  public static func setEnabled(_ enabled: Bool, in preferences: any PreferencesStore) {
    preferences.setBool(enabled, forKey: PreferenceKeys.backupReminderEnabled)
  }

  public static func lastExport(in preferences: any PreferencesStore) -> Int64? {
    preferences.int(forKey: PreferenceKeys.backupLastExportMs).map(Int64.init)
  }

  public static func isDue(
    enabled: Bool,
    lastExportMs: Int64?,
    now: Int64
  ) -> Bool {
    guard enabled else { return false }
    guard let lastExportMs else { return true }
    return now - lastExportMs > intervalMilliseconds
  }
}

/// Эвристика для папок данных в облачных синхронизаторах (ТЗ §10.1, этап 5).
/// Не блокирует операцию: только предупреждение, поскольку синхронизатор может
/// менять файлы вне блокировки приложения.
public enum StorageLocationWarning {
  public static func cloudProviderName(for path: String) -> String? {
    let lowered = path.lowercased()
    if lowered.contains("/library/mobile documents/") { return "iCloud Drive" }
    if lowered.contains("/library/cloudstorage/") {
      let components = lowered.components(separatedBy: "/library/cloudstorage/")
      let provider = components.dropFirst().first?.components(separatedBy: "/").first ?? ""
      if provider.hasPrefix("googledrive") { return "Google Drive" }
      if provider.hasPrefix("onedrive") { return "OneDrive" }
      if provider.hasPrefix("dropbox") { return "Dropbox" }
      return "облачная папка"
    }
    if lowered.contains("/dropbox") { return "Dropbox" }
    if lowered.contains("/google drive") { return "Google Drive" }
    if lowered.contains("/onedrive") { return "OneDrive" }
    return nil
  }
}
