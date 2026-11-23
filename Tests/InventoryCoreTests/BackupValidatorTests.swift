import Foundation
import InventoryCore
import Testing

@Suite("Проверка данных архива")
struct BackupValidatorTests {
  private static let placeA = "00000000-0000-4000-8000-0000000000a1"
  private static let placeB = "00000000-0000-4000-8000-0000000000a2"
  private static let statusActive = "00000000-0000-4000-8000-0000000000b1"
  private static let statusArchived = "00000000-0000-4000-8000-0000000000b2"
  private static let itemId = "00000000-0000-4000-8000-0000000000c1"
  private static let personId = "00000000-0000-4000-8000-0000000000d1"
  private static let tagId = "00000000-0000-4000-8000-0000000000e1"
  private static let transferId = "00000000-0000-4000-8000-0000000000f1"

  private typealias Row = [String: Any]
  private typealias Tables = [String: [Row]]

  private func validTables() -> Tables {
    [
      "places": [
        [
          "id": Self.placeA, "parent_id": NSNull(), "name": "Полка", "description": "",
          "photo_file": "photos/a.jpg", "thumb_file": "thumbs/a.jpg",
          "created_at": 1, "updated_at": 1,
        ]
      ],
      "statuses": [
        [
          "id": Self.statusActive, "name": "В наличии", "is_archived": 0,
          "sort_order": 0, "created_at": 1,
        ],
        [
          "id": Self.statusArchived, "name": "Продал", "is_archived": 1,
          "sort_order": 1, "created_at": 1,
        ],
      ],
      "people": [],
      "items": [
        [
          "id": Self.itemId, "name": "Фонарь", "description": "", "notes": "",
          "quantity": 1, "place_id": Self.placeA, "status_id": Self.statusActive,
          "photo_file": "photos/i.jpg", "thumb_file": "thumbs/i.jpg",
          "created_at": 1, "updated_at": 1,
        ]
      ],
      "tags": [],
      "item_tags": [],
      "status_changes": [],
      "transfers": [],
      "settings": [
        ["key": "default_status_id", "value": Self.statusActive],
        ["key": "transfer_status_id", "value": Self.statusActive],
        ["key": "return_status_id", "value": Self.statusActive],
      ],
    ]
  }

