import Foundation
import InventoryCore
import Testing
import ZIPFoundation

@Suite("Архив inventory.zip")
struct BackupCodecTests {
  @Test("Архив содержит manifest, data и все связанные фото")
  func exportsManifestDataAndFiles() throws {
    let destination = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    let (session, snapshot) = try makeSnapshot()
    defer {
      session.close()
      snapshot.discard()
      try? FileManager.default.removeItem(at: session.layout.rootURL)
    }

    let recorder = ProgressRecorder()
    let archiveURL = try BackupCodec.exportV1(
      snapshot: snapshot,
      to: destination,
      appVersion: "1.2.3",
      timeZone: TimeZone(secondsFromGMT: 0)!,
      progress: { recorder.record($0) }
    )

    #expect(archiveURL.lastPathComponent == "Inventory-2023-11-14.inventory.zip")
    #expect(FileManager.default.fileExists(atPath: archiveURL.path))

    let archive = try Archive(url: archiveURL, accessMode: .read)
    let paths = Set(archive.map(\.path))
    #expect(
      paths == Set(["manifest.json", "data.json"] + snapshot.filePaths))

    let manifestData = try data(in: archive, at: "manifest.json")
    let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
    #expect(manifest.formatVersion == BackupFormat.version)
    #expect(manifest.appVersion == "1.2.3")
    #expect(manifest.exportedAt == snapshot.createdAt)
    #expect(manifest.counts == snapshot.counts)

    let rawData = try data(in: archive, at: "data.json")
    let tables = try JSONDecoder().decode(
      [String: [[String: BackupValue]]].self, from: rawData)
    #expect(Set(tables.keys) == Set(BackupFormat.tableNames))
    #expect(tables["places"]?.count == 1)
    #expect(tables["items"]?.count == 1)
    #expect(tables["tags"]?.isEmpty == true)
    #expect(tables["item_tags"]?.isEmpty == true)
    #expect(tables["status_changes"]?.isEmpty == true)
    #expect(tables["transfers"]?.isEmpty == true)
    #expect(tables["places"]?.first?["name"] == .text("Кладовая"))
    #expect(tables["items"]?.first?["name"] == .text("Фонарь"))
    #expect(String(decoding: rawData, as: UTF8.self).contains("В наличии"))

    for path in snapshot.filePaths {
      let archived = try data(in: archive, at: path)
      let original = try Data(contentsOf: snapshot.fileURL(for: path))
      #expect(archived == original)
    }

