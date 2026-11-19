import Foundation
import InventoryCore
import Testing

@Suite("Файлы фото и PhotoLifecycle")
struct PhotoStoreTests {
  @Test("store пишет обе копии, deleteFiles их удаляет")
  func storesAndDeletesPair() throws {
    let (store, layout, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let stored = try store.store(TestSupport.makePhoto())
    #expect(stored.photoFile.hasPrefix("photos/"))
    #expect(stored.thumbFile.hasPrefix("thumbs/"))

    let photoURL = try layout.fileURL(forRelativePath: stored.photoFile)
    let thumbURL = try layout.fileURL(forRelativePath: stored.thumbFile)
    #expect(FileManager.default.fileExists(atPath: photoURL.path))
    #expect(try Data(contentsOf: thumbURL) == TestSupport.makePhoto().thumbBytes)

    store.delete(stored)
    #expect(!FileManager.default.fileExists(atPath: photoURL.path))
    #expect(!FileManager.default.fileExists(atPath: thumbURL.path))
  }

  @Test("Ошибка SQL в replace удаляет новые файлы и сохраняет старое фото")
  func replaceRollsBackNewFiles() throws {
    let (store, layout, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let lifecycle = PhotoLifecycle(photos: store, logger: NullLogger())
    let previous = try store.store(TestSupport.makePhoto())

    var newStored: StoredPhoto?
    do {
      _ = try lifecycle.replace(prepared: TestSupport.makePhoto(), previous: previous) { stored in
        newStored = stored
        throw TestError.sqlFailed
      }
      Issue.record("Ожидалась ошибка SQL")
    } catch {
      #expect(error is TestError)
    }

    let newPhotoURL = try layout.fileURL(forRelativePath: newStored!.photoFile)
    let newThumbURL = try layout.fileURL(forRelativePath: newStored!.thumbFile)
    #expect(!FileManager.default.fileExists(atPath: newPhotoURL.path))
    #expect(!FileManager.default.fileExists(atPath: newThumbURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: try layout.fileURL(forRelativePath: previous.photoFile).path
      ))
  }

  @Test("После успешной замены старые файлы удаляются")
  func replaceDeletesPreviousAfterCommit() throws {
    let (store, layout, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let lifecycle = PhotoLifecycle(photos: store, logger: NullLogger())
    let previous = try store.store(TestSupport.makePhoto())
    let current = try lifecycle.replace(prepared: TestSupport.makePhoto(), previous: previous) {
      stored in
      stored!
    }

    #expect(
      !FileManager.default.fileExists(
        atPath: try layout.fileURL(forRelativePath: previous.photoFile).path
      ))
    #expect(
      FileManager.default.fileExists(
        atPath: try layout.fileURL(forRelativePath: current.photoFile).path
      ))
  }

  @Test("cleanupOrphans удаляет только неупомянутые фото")
  func cleansOrphans() throws {
    let (store, layout, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let kept = try store.store(TestSupport.makePhoto())
    let orphan = try store.store(TestSupport.makePhoto())

    store.cleanupOrphans(referencedRelativePaths: [kept.photoFile, kept.thumbFile])

    #expect(
      FileManager.default.fileExists(
        atPath: try layout.fileURL(forRelativePath: kept.photoFile).path
      ))
    #expect(
      !FileManager.default.fileExists(
        atPath: try layout.fileURL(forRelativePath: orphan.photoFile).path
      ))
    #expect(
      !FileManager.default.fileExists(
        atPath: try layout.fileURL(forRelativePath: orphan.thumbFile).path
      ))
  }

  @Test("Сбой записи превью удаляет уже записанное фото")
  func removesPhotoWhenThumbFails() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = StoreLayout(rootURL: root)
    try layout.createDirectories()
    // Каталог на месте будущего файла превью заставляет запись не удаться
    // уже после успешной записи основного фото.
    try FileManager.default.createDirectory(
      at: layout.thumbsURL.appendingPathComponent("thumbfail-1.jpg"),
      withIntermediateDirectories: true
    )

    let store = FilePhotoStore(
      layout: layout,
      ids: SequentialTestIds(prefix: "thumbfail"),
      logger: NullLogger()
    )
    #expect(throws: AppException.self) {
      _ = try store.store(TestSupport.makePhoto())
    }

    let remaining = try FileManager.default.contentsOfDirectory(
      at: layout.photosURL,
      includingPropertiesForKeys: nil
    )
    #expect(remaining.isEmpty)
  }

  @Test("Относительный путь не может выйти за пределы корня")
  func rejectsEscapingPath() throws {
    let (store, _, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: AppException.self) {
      _ = try store.fileURL(for: "../inventory.db")
    }
    #expect(throws: AppException.self) {
      _ = try store.fileURL(for: "/tmp/photo.jpg")
    }
  }

  private func makeStore() throws -> (FilePhotoStore, StoreLayout, URL) {
    let root = try TestSupport.temporaryDirectory()
    let layout = StoreLayout(rootURL: root)
    try layout.createDirectories()
    let store = FilePhotoStore(
      layout: layout,
      ids: UuidV4IdGenerator(),
      logger: NullLogger()
    )
    return (store, layout, root)
  }

  private enum TestError: Error {
    case sqlFailed
  }
}
