import Foundation
import InventoryCore
import Testing
import ZIPFoundation

@Suite("Проверка оболочки архива")
struct BackupArchiveReaderTests {
  private struct Fixture {
    let root: URL
    let staging: URL
  }

  private func makeFixture() throws -> Fixture {
    let root = try TestSupport.temporaryDirectory()
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    return Fixture(root: root, staging: staging)
  }

  private enum Kind {
    case file
    case directory
    case symlink
  }

  private struct Member {
    let path: String
    let kind: Kind
    let bytes: Data
    var compression: CompressionMethod = .deflate
  }

  private func makeZip(_ members: [Member], at url: URL) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for member in members {
      let type: Entry.EntryType
      switch member.kind {
      case .file: type = .file
      case .directory: type = .directory
      case .symlink: type = .symlink
      }
      let payload = member.kind == .directory ? Data() : member.bytes
      try archive.addEntry(
        with: member.path,
        type: type,
        uncompressedSize: Int64(payload.count),
        compressionMethod: member.kind == .file ? member.compression : .none
      ) { position, size in
        let start = Int(position)
        guard start < payload.count else { return Data() }
        return payload.subdata(in: start..<min(start + size, payload.count))
      }
    }
  }

  private func manifest(
    formatVersion: Any = 1,
    extra: [String: Any] = [:]
  ) throws -> Data {
    var object: [String: Any] = [
      "format_version": formatVersion,
      "app_version": "1.0",
      "exported_at": 1_700_000_000_000,
      "counts": ["places": 0],
    ]
    for (key, value) in extra { object[key] = value }
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func dataJSON() -> Data {
    Data(#"{"places":[],"items":[]}"#.utf8)
  }

  private func validMembers(extra: [Member] = []) throws -> [Member] {
    [
      Member(path: "manifest.json", kind: .file, bytes: try manifest()),
      Member(path: "data.json", kind: .file, bytes: dataJSON()),
      Member(path: "photos/a.jpg", kind: .file, bytes: Data([0xFF, 0xD8, 0x01])),
      Member(path: "thumbs/a.jpg", kind: .file, bytes: Data([0xFF, 0xD8, 0x02])),
    ] + extra
  }

  private func expectRejected(
    _ code: AppErrorCode,
    members: [Member],
    limits: BackupArchiveLimits = .v1,
    fixture: Fixture,
    sourceComment: String = ""
  ) throws {
    let archiveURL = fixture.root.appendingPathComponent("\(UUID().uuidString).inventory.zip")
    try makeZip(members, at: archiveURL)
    let reader = BackupArchiveReader(limits: limits, temporaryRoot: fixture.staging)
    do {
      let staged = try reader.stage(archiveAt: archiveURL)
      staged.discard()
      Issue.record("Ожидалась ошибка \(code.rawValue) \(sourceComment)")
    } catch let error as AppException {
      #expect(error.code == code, "\(sourceComment): \(error)")
    }
    #expect(try contents(of: fixture.staging).isEmpty)
  }

  private func contents(of directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
  }

  @Test("Корректный архив распаковывается в staging и совпадает с манифестом")
  func stagesValidArchive() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let archiveURL = fixture.root.appendingPathComponent("ok.inventory.zip")
    try makeZip(try validMembers(), at: archiveURL)

    let reader = BackupArchiveReader(temporaryRoot: fixture.staging)
    let staged = try reader.stage(archiveAt: archiveURL)

    #expect(staged.manifest.formatVersion == 1)
    #expect(staged.manifest.appVersion == "1.0")
    #expect(staged.filePaths == ["photos/a.jpg", "thumbs/a.jpg"])
    #expect(try Data(contentsOf: staged.dataURL) == dataJSON())
    #expect(
      try Data(contentsOf: staged.directoryURL.appendingPathComponent("photos/a.jpg"))
        == Data([0xFF, 0xD8, 0x01]))

    staged.discard()
    #expect(try contents(of: fixture.staging).isEmpty)
  }

  @Test("Повреждённый ZIP отклоняется до распаковки")
  func rejectsBrokenZip() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let archiveURL = fixture.root.appendingPathComponent("broken.inventory.zip")
    try Data("это не архив".utf8).write(to: archiveURL)

    let reader = BackupArchiveReader(temporaryRoot: fixture.staging)
    do {
      _ = try reader.stage(archiveAt: archiveURL)
      Issue.record("Ожидалась ошибка backupInvalidZip")
    } catch let error as AppException {
      #expect(error.code == .backupInvalidZip)
    }
    #expect(try contents(of: fixture.staging).isEmpty)
  }

  @Test("Без manifest.json архив отклоняется")
  func rejectsMissingManifest() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try expectRejected(
      .backupManifestInvalid,
      members: [Member(path: "data.json", kind: .file, bytes: dataJSON())],
      fixture: fixture,
      sourceComment: "missing manifest"
    )
  }

  @Test("Архив новее поддерживаемой версии отклоняется с понятным кодом")
  func rejectsNewerFormat() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let members = [
      Member(path: "manifest.json", kind: .file, bytes: try manifest(formatVersion: 2)),
      Member(path: "data.json", kind: .file, bytes: dataJSON()),
    ]
    let archiveURL = fixture.root.appendingPathComponent("new.inventory.zip")
    try makeZip(members, at: archiveURL)

    let reader = BackupArchiveReader(temporaryRoot: fixture.staging)
    do {
      _ = try reader.stage(archiveAt: archiveURL)
      Issue.record("Ожидалась ошибка backupNewerFormat")
    } catch let error as AppException {
      #expect(error.code == .backupNewerFormat)
      #expect(error.int("found") == 2)
      #expect(error.int("supported") == 1)
    }
    #expect(try contents(of: fixture.staging).isEmpty)
  }

  @Test("Неверный format_version отклоняется: строка, ноль, отсутствие, булево")
  func rejectsInvalidFormatVersion() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let variants: [(String, Any)] = [
      ("строка", "1"),
      ("ноль", 0),
      ("булево", true),
    ]
    for (name, value) in variants {
      try expectRejected(
        .backupManifestInvalid,
        members: [
          Member(path: "manifest.json", kind: .file, bytes: try manifest(formatVersion: value)),
          Member(path: "data.json", kind: .file, bytes: dataJSON()),
        ],
        fixture: fixture,
        sourceComment: name
      )
    }

    let withoutVersion = try JSONSerialization.data(
      withJSONObject: [
        "app_version": "1.0", "exported_at": 1, "counts": [:],
      ] as [String: Any])
    try expectRejected(
      .backupManifestInvalid,
      members: [
        Member(path: "manifest.json", kind: .file, bytes: withoutVersion),
        Member(path: "data.json", kind: .file, bytes: dataJSON()),
      ],
      fixture: fixture,
      sourceComment: "без format_version"
    )
  }

  @Test("Лишние поля манифеста в v1 отклоняются")
  func rejectsUnknownManifestFields() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try expectRejected(
      .backupManifestInvalid,
      members: [
        Member(
          path: "manifest.json",
          kind: .file,
          bytes: try manifest(extra: ["unexpected": "x"])),
        Member(path: "data.json", kind: .file, bytes: dataJSON()),
      ],
      fixture: fixture,
      sourceComment: "unknown field"
    )
  }

  @Test("Абсолютные пути, выход через .. и чужие папки не распаковываются")
  func rejectsZipSlip() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let paths = [
      "/etc/evil.jpg",
      "photos/../../evil.jpg",
      "photos/../evil.jpg",
      "_safety/inventory.db",
      "logs/app.log",
      "photos/sub/deep.jpg",
    ]
    for path in paths {
      let members = try validMembers(extra: [
        Member(path: path, kind: .file, bytes: Data([0x01]))
      ])
      try expectRejected(
        .backupInvalidZip,
        members: members,
        fixture: fixture,
        sourceComment: path
      )
    }
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("evil.jpg").path))
  }

  @Test("Символические ссылки отклоняются")
  func rejectsSymlinks() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try expectRejected(
      .backupInvalidZip,
      members: try validMembers(extra: [
        Member(
          path: "photos/link.jpg",
          kind: .symlink,
          bytes: Data("/etc/passwd".utf8),
          compression: .none)
      ]),
      fixture: fixture,
      sourceComment: "symlink"
    )
  }

  @Test("Повтор пути и коллизия регистра отклоняются")
  func rejectsDuplicatesAndCollisions() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try expectRejected(
      .backupInvalidZip,
      members: try validMembers(extra: [
        Member(path: "photos/a.jpg", kind: .file, bytes: Data([0x03]))
      ]),
      fixture: fixture,
      sourceComment: "duplicate"
    )
    try expectRejected(
      .backupInvalidZip,
      members: try validMembers(extra: [
        Member(path: "photos/A.JPG", kind: .file, bytes: Data([0x03]))
      ]),
      fixture: fixture,
      sourceComment: "case collision"
    )
  }

  @Test("Архив без data.json отклоняется")
  func rejectsMissingData() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try expectRejected(
      .backupInvalidZip,
      members: [Member(path: "manifest.json", kind: .file, bytes: try manifest())],
      fixture: fixture,
      sourceComment: "missing data"
    )
  }

  @Test("Подозрительный коэффициент сжатия отклоняется")
  func rejectsCompressionBomb() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bomb = Data(count: 2_000_000)
    try expectRejected(
      .backupLimitExceeded,
      members: try validMembers(extra: [
        Member(path: "photos/bomb.jpg", kind: .file, bytes: bomb)
      ]),
      fixture: fixture,
      sourceComment: "ratio"
    )
  }

  @Test("Превышение числа файлов и размера распаковки отклоняется")
  func rejectsLimits() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let fewEntries = BackupArchiveLimits(maxEntries: 3)
    try expectRejected(
      .backupLimitExceeded,
      members: try validMembers(),
      limits: fewEntries,
      fixture: fixture,
      sourceComment: "entries"
    )

    let smallTotal = BackupArchiveLimits(maxUnpackedBytes: 10)
    try expectRejected(
      .backupLimitExceeded,
      members: try validMembers(),
      limits: smallTotal,
      fixture: fixture,
      sourceComment: "total"
    )

    let smallData = BackupArchiveLimits(maxDataJSONBytes: 4)
    try expectRejected(
      .backupLimitExceeded,
      members: try validMembers(),
      limits: smallData,
      fixture: fixture,
      sourceComment: "data.json"
    )
  }

  @Test("Лимиты D11 совпадают с утверждённым значением")
  func v1LimitsMatchDecision() {
    #expect(BackupArchiveLimits.v1.maxUnpackedBytes == 2 * 1024 * 1024 * 1024)
    #expect(BackupArchiveLimits.v1.maxEntries == 100_000)
    #expect(BackupArchiveLimits.v1.maxCompressionRatio == 100)
    #expect(BackupArchiveLimits.v1.maxDataJSONBytes == 512 * 1024 * 1024)
  }
}
