import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Места: иерархия, проверки и файлы")
struct PlaceTests {
  @Test("Создание, вложенный путь и естественная сортировка")
  func createsHierarchyAndSortsNaturally() throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    let place = session.places
    let home = try place.create(
      PlaceCreate(
        name: "  Дом  ", description: "Основное", parentId: nil, photo: TestSupport.makePhoto())
    )
    #expect(home.name == "Дом")
    #expect(home.parentId == nil)
    #expect(home.photoFile != nil)

    let shelf2 = try place.create(
      PlaceCreate(
        name: "Полка 2", description: "", parentId: home.id, photo: TestSupport.makePhoto())
    )
    let shelf10 = try place.create(
      PlaceCreate(
        name: "Полка 10", description: "", parentId: home.id, photo: TestSupport.makePhoto())
    )
    let box = try place.create(
      PlaceCreate(
        name: "Коробка", description: "", parentId: shelf2.id, photo: TestSupport.makePhoto())
    )

    let children = try place.children(of: home.id)
    #expect(children.map(\.id) == [shelf2.id, shelf10.id])

    let path = try place.path(to: box.id)
    #expect(path.segments.map(\.name) == ["Дом", "Полка 2", "Коробка"])
    #expect(path.display == "Дом / Полка 2 / Коробка")

