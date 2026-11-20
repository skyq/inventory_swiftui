import AppKit
import Foundation
import GRDB
import InventoryCore

/// Детерминированный генератор тестового хранилища для этапа 2.
///
/// Использование:
///   swift run InventoryFixture /path/to/new/store
///
/// Генератор отказывается работать, если в папке уже есть база.
@main
enum InventoryFixture {
  static func main() {
    let arguments = CommandLine.arguments.dropFirst()
    guard let rawPath = arguments.first, !rawPath.isEmpty else {
      print("Использование: InventoryFixture <путь к новой папке данных>")
      exit(64)
    }

    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    let defaultStore = DefaultStoreLocation.url().standardizedFileURL.path
    if path == defaultStore {
      print("Отказ: нельзя генерировать поверх рабочего хранилища \(defaultStore)")
      exit(65)
    }

    do {
      try generate(at: path)
    } catch {
      print("Ошибка генерации: \(error)")
      exit(1)
    }
  }

  private static func generate(at path: String) throws {
    let preferences = InMemoryPreferencesStore()
    let coordinator = StorageCoordinator(
      preferences: preferences,
      logger: NullLogger(),
      clock: FixtureClock(),
      ids: FixtureIds(prefix: "fixture"),
      cleanupOrphansOnOpen: false
    )
    let session = try coordinator.createNew(path)
    defer { session.close() }

    let photo = try makePhoto()
    let places = try makePlaces(session: session, photo: photo)
    let tagNames = ["Дом", "Работа", "Хобби", "Свет", "Бумага", "Кухня"]

    let statusIds = try session.statuses.list().map(\.id)

    let createStart = Date()
    for index in 1...500 {
      let tags = tagsFor(index: index, all: tagNames)
      let placeId: String? = index % 7 == 0 ? nil : places[index % places.count]
      let created = try session.items.create(
        ItemCreate(
          name: nameFor(index: index),
          description: index % 5 == 0 ? "Тестовая вещь №\(index)" : "",
          notes: index % 11 == 0 ? "Заметка для вещи \(index)" : "",
          quantity: (index % 4) + 1,
          placeId: placeId,
          statusId: nil,
          tags: tags,
          photo: photo
        )
      )

      if index % 9 == 0, statusIds.count > 1 {
        let statusId = statusIds[index % statusIds.count]
        try session.database.write { db in
          try db.execute(
            sql: "UPDATE items SET status_id = ? WHERE id = ?",
            arguments: [statusId, created.item.id]
          )
        }
      }
    }
    let createSeconds = Date().timeIntervalSince(createStart)

    let listStart = Date()
    let entries = try session.items.list(GalleryQuery(sort: .createdAt, direction: .desc))
    let listMilliseconds = Date().timeIntervalSince(listStart) * 1000

    var getTotal: TimeInterval = 0
    for entry in entries.prefix(50) {
      let start = Date()
      _ = try session.items.get(entry.item.id)
      getTotal += Date().timeIntervalSince(start)
    }
    let averageGet = entries.isEmpty ? 0 : getTotal / Double(min(entries.count, 50)) * 1000

    print("Хранилище: \(path)")
    print("Мест: \(places.count), вещей: \(entries.count)")
    print("Создание 500 вещей: \(String(format: "%.2f", createSeconds)) с")
    print("Запрос галереи: \(String(format: "%.1f", listMilliseconds)) мс")
    print("Среднее открытие карточки (get): \(String(format: "%.2f", averageGet)) мс")
  }

  private static func makePlaces(session: StorageSession, photo: ProcessedPhoto) throws -> [String]
  {
    let roots = ["Дом", "Офис", "Гараж", "Дача"]
    var ids: [String] = []
    for root in roots {
      let place = try session.places.create(
        PlaceCreate(name: root, description: "", parentId: nil, photo: photo)
      )
      ids.append(place.id)
      for shelf in 1...3 {
        let child = try session.places.create(
          PlaceCreate(
            name: "Полка \(shelf)",
            description: "",
            parentId: place.id,
            photo: photo
          )
        )
        ids.append(child.id)
      }
    }
    return ids
  }

  private static func tagsFor(index: Int, all: [String]) -> [String] {
    let count = index % 4
    guard count > 0 else { return [] }
    return (0..<count).map { all[(index + $0) % all.count] }
  }

  private static func nameFor(index: Int) -> String {
    let nouns = ["Лампа", "Книга", "Кружка", "Кабель", "Инструмент", "Коробка", "Игрушка"]
    return "\(nouns[index % nouns.count]) \(index)"
  }

  /// Синтетическая JPEG-картинка: не использует данные пользователя.
  private static func makePhoto() throws -> ProcessedPhoto {
    let photoData = try makeJPEG(red: 0.7, green: 0.75, blue: 0.8)
    let thumbData = try makeJPEG(red: 0.7, green: 0.75, blue: 0.8)
    return ProcessedPhoto(
      photoBytes: photoData,
      thumbBytes: thumbData,
      width: 16,
      height: 16,
      thumbWidth: 16,
      thumbHeight: 16,
      originalWidth: 16,
      originalHeight: 16
    )
  }

  private static func makeJPEG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let size = 16
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      throw FixtureError.photoGenerationFailed
    }
    let color = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    for y in 0..<size {
      for x in 0..<size {
        rep.setColor(color, atX: x, y: y)
      }
    }
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
      throw FixtureError.photoGenerationFailed
    }
    return data
  }
}

private enum FixtureError: Error {
  case photoGenerationFailed
}

private final class FixtureClock: Clock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Int64 = 1_700_000_000_000

  func nowMilliseconds() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    current += 1
    return current
  }
}

private final class FixtureIds: IdGenerator, @unchecked Sendable {
  private let lock = NSLock()
  private let prefix: String
  private var counter = 0

  init(prefix: String) {
    self.prefix = prefix
  }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    counter += 1
    return String(format: "%@-%06d", prefix, counter)
  }
}
