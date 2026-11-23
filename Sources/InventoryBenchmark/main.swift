import AppKit
import Foundation
import InventoryCore

/// Замеры T05.17 по методике D11.
///
/// Использование:
///   swift run -c release InventoryBenchmark [/путь/для/временных/файлов]
///
/// Создаёт новое хранилище на 500 вещей с фото, затем измеряет:
/// готовность данных при открытии, экспорт и импорт (3 повтора),
/// открытие карточки. Рабочая папка удаляется после замера.
@main
enum InventoryBenchmark {
  static func main() async throws {
    let count = 500
    let repeats = 3
    let arguments = CommandLine.arguments.dropFirst()
    let base =
      arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "InventoryBenchmark-\(UUID().uuidString)", isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: base) }

    let preferences = InMemoryPreferencesStore()
    let coordinator = StorageCoordinator(
      preferences: preferences,
      logger: NullLogger(),
      clock: SystemClock(),
      ids: UuidV4IdGenerator(),
      cleanupOrphansOnOpen: false
    )
    let storeDirectory = base.appendingPathComponent("store", isDirectory: true)

    print("=== Inventory benchmark (D11) ===")
    print("machine: \(machineDescription())")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("items: \(count), repeats: \(repeats)")
    print("work: \(base.path)")

    let photos = try makePhotoVariants()
    let photoBytes = photos.reduce(Int64(0)) {
      $0 + Int64($1.photoBytes.count + $1.thumbBytes.count)
    }
    print("photo variants: \(photos.count), bytes per item: \(photoBytes / Int64(photos.count))")

    var session = try coordinator.createNew(storeDirectory.path)
    let places = try makePlaces(session: session, photo: photos[0])
    let tags = ["Дом", "Работа", "Хобби", "Свет", "Бумага", "Кухня"]
    let statusIds = try session.statuses.list().map(\.id)

    let createStart = Date()
    for index in 0..<count {
      _ = try session.items.create(
        ItemCreate(
          name: "\(itemName(index)) \(index + 1)",
          description: index % 5 == 0 ? "Описание вещи №\(index + 1)" : "",
          notes: "",
          quantity: (index % 3) + 1,
          placeId: index % 7 == 0 ? nil : places[index % places.count],
          statusId: statusIds.isEmpty ? nil : statusIds[index % statusIds.count],
          tags: index % 4 == 0 ? [] : [tags[index % tags.count], tags[(index + 2) % tags.count]],
          photo: photos[index % photos.count]
        )
      )
    }
    print("dataset created in \(seconds(since: createStart)) s")
    print(
      "live photo bytes: \(directorySize(session.layout.photosURL) + directorySize(session.layout.thumbsURL))"
    )

    // Готовность данных: открытие хранилища, галерея и индекс поиска.
    let ids = try session.items.list(GalleryQuery()).map(\.item.id)
    session.close()
    var openTimes: [Double] = []
    for _ in 0..<repeats {
      let start = Date()
      session = try coordinator.openExisting(storeDirectory.path)
      _ = try session.items.list(GalleryQuery())
      await session.search.rebuild()
      openTimes.append(seconds(since: start))
      session.close()
    }
    print("open+gallery+search: \(format(openTimes))")
    session = try coordinator.openExisting(storeDirectory.path)
    defer { session.close() }

    // Карточка: чтение деталей и файла фото.
    var cardTimes: [Double] = []
    for id in ids.prefix(50) {
      let start = Date()
      let details = try session.items.get(id)
      let url = try session.photos.fileURL(for: details.item.photoFile)
      _ = try Data(contentsOf: url)
      cardTimes.append(seconds(since: start) * 1000)
    }
    print("card+photo: \(format(cardTimes)) ms")

    // Экспорт.
    let maintenance = coordinator.makeMaintenance(
      appVersion: "benchmark", temporaryRoot: base)
    var exportTimes: [Double] = []
    var archiveBytes: Int64 = 0
    var archiveURL: URL?
    for repeatIndex in 0..<repeats {
      let directory = base.appendingPathComponent("export-\(repeatIndex)", isDirectory: true)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let start = Date()
      let url = try maintenance.export(session: session, to: directory)
      exportTimes.append(seconds(since: start))
      archiveBytes = fileSize(url)
      archiveURL = url
      print(
        "export #\(repeatIndex + 1): \(secondsText(exportTimes.last!)) s, \(archiveBytes) bytes")
    }

    guard let archiveURL else { return }
    // Импорт: проверка архива + полная замена (как в интерфейсе).
    var importTimes: [Double] = []
    for repeatIndex in 0..<repeats {
      let start = Date()
      let validated = try maintenance.prepareImport(archive: archiveURL)
      let outcome = maintenance.importBackup(
        validated,
        confirmedItemCount: validated.itemCount,
        session: session
      )
      importTimes.append(seconds(since: start))
      if let error = outcome.error {
        print("import #\(repeatIndex + 1) error: \(error.code)")
        exit(1)
      }
      guard let opened = outcome.session else {
        print("import #\(repeatIndex + 1): store did not open")
        exit(1)
      }
      session = opened
      let restored = try session.items.list(GalleryQuery())
      guard restored.count == count else {
        print("import #\(repeatIndex + 1): expected \(count) items, got \(restored.count)")
        exit(1)
      }
      for entry in restored {
        let url = try session.photos.fileURL(for: entry.item.photoFile)
        guard fileManager.fileExists(atPath: url.path) else {
          print("import #\(repeatIndex + 1): missing photo \(entry.item.photoFile)")
          exit(1)
        }
      }
      print(
        "import #\(repeatIndex + 1): \(secondsText(importTimes.last!)) s, items=\(restored.count), photos=ok"
      )
    }

    print("--- summary ---")
    print("archive: \(archiveBytes) bytes")
    print("open+gallery+search: \(format(openTimes)) s")
    print("card+photo: \(format(cardTimes)) ms")
    print("export: \(format(exportTimes)) s")
    print("import (validate+replace): \(format(importTimes)) s")
  }

  // MARK: - Data

  private static func makePlaces(session: StorageSession, photo: ProcessedPhoto) throws -> [String]
  {
    var ids: [String] = []
    for root in ["Дом", "Офис", "Гараж", "Дача"] {
      let place = try session.places.create(
        PlaceCreate(name: root, description: "", parentId: nil, photo: photo))
      ids.append(place.id)
      for shelf in 1...2 {
        let child = try session.places.create(
          PlaceCreate(
            name: "Полка \(shelf)", description: "", parentId: place.id, photo: photo))
        ids.append(child.id)
      }
    }
    return ids
  }

  private static func itemName(_ index: Int) -> String {
    let nouns = ["Лампа", "Книга", "Кружка", "Кабель", "Инструмент", "Коробка", "Игрушка"]
    return nouns[index % nouns.count]
  }

  /// 24 разных фото 900×675 и превью 400×300: архиву есть что сжимать,
  /// но подготовка набора не занимает заметного времени.
  private static func makePhotoVariants() throws -> [ProcessedPhoto] {
    var variants: [ProcessedPhoto] = []
    for index in 0..<24 {
      let photo = try makeJPEG(width: 900, height: 675, seed: UInt64(index + 1))
      let thumb = try makeJPEG(width: 400, height: 300, seed: UInt64(index + 101))
      variants.append(
        ProcessedPhoto(
          photoBytes: photo,
          thumbBytes: thumb,
          width: 900,
          height: 675,
          thumbWidth: 400,
          thumbHeight: 300,
          originalWidth: 900,
          originalHeight: 675
        )
      )
    }
    return variants
  }

  private static func makeJPEG(width: Int, height: Int, seed: UInt64) throws -> Data {
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 3,
        bitsPerPixel: 24
      ),
      let buffer = rep.bitmapData
    else {
      throw BenchmarkError.photoGenerationFailed
    }
    var state = seed
    for y in 0..<height {
      for x in 0..<width {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let noise = Int((state >> 40) % 24)
        let offset = (y * width + x) * 3
        buffer[offset] = UInt8(clamping: (x * 255 / width + noise + Int(seed)) % 256)
        buffer[offset + 1] = UInt8(clamping: (y * 255 / height + noise) % 256)
        buffer[offset + 2] = UInt8(clamping: ((x + y) * 127 / (width + height) + noise) % 256)
      }
    }
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
      throw BenchmarkError.photoGenerationFailed
    }
    return data
  }

  // MARK: - Helpers

  private static func machineDescription() -> String {
    let model = sysctlString("hw.model")
    let chip = sysctlString("machdep.cpu.brand_string")
    return "\(model), \(chip)"
  }

  private static func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }

  private static func seconds(since start: Date) -> Double {
    Date().timeIntervalSince(start)
  }

  private static func secondsText(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private static func format(_ values: [Double]) -> String {
    let sorted = values.sorted()
    let best = sorted.first ?? 0
    let median = sorted[sorted.count / 2]
    let worst = sorted.last ?? 0
    return
      "best \(String(format: "%.2f", best)), median \(String(format: "%.2f", median)), worst \(String(format: "%.2f", worst))"
  }

  private static func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
  }

  private static func directorySize(_ url: URL) -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
      guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true
      else { continue }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }
}

private enum BenchmarkError: Error {
  case photoGenerationFailed
}
