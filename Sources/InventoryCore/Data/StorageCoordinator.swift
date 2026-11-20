import Foundation
import GRDB

/// Открытая сессия хранилища: владеет соединением, блокировкой и сервисами.
public final class StorageSession: @unchecked Sendable {
  public let layout: StoreLayout
  public let database: InventoryDatabase
  public let logger: any AppLogger
  public let photos: any PhotoStore
  public let mutations: MutationBus
  public let places: any PlaceService
  public let items: any ItemService
  public let tags: any TagService
  public let statuses: any StatusService

  private let lock: StorageLock
  private let closeLock = NSLock()
  private var closed = false

  init(
    layout: StoreLayout,
    database: InventoryDatabase,
    lock: StorageLock,
    logger: any AppLogger,
    photos: any PhotoStore,
    mutations: MutationBus,
    places: any PlaceService,
    items: any ItemService,
    tags: any TagService,
    statuses: any StatusService
  ) {
    self.layout = layout
    self.database = database
    self.lock = lock
    self.logger = logger
    self.photos = photos
    self.mutations = mutations
    self.places = places
    self.items = items
    self.tags = tags
    self.statuses = statuses
  }

  public func close() {
    closeLock.lock()
    if closed {
      closeLock.unlock()
      return
    }
    closed = true
    closeLock.unlock()

    mutations.close()
    database.close()
    lock.release()
  }
}

/// Различает первый запуск, открытие существующей БД и недоступную папку.
public final class StorageCoordinator: @unchecked Sendable {
  private let preferences: any PreferencesStore
  private let bootstrapLogger: any AppLogger
  private let clock: any Clock
  private let ids: any IdGenerator
  private let fileManager: FileManager
  private let targetVersion: Int
  private let makeMigrator: () -> DatabaseMigrator
  private let loggerFactory: ((StoreLayout) -> any AppLogger)?
  private let cleanupOrphansOnOpen: Bool

  public init(
    preferences: any PreferencesStore,
    logger: any AppLogger = NullLogger(),
    clock: any Clock = SystemClock(),
    ids: any IdGenerator = UuidV4IdGenerator(),
    fileManager: FileManager = .default,
    targetVersion: Int = Schema.version,
    makeMigrator: @escaping () -> DatabaseMigrator = Schema.makeMigrator,
    loggerFactory: ((StoreLayout) -> any AppLogger)? = nil,
    cleanupOrphansOnOpen: Bool = true
  ) {
    self.preferences = preferences
    self.bootstrapLogger = logger
    self.clock = clock
    self.ids = ids
    self.fileManager = fileManager
    self.targetVersion = targetVersion
    self.makeMigrator = makeMigrator
    self.loggerFactory = loggerFactory
    self.cleanupOrphansOnOpen = cleanupOrphansOnOpen
  }

  public func openOrCreateDefault() throws -> StorageSession {
    if let stored = preferences.string(forKey: PreferenceKeys.activeStorePath), !stored.isEmpty {
      return try openExisting(stored)
    }
    let session = try createNew(DefaultStoreLocation.url(fileManager: fileManager).path)
    preferences.setString(session.layout.rootPath, forKey: PreferenceKeys.activeStorePath)
    return session
  }

