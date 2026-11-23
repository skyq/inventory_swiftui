import Foundation
import InventoryCore

/// Настройки интерфейса в `UserDefaults`. Путь хранилища — отдельный ключ вне папки данных.
public final class UserDefaultsPreferencesStore: PreferencesStore, @unchecked Sendable {
  private let defaults: UserDefaults
  private let lock = NSLock()

  public init(suiteName: String? = nil) {
    if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
      self.defaults = suite
    } else {
      self.defaults = .standard
    }
  }

  public func string(forKey key: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return defaults.string(forKey: key)
  }

  public func setString(_ value: String?, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    defaults.set(value, forKey: key)
  }

  public func bool(forKey key: String) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    guard defaults.object(forKey: key) != nil else { return nil }
    return defaults.bool(forKey: key)
  }

  public func setBool(_ value: Bool, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    defaults.set(value, forKey: key)
  }

  public func int(forKey key: String) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    guard defaults.object(forKey: key) != nil else { return nil }
    return defaults.integer(forKey: key)
  }

  public func setInt(_ value: Int, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    defaults.set(value, forKey: key)
  }
}
