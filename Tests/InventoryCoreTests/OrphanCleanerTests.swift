import Foundation
import InventoryCore
import Testing

@Suite("Очистка фото-сирот")
struct OrphanCleanerTests {
  @Test("Используемые фото вещей и мест сохраняются, сироты удаляются")
  func cleansOnlyOrphans() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let place = try session.places.create(
      PlaceCreate(name: "Дом", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let item = try session.items.create(
      ItemCreate(
        name: "Лампа",
        placeId: place.id,
        statusId: nil,
        tags: [],
        photo: TestSupport.makePhoto()
      )
    )

    try writeFile("photos/orphan.jpg", "orphan", session)
    try writeFile("thumbs/orphan.jpg", "orphan", session)
    try writeFile("_safety/keep.jpg", "keep", session)
    try writeFile("_tmp/keep.jpg", "keep", session)
    try FileManager.default.createDirectory(
      at: session.layout.photosURL.appendingPathComponent("nested", isDirectory: true),
      withIntermediateDirectories: true
    )
    try writeFile("photos/nested/keep.jpg", "keep", session)

    OrphanPhotoCleaner(
      database: session.database,
      photos: session.photos,
      logger: NullLogger()
    ).cleanup()

    #expect(fileExists(place.photoFile, session))
    #expect(fileExists(place.thumbFile, session))
    #expect(fileExists(item.item.photoFile, session))
    #expect(fileExists(item.item.thumbFile, session))
    #expect(!fileExists("photos/orphan.jpg", session))
    #expect(!fileExists("thumbs/orphan.jpg", session))
    #expect(fileExists("_safety/keep.jpg", session))
    #expect(fileExists("_tmp/keep.jpg", session))
    #expect(fileExists("photos/nested/keep.jpg", session))
  }

  private func writeFile(_ relative: String, _ contents: String, _ session: StorageSession) throws {
    let url = try session.layout.fileURL(forRelativePath: relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

  private func fileExists(_ relative: String?, _ session: StorageSession) -> Bool {
    guard let relative, let url = try? session.layout.fileURL(forRelativePath: relative) else {
      return false
    }
    return FileManager.default.fileExists(atPath: url.path)
  }
}