  public func createNew(_ rootPath: String) throws -> StorageSession {
    let root = URL(fileURLWithPath: rootPath)
    let layout = StoreLayout(rootURL: root)

    if fileManager.fileExists(atPath: layout.databasePath) {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(layout.rootPath)],
        debugMessage: "database already exists; refusing to create a new store"
      )
    }

    do {
      try layout.createDirectories(fileManager: fileManager)
    } catch {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(layout.rootPath)],
        debugMessage: "cannot create store directories: \(error)"
      )
    }

    let logger = loggerFactory?(layout) ?? bootstrapLogger
    let lock = try StorageLock.acquire(layout: layout, fileManager: fileManager)

    do {
      if fileManager.fileExists(atPath: layout.databasePath) {
        throw AppException(
          .storageUnavailable,
          params: ["path": .string(layout.rootPath)],
          debugMessage: "database appeared while opening the store"
        )
      }

      let migrator = MigrationCoordinator(
        targetVersion: targetVersion,
        makeMigrator: makeMigrator,
        logger: logger,
        fileManager: fileManager
      )
      try migrator.migrateIfNeeded(layout: layout, createBackup: false)

      let database = try openDatabase(layout: layout)
      do {
        try database.write { db in
          try SeedData.applyIfNeeded(db, clock: clock, ids: ids)
        }
      } catch {
        database.close()
        try? removeDatabaseFiles(layout: layout)
        throw AppException(
          .storageUnavailable,
          params: ["path": .string(layout.rootPath)],
          debugMessage: "cannot seed a new store: \(error)"
        )
      }

      logger.info("store created", data: ["path": layout.rootPath])
      preferences.setString(layout.rootPath, forKey: PreferenceKeys.activeStorePath)
      return makeSession(layout: layout, database: database, lock: lock, logger: logger)
    } catch {
      lock.release()
      throw error
    }
  }

  public func openExisting(_ rootPath: String) throws -> StorageSession {
    let layout = StoreLayout(rootURL: URL(fileURLWithPath: rootPath))

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: layout.rootPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(layout.rootPath), "reason": .string("missing")]
      )
    }
    guard fileManager.fileExists(atPath: layout.databasePath) else {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(layout.rootPath), "reason": .string("missing-database")]
      )
    }

    let logger = loggerFactory?(layout) ?? bootstrapLogger
    let lock = try StorageLock.acquire(layout: layout, fileManager: fileManager)

    do {
      let version = try integrityCheck(layout: layout)
      if version > targetVersion {
        throw AppException(
          .storageNewerSchema,
          params: ["found": .int(version), "supported": .int(targetVersion)]
        )
      }
      if version < targetVersion {
        let migrator = MigrationCoordinator(
          targetVersion: targetVersion,
          makeMigrator: makeMigrator,
          logger: logger,
          fileManager: fileManager
        )
        try migrator.migrateIfNeeded(layout: layout, createBackup: true)
      }

      let database = try openDatabase(layout: layout)
      logger.info("store opened", data: ["path": layout.rootPath])
      preferences.setString(layout.rootPath, forKey: PreferenceKeys.activeStorePath)
      return makeSession(layout: layout, database: database, lock: lock, logger: logger)
    } catch {
      lock.release()
      throw error
    }
  }

  // MARK: - Внутренние шаги

  private func openDatabase(layout: StoreLayout) throws -> InventoryDatabase {
    do {
      return try InventoryDatabase(path: layout.databasePath)
    } catch {
      throw AppException(
        .storageCorrupt,
        params: ["path": .string(layout.databasePath)],
        debugMessage: "cannot open database: \(error)"
      )
    }
  }

  private func integrityCheck(layout: StoreLayout) throws -> Int {
    let queue: DatabaseQueue
    do {
      queue = try DatabaseQueue(
        path: layout.databasePath,
        configuration: InventoryDatabase.makeConfiguration()
      )
    } catch {
      throw AppException(
        .storageCorrupt,
        params: ["path": .string(layout.databasePath)],
        debugMessage: "cannot open database for integrity check: \(error)"
      )
    }
    defer { try? queue.close() }

    do {
      let result = try queue.read { database in
        try String.fetchOne(database, sql: "PRAGMA integrity_check")
      }
      guard result == "ok" else {
        throw AppException(
          .storageCorrupt,
          params: ["path": .string(layout.databasePath)],
          debugMessage: "integrity_check returned: \(result ?? "no result")"
        )
      }
      return try queue.read { database in
        try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
      }
    } catch let error as AppException {
      throw error
    } catch {
      throw AppException(
        .storageCorrupt,
        params: ["path": .string(layout.databasePath)],
        debugMessage: "integrity check failed: \(error)"
      )
    }
  }

  private func makeSession(
    layout: StoreLayout,
    database: InventoryDatabase,
    lock: StorageLock,
    logger: any AppLogger
  ) -> StorageSession {
    let photos = FilePhotoStore(layout: layout, ids: ids, logger: logger, fileManager: fileManager)
    let mutations = MutationBus()
    let lifecycle = PhotoLifecycle(photos: photos, logger: logger)
    let places = PlaceServiceImpl(
      database: database,
      photos: lifecycle,
      clock: clock,
      ids: ids,
      mutations: mutations
    )
    let tags = TagServiceImpl(database: database, ids: ids, mutations: mutations)
    let statuses = StatusServiceImpl(database: database, mutations: mutations)
    let items = ItemServiceImpl(
      database: database,
      photos: lifecycle,
      clock: clock,
      ids: ids,
      mutations: mutations
    )

    if cleanupOrphansOnOpen {
      OrphanPhotoCleaner(database: database, photos: photos, logger: logger).cleanup()
    }

    return StorageSession(
      layout: layout,
      database: database,
      lock: lock,
      logger: logger,
      photos: photos,
      mutations: mutations,
      places: places,
      items: items,
      tags: tags,
      statuses: statuses
    )
  }

  private func removeDatabaseFiles(layout: StoreLayout) throws {
    for url in [
      layout.databaseURL,
      URL(fileURLWithPath: layout.databasePath + "-wal"),
      URL(fileURLWithPath: layout.databasePath + "-shm"),
      URL(fileURLWithPath: layout.databasePath + "-journal"),
    ] where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }
}
