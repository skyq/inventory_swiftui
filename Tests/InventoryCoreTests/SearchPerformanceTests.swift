import Foundation
import InventoryCore
import Testing

@Suite("Поиск: производительность", .serialized)
struct SearchPerformanceTests {
  private static let itemCount = 500

  @Test("500 вещей: поиск с фильтрами укладывается в 100 мс")
  func searchWithFiltersUnder100ms() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    var places: [Place] = []
    for index in 0..<10 {
      places.append(try TestSupport.createPlace(session, name: "Место \(index)"))
    }

    let names = ["Куртка", "Лампа", "Дрель", "Стол", "Книга"]
    let tags = ["Одежда", "Свет", "Инструмент", "Мебель", "Бумага"]
    var itemIds: [String] = []
    for index in 0..<Self.itemCount {
      let kind = index % names.count
      let created = try TestSupport.createItem(
        session,
        name: "\(names[kind]) \(index)",
        placeId: places[index % places.count].id,
        tags: [tags[kind]]
      )
      itemIds.append(created.item.id)
    }

    let rebuildStart = ContinuousClock.now
    await session.search.rebuild()
    let rebuildTime = ContinuousClock.now - rebuildStart
    print("PERF cold rebuild \(Self.itemCount) items: \(rebuildTime)")
    #expect(rebuildTime < .seconds(10))

    // Запросы: точное совпадение, словоформа, опечатка, префикс, промах.
    let queries = ["куртка", "куртку", "курка", "дре", "электроинструмент"]
    var worst = Duration.zero
    for query in queries {
      for _ in 0..<5 {
        let start = ContinuousClock.now
        let hits = session.search.search(query)
        let filtered = GalleryQuery(
          place: .all,
          statusIds: [],
          tagIds: [],
          sort: .createdAt,
          direction: .desc,
          searchItemIds: Set(hits.map(\.itemId))
        )
        _ = try session.items.list(filtered)
        let elapsed = ContinuousClock.now - start
        if elapsed > worst {
          worst = elapsed
        }
        #expect(
          elapsed < .milliseconds(100),
          "Запрос «\(query)» занял \(elapsed), лимит 100 мс"
        )
      }
    }
    print("PERF worst search+filters \(Self.itemCount) items: \(worst)")
  }

  @Test("Изменение вещи обновляет индекс без перезапуска")
  func liveUpdateWithoutRestart() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let target = try TestSupport.createItem(session, name: "Куртка 0")
    for index in 1..<Self.itemCount {
      _ = try TestSupport.createItem(session, name: "Лампа \(index)")
    }
    await session.search.rebuild()

    let start = ContinuousClock.now
    _ = try session.items.updateDetails(
      ItemDetailsUpdate(
        id: target.item.id,
        name: "Перфоратор",
        description: "",
        notes: "",
        quantity: 1,
        placeId: nil,
        tags: [],
        newPhoto: nil
      )
    )
    await session.search.waitForIdle()
    let elapsed = ContinuousClock.now - start
    print("PERF live index update \(Self.itemCount) items: \(elapsed)")

    #expect(session.search.search("перфоратор").map(\.itemId) == [target.item.id])
    #expect(session.search.search("куртка").isEmpty)
    #expect(elapsed < .seconds(2))
  }
}
