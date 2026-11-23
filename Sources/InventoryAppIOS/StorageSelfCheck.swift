import Foundation
import InventoryCore
import GRDB
import InventoryPlatform
import UIKit

/// Проверка хранилища на устройстве (IOS.03). Работает в папке Application Support
/// приложения, не трогает рабочие данные: использует отдельную папку `SelfCheck`.
enum StorageSelfCheck {
  struct Line: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let passed: Bool
    let detail: String
  }

  static func run() async -> [Line] {
    await Task.detached(priority: .userInitiated) { runSync() }.value
  }

  private static func runSync() -> [Line] {
    var lines: [Line] = []
    let base = DefaultStoreLocation.url()
      .deletingLastPathComponent()
      .appendingPathComponent("InventorySelfCheck", isDirectory: true)
    try? FileManager.default.removeItem(at: base)

    func check(_ title: String, _ body: () throws -> String) {
      do {
        let detail = try body()
        lines.append(Line(title: title, passed: true, detail: detail))
      } catch {
        lines.append(Line(title: title, passed: false, detail: "\(error)"))
      }
    }

    let preferences = InMemoryPreferencesStore()
    let coordinator = StorageCoordinator(
      preferences: preferences,
      logger: NullLogger(),
      clock: SystemClock(),
      ids: UuidV4IdGenerator()
    )
    let store = base.appendingPathComponent("store", isDirectory: true).path
    var session: StorageSession?

    check("Создание хранилища") {
      session = try coordinator.createNew(store)
      return "папка: \(store)"
    }

    check("Место, фото и вещь") {
      guard let session else { throw SelfCheckError.noSession }
      let photo = try makePhoto()
      let place = try session.places.create(
        PlaceCreate(name: "Проверка", description: "", parentId: nil, photo: photo))
      _ = try session.items.create(
        ItemCreate(
          name: "Лампа",
          description: "",
          notes: "",
          quantity: 1,
          placeId: place.id,
          statusId: nil,
          tags: ["Свет"],
          photo: photo
        ))
      let count = try session.items.list(GalleryQuery()).count
      guard count == 1 else { throw SelfCheckError.mismatch("вещей \(count)") }
      return "вещей: \(count)"
    }

    check("Повторное открытие после закрытия") {
      session?.close()
      session = nil
      let reopened = try coordinator.openExisting(store)
      defer { reopened.close() }
      let count = try reopened.items.list(GalleryQuery()).count
      guard count == 1 else { throw SelfCheckError.mismatch("вещей \(count)") }
      return "данные на месте, вещей: \(count)"
    }

    check("Блокировка: второе открытие отклоняется") {
      let first = try coordinator.openExisting(store)
      defer { first.close() }
      do {
        let second = try coordinator.openExisting(store)
        second.close()
        throw SelfCheckError.mismatch("второе открытие не отклонено")
      } catch let error as AppException {
        return "отклонено: \(error.code)"
      }
    }

    check("Экспорт и импорт архива") {
      let opened = try coordinator.openExisting(store)
      let maintenance = coordinator.makeMaintenance(
        appVersion: "ios-check", temporaryRoot: base)
      let exportDir = base.appendingPathComponent("export", isDirectory: true)
      try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
      let archive = try maintenance.export(session: opened, to: exportDir)
      let validated = try maintenance.prepareImport(archive: archive)
      let outcome = maintenance.importBackup(
        validated, confirmedItemCount: validated.itemCount, session: opened)
      guard let restored = outcome.session else {
        throw SelfCheckError.mismatch("хранилище не открылось: \(String(describing: outcome.error))")
      }
      defer { restored.close() }
      if let error = outcome.error { throw error }
      let count = try restored.items.list(GalleryQuery()).count
      guard count == 1 else { throw SelfCheckError.mismatch("после импорта вещей \(count)") }
      let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
      return "архив \(size) байт, после импорта вещей: \(count)"
    }

    check("Восстановление после прерванной операции") {
      session?.close()
      session = nil
      let layout = StoreLayout(rootURL: URL(fileURLWithPath: store))
      let journal = RecoveryJournal(layout: layout)
      try journal.write(
        RecoveryRecord(
          operation: .move, opId: "check", phase: .copying,
          startedAt: 1, updatedAt: 1, root: store, staging: nil, target: nil))
      let recovered = try coordinator.openExisting(store)
      defer { recovered.close() }
      guard !FileManager.default.fileExists(atPath: journal.url.path) else {
        throw SelfCheckError.mismatch("журнал не удалён")
      }
      return "журнал обработан при открытии"
    }

    check("Целостность после всех операций") {
      let opened = try coordinator.openExisting(store)
      defer { opened.close() }
      let queue = try DatabaseQueue(path: opened.layout.databasePath)
      defer { try? queue.close() }
      let result = try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
      guard result == "ok" else { throw SelfCheckError.mismatch("integrity_check: \(result ?? "-")") }
      return "integrity_check: ok, файлы: \(opened.layout.rootPath)"
    }

    try? FileManager.default.removeItem(at: base)
    return lines
  }

  private static func makePhoto() throws -> ProcessedPhoto {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
    let image = renderer.image { context in
      UIColor(red: 0.7, green: 0.75, blue: 0.8, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    guard let data = image.jpegData(compressionQuality: 0.8) else {
      throw SelfCheckError.photo
    }
    return ProcessedPhoto(
      photoBytes: data,
      thumbBytes: data,
      width: 16,
      height: 16,
      thumbWidth: 16,
      thumbHeight: 16,
      originalWidth: 16,
      originalHeight: 16
    )
  }
}

private enum SelfCheckError: Error, CustomStringConvertible {
  case noSession
  case mismatch(String)
  case photo

  var description: String {
    switch self {
    case .noSession: return "нет открытого хранилища"
    case .mismatch(let text): return text
    case .photo: return "не удалось создать фото"
    }
  }
}