    #expect(try place.descendants(of: home.id).map(\.id) == [box.id, shelf2.id, shelf10.id])
    #expect(try place.invalidParentIds(for: home.id) == [home.id, shelf2.id, shelf10.id, box.id])
  }

  @Test("Валидация имени и обязательного фото")
  func validatesNameAndPhoto() throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    #expect(throws: AppException.self) {
      try session.places.create(
        PlaceCreate(name: "   ", description: "", parentId: nil, photo: TestSupport.makePhoto()))
    }
    #expect(throws: AppException.self) {
      try session.places.create(
        PlaceCreate(
          name: String(repeating: "Я", count: 201), description: "", parentId: nil,
          photo: TestSupport.makePhoto())
      )
    }
    #expect(throws: AppException.self) {
      try session.places.create(
        PlaceCreate(name: "Без фото", description: "", parentId: nil, photo: nil))
    }
    #expect(try session.places.all().isEmpty)
  }

  @Test("Дубль имени у одного родителя требует подтверждения")
  func duplicateNeedsConfirmation() throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    let parent = try session.places.create(
      PlaceCreate(name: "Шкаф", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    _ = try session.places.create(
      PlaceCreate(
        name: "Полка", description: "", parentId: parent.id, photo: TestSupport.makePhoto())
    )

    do {
      _ = try session.places.create(
        PlaceCreate(
          name: "  полка ", description: "", parentId: parent.id, photo: TestSupport.makePhoto())
      )
      Issue.record("Ожидалась ошибка duplicateName")
    } catch let error as AppException {
      #expect(error.code == .duplicateName)
    }

    let duplicate = try session.places.create(
      PlaceCreate(
        name: "полка", description: "", parentId: parent.id, photo: TestSupport.makePhoto()),
      duplicateConfirmed: true
    )
    #expect(duplicate.name == "полка")
    #expect(try session.places.children(of: parent.id).count == 2)
  }

  @Test("Перемещение сохраняет поддерево и пересчитывает путь")
  func moveKeepsSubtree() throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    let a = try session.places.create(
      PlaceCreate(name: "A", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let b = try session.places.create(
      PlaceCreate(name: "B", description: "", parentId: a.id, photo: TestSupport.makePhoto())
    )
    let c = try session.places.create(
      PlaceCreate(name: "C", description: "", parentId: b.id, photo: TestSupport.makePhoto())
    )
    let x = try session.places.create(
      PlaceCreate(name: "X", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )

    let moved = try session.places.move(b.id, newParentId: x.id)
    #expect(moved.parentId == x.id)
    #expect(try session.places.get(c.id).parentId == b.id)
    #expect(try session.places.path(to: c.id).segments.map(\.name) == ["X", "B", "C"])

    _ = try session.places.move(c.id, newParentId: nil)
    #expect(try session.places.path(to: c.id).segments.map(\.name) == ["C"])
  }

  @Test("Циклы запрещены и через updateDetails, и через move")
  func rejectsCycles() throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    let a = try session.places.create(
      PlaceCreate(name: "A", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let b = try session.places.create(
      PlaceCreate(name: "B", description: "", parentId: a.id, photo: TestSupport.makePhoto())
    )
    let c = try session.places.create(
      PlaceCreate(name: "C", description: "", parentId: b.id, photo: TestSupport.makePhoto())
    )

    for invalidParent in [a.id, c.id] {
      do {
        _ = try session.places.move(a.id, newParentId: invalidParent)
        Issue.record("Ожидалась ошибка placeCycle")
      } catch let error as AppException {
        #expect(error.code == .placeCycle)
      }
    }

    do {
      _ = try session.places.updateDetails(
        PlaceDetailsUpdate(
          id: a.id,
          name: "A",
          description: "",
          parentId: b.id,
          newPhoto: nil
        )
      )
      Issue.record("Ожидалась ошибка placeCycle")
    } catch let error as AppException {
      #expect(error.code == .placeCycle)
    }

    #expect(try session.places.path(to: c.id).segments.map(\.name) == ["A", "B", "C"])
  }

  @Test("Удаляется только пустое место; фото удаляются после commit")
  func deletesOnlyEmptyPlaces() throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    let empty = try session.places.create(
      PlaceCreate(name: "Пустое", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let photoURL = try session.layout.fileURL(forRelativePath: empty.photoFile!)
    let thumbURL = try session.layout.fileURL(forRelativePath: empty.thumbFile!)
    #expect(FileManager.default.fileExists(atPath: photoURL.path))

    try session.places.deleteEmpty(empty.id)
    #expect(!FileManager.default.fileExists(atPath: photoURL.path))
    #expect(!FileManager.default.fileExists(atPath: thumbURL.path))

    let parent = try session.places.create(
      PlaceCreate(name: "Родитель", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let child = try session.places.create(
      PlaceCreate(
        name: "Ребёнок", description: "", parentId: parent.id, photo: TestSupport.makePhoto())
    )

    do {
      try session.places.deleteEmpty(parent.id)
      Issue.record("Ожидалась ошибка placeNotEmpty")
    } catch let error as AppException {
      #expect(error.code == .placeNotEmpty)
      #expect(error.int("childrenCount") == 1)
      #expect(error.int("itemsCount") == 0)
    }

    let statusId = try session.database.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'default_status_id'")!
    }
    try session.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO items (id, name, description, notes, quantity, place_id, status_id,
                             photo_file, thumb_file, created_at, updated_at)
          VALUES ('item', 'Вещь', '', '', 1, ?, ?, '', '', 1, 1)
          """,
        arguments: [child.id, statusId]
      )
    }

    do {
      try session.places.deleteEmpty(child.id)
      Issue.record("Ожидалась ошибка placeNotEmpty")
    } catch let error as AppException {
      #expect(error.code == .placeNotEmpty)
      #expect(error.int("childrenCount") == 0)
      #expect(error.int("itemsCount") == 1)
    }
  }

  @Test("Замена фото удаляет старую пару после записи в БД")
  func replacesPhotoFiles() throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    let place = try session.places.create(
      PlaceCreate(name: "Комната", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let oldPhoto = try session.layout.fileURL(forRelativePath: place.photoFile!)
    let oldThumb = try session.layout.fileURL(forRelativePath: place.thumbFile!)

    let updated = try session.places.updateDetails(
      PlaceDetailsUpdate(
        id: place.id,
        name: "Комната",
        description: "Новое описание",
        parentId: nil,
        newPhoto: TestSupport.makePhoto()
      )
    )

    #expect(updated.photoFile != place.photoFile)
    #expect(updated.description == "Новое описание")
    #expect(!FileManager.default.fileExists(atPath: oldPhoto.path))
    #expect(!FileManager.default.fileExists(atPath: oldThumb.path))
    #expect(
      FileManager.default.fileExists(
        atPath: try session.layout.fileURL(forRelativePath: updated.photoFile!).path
      ))

    let kept = try session.places.updateDetails(
      PlaceDetailsUpdate(
        id: place.id, name: "Комната 2", description: "", parentId: nil, newPhoto: nil)
    )
    #expect(kept.photoFile == updated.photoFile)
  }

  @Test("Изменения переживают переоткрытие хранилища")
  func persistsAcrossReopen() throws {
    let root = try TestSupport.temporaryDirectory()
    let coordinator = TestSupport.makeCoordinator()
    let first = try coordinator.createNew(root.path)
    let created = try first.places.create(
      PlaceCreate(
        name: "Кухня", description: "Посуда", parentId: nil, photo: TestSupport.makePhoto())
    )
    first.close()

    let second = try coordinator.openExisting(root.path)
    defer {
      second.close()
      try? FileManager.default.removeItem(at: root)
    }
    let loaded = try second.places.get(created.id)
    #expect(loaded.name == "Кухня")
    #expect(loaded.description == "Посуда")
    #expect(loaded.photoFile == created.photoFile)
  }

  @Test("События мест публикуются после commit")
  func publishesMutationEvents() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer { cleanup(session, root) }

    var iterator = session.places.changes.makeAsyncIterator()
    let created = try session.places.create(
      PlaceCreate(name: "Событие", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let event = await iterator.next()
    guard case .placesChanged(let ids, _, let kind) = event else {
      Issue.record("Ожидалось событие PlacesChanged")
      return
    }
    #expect(ids == Set([created.id]))
    #expect(kind == .created)
  }

  private func cleanup(_ session: StorageSession, _ root: URL) {
    session.close()
    try? FileManager.default.removeItem(at: root)
  }
}
