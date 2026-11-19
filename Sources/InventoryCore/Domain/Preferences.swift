import Foundation

/// Настройки интерфейса и путь активного хранилища живут вне папки данных.
public protocol PreferencesStore: AnyObject, Sendable {
  func string(forKey key: String) -> String?
  func setString(_ value: String?, forKey key: String)
  func bool(forKey key: String) -> Bool?
  func setBool(_ value: Bool, forKey key: String)
  func int(forKey key: String) -> Int?
  func setInt(_ value: Int, forKey key: String)
}

public enum PreferenceKeys {
  public static let activeStorePath = "storage.active_path"
  public static let backupReminderEnabled = "backup.reminder_enabled"
  public static let backupLastExportMs = "backup.last_export_ms"
  public static let galleryMode = "gallery.mode"
  public static let galleryTileSize = "gallery.tile_size"
  public static let gallerySort = "gallery.sort"
  public static let gallerySortDirection = "gallery.sort_direction"
  public static let galleryFilterPlaceId = "gallery.filter_place_id"
  public static let galleryFilterNoPlace = "gallery.filter_no_place"
  public static let galleryFilterStatusIds = "gallery.filter_status_ids"
  public static let galleryFilterTagIds = "gallery.filter_tag_ids"
}

/// Потокобезопасное хранилище настроек в памяти: используется тестами и превью.
public final class InMemoryPreferencesStore: PreferencesStore, @unchecked Sendable {
  private let lock = NSLock()
  private var strings: [String: String] = [:]
  private var bools: [String: Bool] = [:]
  private var ints: [String: Int] = [:]

  public init() {}

  public func string(forKey key: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return strings[key]
  }

  public func setString(_ value: String?, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    strings[key] = value
  }

  public func bool(forKey key: String) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    return bools[key]
  }

  public func setBool(_ value: Bool, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    bools[key] = value
  }

  public func int(forKey key: String) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return ints[key]
  }

  public func setInt(_ value: Int, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    ints[key] = value
  }
}

public enum DefaultStoreLocation {
  /// `~/Library/Application Support/Inventory`.
  public static func url(fileManager: FileManager = .default) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Inventory", isDirectory: true)
  }
}