  private func counts(of tables: Tables) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: BackupFormat.tableNames.map { ($0, tables[$0]?.count ?? 0) })
  }

  private func stage(
    _ tables: Tables,
    counts overrideCounts: [String: Int]? = nil,
    photos: [String] = ["photos/a.jpg", "photos/i.jpg", "thumbs/a.jpg", "thumbs/i.jpg"],
    formatVersion: Int = 1
  ) throws -> StagedBackupArchive {
    let root = try TestSupport.temporaryDirectory()
    for path in photos {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([0xFF, 0xD8]).write(to: url)
    }
    let dataURL = root.appendingPathComponent("data.json")
    let rawTables = tables.mapValues { $0 as Any }
    let data = try JSONSerialization.data(withJSONObject: rawTables)
    try data.write(to: dataURL)
    let manifest = BackupManifest(
      formatVersion: formatVersion,
      appVersion: "1.0",
      exportedAt: 1,
      counts: overrideCounts ?? counts(of: tables)
    )
    return StagedBackupArchive(
      directoryURL: root,
      manifest: manifest,
      dataURL: dataURL,
      filePaths: photos.sorted()
    )
  }

  private func expectRejected(
    _ code: AppErrorCode,
    _ comment: String,
    _ make: () throws -> StagedBackupArchive
  ) throws {
    let staged = try make()
    defer { staged.discard() }
    do {
      _ = try BackupFormatRegistry.validate(staged)
      Issue.record("Ожидалась ошибка \(code.rawValue): \(comment)")
    } catch let error as AppException {
      #expect(error.code == code, "\(comment): \(error)")
    }
  }

  @Test("Валидный v1 принимается и отдаёт строки и число вещей")
  func acceptsValidV1() throws {
    let staged = try stage(validTables())
    defer { staged.discard() }

    let validated = try BackupFormatRegistry.validate(staged)
    #expect(validated.itemCount == 1)
    #expect(validated.counts["places"] == 1)
    #expect(validated.tables.map(\.name) == BackupFormat.tableNames)
    #expect(validated.table(named: "items")?.rows.first?["name"] == .text("Фонарь"))
  }

  @Test("Отсутствующее фото отклоняется")
  func rejectsMissingPhoto() throws {
    try expectRejected(.backupIntegrityFailed, "thumb not in archive") {
      try stage(validTables(), photos: ["photos/a.jpg", "photos/i.jpg", "thumbs/a.jpg"])
    }
  }

  @Test("Несуществующая ссылка FK отклоняется")
  func rejectsMissingForeignKey() throws {
    var tables = validTables()
    tables["items"]?[0]["place_id"] = "00000000-0000-4000-8000-0000000000ff"
    try expectRejected(.backupIntegrityFailed, "place_id") { try stage(tables) }
  }

  @Test("Дубликат id отклоняется")
  func rejectsDuplicateId() throws {
    var tables = validTables()
    let duplicate = tables["places"]![0]
    tables["places"]?.append(duplicate)
    try expectRejected(.backupIntegrityFailed, "duplicate place id") {
      try stage(
        tables,
        counts: [
          "places": 2, "statuses": 2, "people": 0, "items": 1,
          "tags": 0, "item_tags": 0, "status_changes": 0, "transfers": 0, "settings": 3,
        ])
    }
  }

  @Test("Несовпадение счётчика манифеста отклоняется")
  func rejectsCountMismatch() throws {
    var counts = counts(of: validTables())
    counts["items"] = 2
    try expectRejected(.backupIntegrityFailed, "items count") {
      try stage(validTables(), counts: counts)
    }
  }

  @Test("Цикл иерархии мест отклоняется")
  func rejectsPlaceCycle() throws {
    var tables = validTables()
    tables["places"] = [
      [
        "id": Self.placeA, "parent_id": Self.placeB, "name": "A", "description": "",
        "photo_file": "photos/a.jpg", "thumb_file": "thumbs/a.jpg",
        "created_at": 1, "updated_at": 1,
      ],
      [
        "id": Self.placeB, "parent_id": Self.placeA, "name": "B", "description": "",
        "photo_file": "photos/a.jpg", "thumb_file": "thumbs/a.jpg",
        "created_at": 1, "updated_at": 1,
      ],
    ]
    try expectRejected(.backupIntegrityFailed, "cycle") {
      try stage(tables, counts: counts(of: tables))
    }
  }

  @Test("Архивный статус в настройках по умолчанию отклоняется")
  func rejectsArchivedDefaultStatus() throws {
    var tables = validTables()
    tables["settings"]?[0]["value"] = Self.statusArchived
    try expectRejected(.backupIntegrityFailed, "archived default") { try stage(tables) }
  }

  @Test("Отсутствующая настройка статуса отклоняется")
  func rejectsMissingDefaultSetting() throws {
    var tables = validTables()
    tables["settings"]?.removeLast()
    try expectRejected(.backupIntegrityFailed, "missing return_status_id") {
      try stage(tables, counts: counts(of: tables))
    }
  }

  @Test("Неверный тип и NULL в обязательной колонке отклоняются")
  func rejectsWrongTypesAndNulls() throws {
    var wrongType = validTables()
    wrongType["items"]?[0]["quantity"] = "1"
    try expectRejected(.backupIntegrityFailed, "text quantity") { try stage(wrongType) }

    var nullName = validTables()
    nullName["items"]?[0]["name"] = NSNull()
    try expectRejected(.backupIntegrityFailed, "null name") { try stage(nullName) }
  }

  @Test("Лишняя и отсутствующая колонка отклоняются")
  func rejectsUnknownAndMissingColumns() throws {
    var extra = validTables()
    extra["items"]?[0]["extra"] = "x"
    try expectRejected(.backupIntegrityFailed, "extra column") { try stage(extra) }

    var missing = validTables()
    missing["items"]?[0].removeValue(forKey: "notes")
    try expectRejected(.backupIntegrityFailed, "missing column") { try stage(missing) }
  }

  @Test("Не-UUID идентификатор отклоняется")
  func rejectsNonUUIDId() throws {
    var tables = validTables()
    tables["places"]?[0]["id"] = "place-1"
    try expectRejected(.backupIntegrityFailed, "non-UUID") { try stage(tables) }
  }

  @Test("Нулевое количество и неверный вид передачи отклоняются")
  func rejectsInvalidValues() throws {
    var quantity = validTables()
    quantity["items"]?[0]["quantity"] = 0
    try expectRejected(.backupIntegrityFailed, "quantity 0") { try stage(quantity) }

    var tables = validTables()
    tables["people"] = [
      [
        "id": Self.personId, "name": "Анна", "phone": "", "notes": "",
        "is_archived": 0, "created_at": 1, "updated_at": 1,
      ]
    ]
    tables["transfers"] = [
      [
        "id": Self.transferId, "item_id": Self.itemId, "kind": "lend",
        "person_id": Self.personId, "comment": "", "created_at": 1,
      ]
    ]
    try expectRejected(.backupIntegrityFailed, "kind") {
      try stage(tables, counts: counts(of: tables))
    }
  }

  @Test("Дубликат тега по ключу и пара item/tag отклоняются")
  func rejectsDuplicateTagKeys() throws {
    var tables = validTables()
    tables["tags"] = [
      ["id": Self.tagId, "name": "Свет", "name_key": "свет"],
      ["id": "00000000-0000-4000-8000-0000000000e2", "name": "свет", "name_key": "свет"],
    ]
    try expectRejected(.backupIntegrityFailed, "name_key") {
      try stage(tables, counts: counts(of: tables))
    }
  }

  @Test("Путь фото вне photos/thumbs отклоняется")
  func rejectsEscapingPhotoPath() throws {
    var tables = validTables()
    tables["items"]?[0]["photo_file"] = "photos/../../secret.jpg"
    try expectRejected(.backupIntegrityFailed, "escape") {
      try stage(tables, photos: ["photos/a.jpg", "thumbs/a.jpg", "thumbs/i.jpg"])
    }
  }

  @Test("Отсутствующая таблица отклоняется")
  func rejectsMissingTable() throws {
    var tables = validTables()
    tables.removeValue(forKey: "tags")
    try expectRejected(.backupIntegrityFailed, "no tags") { try stage(tables) }
  }

  @Test("v1 без is_hidden принимается; v2 требует is_hidden в статусах")
  func v1AcceptedV2RequiresHidden() throws {
    let v1 = try stage(validTables())
    defer { v1.discard() }
    #expect(try BackupFormatRegistry.validate(v1).counts["statuses"] == 2)

    var withHidden = validTables()
    withHidden["statuses"] = withHidden["statuses"]?.map { row in
      var row = row
      row["is_hidden"] = 0
      return row
    }
    let v2 = try stage(withHidden, formatVersion: 2)
    defer { v2.discard() }
    #expect(try BackupFormatRegistry.validate(v2).counts["statuses"] == 2)

    try expectRejected(.backupIntegrityFailed, "v2 без is_hidden") {
      try stage(validTables(), formatVersion: 2)
    }
  }

  @Test("Формат новее и неизвестный формат отклоняются через реестр")
  func registryRejectsUnsupportedVersions() throws {
    try expectRejected(.backupNewerFormat, "version 3") {
      try stage(validTables(), formatVersion: 3)
    }
    try expectRejected(.backupManifestInvalid, "version 0") {
      try stage(validTables(), formatVersion: 0)
    }
  }

  @Test("Архив, записанный приложением, проходит чтение и проверку без изменения живых данных")
  func roundTripFromRealSessionPasses() throws {
    let root = try TestSupport.temporaryDirectory()
    let work = try TestSupport.temporaryDirectory()
    let destination = try TestSupport.temporaryDirectory()
    defer {
      for url in [root, work, destination] { try? FileManager.default.removeItem(at: url) }
    }

    let session = try StorageCoordinator(
      preferences: InMemoryPreferencesStore(),
      clock: FixedTestClock(value: 1_700_000_000_000),
      ids: UuidV4IdGenerator()
    ).createNew(root.appendingPathComponent("store").path)
    defer { session.close() }

    let place = try TestSupport.createPlace(session, name: "Кладовая")
    _ = try TestSupport.createItem(session, name: "Фонарь", placeId: place.id, tags: ["Свет"])
    let itemsBefore = try session.items.list(GalleryQuery()).count

    let snapshot = try BackupSnapshotService(
      database: session.database,
      layout: session.layout,
      gate: session.writeGate,
      temporaryRoot: work
    ).makeSnapshot()
    defer { snapshot.discard() }

    let archiveURL = try BackupCodec.exportV1(
      snapshot: snapshot,
      to: destination,
      appVersion: "1.0",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let staged = try BackupArchiveReader(temporaryRoot: work).stage(archiveAt: archiveURL)
    let validated = try BackupFormatRegistry.validate(staged)
    defer { validated.discard() }

    #expect(validated.itemCount == 1)
    #expect(validated.counts["places"] == 1)
    #expect(validated.counts["tags"] == 1)
    #expect(validated.counts["item_tags"] == 1)
    #expect(validated.counts["settings"] == 3)
    #expect(validated.staged.filePaths.count == 4)
    #expect(try session.items.list(GalleryQuery()).count == itemsBefore)
  }
}
