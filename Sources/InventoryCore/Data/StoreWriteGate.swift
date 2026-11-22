import Foundation

/// Единая точка сериализации изменений хранилища.
///
/// SQLite сам сериализует запись, но фотографии меняются вне SQL-транзакции:
/// новый файл пишется до commit, старый удаляется после. Поэтому запись вещи
/// или места должна удерживать гейт от подготовки файла до удаления старого,
/// иначе экспорт может увидеть базу одной версии, а файлы — другой.
///
/// `performSnapshot` захватывает гейт на всё время снятия снимка: ни одна
/// операция записи не пересечётся со снимком. Ошибка в замыкании не оставляет
/// гейт заблокированным.
public final class StoreWriteGate: @unchecked Sendable {
  private let lock = NSRecursiveLock()

  public init() {}

  /// Обычная операция записи. Повторный вход с того же потока разрешён:
  /// сервис может держать гейт, а вложенный `InventoryDatabase.write` — нет.
  public func performWrite<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// Эксклюзивный доступ для сборки согласованного снимка. Блокирует все
  /// операции записи до завершения замыкания.
  public func performSnapshot<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