    let progress = recorder.values
    #expect(progress.first == BackupExportProgress(completedSteps: 0, totalSteps: 6))
    #expect(progress.last == BackupExportProgress(completedSteps: 6, totalSteps: 6))
    #expect(progress == progress.sorted { $0.completedSteps < $1.completedSteps })
    #expect(noTemporaryFiles(in: destination))
  }

  @Test("Сбой упаковки не оставляет финальный архив и временный файл")
  func failedExportLeavesNoArchive() throws {
    let destination = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    let (session, snapshot) = try makeSnapshot()
    defer {
      session.close()
      snapshot.discard()
      try? FileManager.default.removeItem(at: session.layout.rootURL)
    }

    let missing = try #require(snapshot.filePaths.first)
    try FileManager.default.removeItem(at: snapshot.fileURL(for: missing))

    let expectedURL = destination.appendingPathComponent(
      BackupCodec.fileName(
        for: snapshot.createdAt, timeZone: TimeZone(secondsFromGMT: 0)!))
    let previous = Data("прежний архив".utf8)
    try previous.write(to: expectedURL)

    do {
      _ = try BackupCodec.exportV1(
        snapshot: snapshot,
        to: destination,
        appVersion: "1.0",
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
      Issue.record("Ожидалась ошибка backupIntegrityFailed")
    } catch let error as AppException {
      #expect(error.code == .backupIntegrityFailed)
    }

    #expect(try Data(contentsOf: expectedURL) == previous)
    #expect(noTemporaryFiles(in: destination))
  }

  @Test("Успешный экспорт заменяет прежний файл целиком")
  func successfulExportReplacesExistingArchive() throws {
    let destination = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    let (session, snapshot) = try makeSnapshot()
    defer {
      session.close()
      snapshot.discard()
      try? FileManager.default.removeItem(at: session.layout.rootURL)
    }

    let expectedURL = destination.appendingPathComponent(
      BackupCodec.fileName(
        for: snapshot.createdAt, timeZone: TimeZone(secondsFromGMT: 0)!))
    try Data("старый файл".utf8).write(to: expectedURL)

    let result = try BackupCodec.exportV1(
      snapshot: snapshot,
      to: destination,
      appVersion: "1.0",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(result == expectedURL)

    let archive = try Archive(url: result, accessMode: .read)
    #expect(archive["manifest.json"] != nil)
    #expect(archive["data.json"] != nil)
    #expect(noTemporaryFiles(in: destination))
  }

  @Test("Имя архива использует локальную дату снимка")
  func fileNameUsesRequestedTimeZone() {
    let createdAt: Int64 = 1_700_003_400_000
    let utcName = BackupCodec.fileName(
      for: createdAt, timeZone: TimeZone(secondsFromGMT: 0)!)
    let plusTenName = BackupCodec.fileName(
      for: createdAt, timeZone: TimeZone(secondsFromGMT: 10 * 3600)!)
    #expect(utcName == "Inventory-2023-11-14.inventory.zip")
    #expect(plusTenName == "Inventory-2023-11-15.inventory.zip")
  }

  @Test("Пустые таблицы сериализуются как пустые массивы")
  func emptyTablesAreArrays() throws {
    let destination = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    let session = try TestSupport.makeSession().0
    let snapshotRoot = try TestSupport.temporaryDirectory()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: session.layout.rootURL)
      try? FileManager.default.removeItem(at: snapshotRoot)
    }

    let service = BackupSnapshotService(
      database: session.database,
      layout: session.layout,
      gate: session.writeGate,
      clock: FixedTestClock(value: 1_700_000_000_000),
      temporaryRoot: snapshotRoot
    )
    let snapshot = try service.makeSnapshot()
    defer { snapshot.discard() }

    let archiveURL = try BackupCodec.exportV1(
      snapshot: snapshot,
      to: destination,
      appVersion: "1.0",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let archive = try Archive(url: archiveURL, accessMode: .read)
    let raw = try data(in: archive, at: "data.json")
    let tables = try JSONDecoder().decode(
      [String: [[String: BackupValue]]].self, from: raw)

    #expect(tables.count == 9)
    #expect(tables["places"]?.isEmpty == true)
    #expect(tables["items"]?.isEmpty == true)
    #expect(tables["people"]?.isEmpty == true)
    #expect(tables["statuses"]?.count == 7)
    #expect(tables["settings"]?.count == 3)
  }

  // MARK: - Вспомогательное

  private func makeSnapshot() throws -> (StorageSession, BackupSnapshot) {
    let session = try TestSupport.makeSession().0
    let place = try TestSupport.createPlace(session, name: "Кладовая")
    _ = try TestSupport.createItem(session, name: "Фонарь", placeId: place.id)

    let service = BackupSnapshotService(
      database: session.database,
      layout: session.layout,
      gate: session.writeGate,
      clock: FixedTestClock(value: 1_700_000_000_000),
      temporaryRoot: FileManager.default.temporaryDirectory
    )
    let snapshot = try service.makeSnapshot()
    return (session, snapshot)
  }

  private func data(in archive: Archive, at path: String) throws -> Data {
    guard let entry = archive[path] else {
      throw ArchiveTestError.missingEntry(path)
    }
    var result = Data()
    _ = try archive.extract(entry) { chunk in
      result.append(chunk)
    }
    return result
  }

  private func noTemporaryFiles(in directory: URL) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return !names.contains { $0.hasSuffix(".tmp") }
  }
}

private enum ArchiveTestError: Error {
  case missingEntry(String)
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [BackupExportProgress] = []

  var values: [BackupExportProgress] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record(_ progress: BackupExportProgress) {
    lock.lock()
    recorded.append(progress)
    lock.unlock()
  }
}
