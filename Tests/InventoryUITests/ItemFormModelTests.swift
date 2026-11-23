import Foundation
import InventoryCore
import Testing

@testable import InventoryUI

@Suite("Форма вещи")
@MainActor
struct ItemFormModelTests {
  @Test("Новой вещи сразу подставляется фото-заглушка")
  func fillsDefaultPhoto() async throws {
    let items = FakeItemService()
    let images = FakeImageProcessor()
    let model = makeCreateModel(items: items, images: images)
    await model.loadReferences()

    #expect(model.hasPhoto)
    #expect(model.previewImage != nil)
    #expect(await images.callCount() == 1)

    model.name = "Лампа"
    model.quantity = 1
    #expect(model.canSave)

    await model.save()
    #expect(model.didSave)
    let input = try #require(items.createdInputs.first)
    #expect(input.photo != nil)
  }

  @Test("Создание передаёт поля, теги и выбранный статус")
  func createsWithFields() async throws {
    let items = FakeItemService()
    let statuses = FakeStatusService(statuses: [
      makeTestStatus(id: "status-1", name: "В наличии"),
      makeTestStatus(id: "status-2", name: "В ремонте"),
    ])
    let tags = FakeTagService(suggestions: [
      TagSuggestion(id: "tag-1", name: "Свет", itemCount: 3)
    ])
    let dialogs = FakeFileDialogs()
    dialogs.imageURL = try makeTemporaryFile()
    let model = makeCreateModel(items: items, statuses: statuses, tags: tags, dialogs: dialogs)
    await model.loadReferences()

    model.name = "  Настольная лампа "
    model.description = "Тёплый свет"
    model.notes = "На полке"
    model.quantity = 2
    model.placeId = "place-1"
    model.statusId = "status-2"
    model.tagInput = " Свет "

    await model.choosePhoto()
    #expect(model.hasPhoto)
    #expect(items.createdInputs.isEmpty)

    await model.save()
    #expect(model.didSave)
    let input = try #require(items.createdInputs.first)
    #expect(input.name == "Настольная лампа")
    #expect(input.description == "Тёплый свет")
    #expect(input.notes == "На полке")
    #expect(input.quantity == 2)
    #expect(input.placeId == "place-1")
    #expect(input.statusId == "status-2")
    #expect(input.tags == ["Свет"])
    #expect(input.photo != nil)
  }

  @Test("Редактирование показывает статус только для чтения")
  func editKeepsStatusReadOnly() async throws {
    let details = makeTestItemDetails(
      id: "item-1",
      name: "Лампа",
      placeId: "place-1",
      statusId: "status-2",
      status: makeTestStatus(id: "status-2", name: "В ремонте"),
      tagNames: ["Свет"]
    )
    let items = FakeItemService(initial: [details])
    let statuses = FakeStatusService(statuses: [
      makeTestStatus(id: "status-2", name: "В ремонте"),
      makeTestStatus(id: "status-3", name: "Архивный", archived: true),
    ])
    let model = ItemFormModel(
      mode: .edit(details),
      items: items,
      tags: FakeTagService(),
      statuses: statuses,
      places: FakePlaceService(initial: [makeTestPlace(id: "place-1", name: "Дом")]),
      images: FakeImageProcessor(),
      dialogs: FakeFileDialogs(),
      photos: FakePhotoStore()
    )
    await model.loadReferences()

    #expect(model.isEditing)
    #expect(model.readOnlyStatusName == "В ремонте")
    #expect(model.selectedTags == ["Свет"])
    #expect(!model.activeStatuses.contains { $0.isArchived })

    model.name = "Лампа настольная"
    model.quantity = 4
    model.tagInput = "Дом"
    model.addTagFromInput()
    await model.save()

    #expect(model.didSave)
    let input = try #require(items.updatedInputs.first)
    #expect(input.name == "Лампа настольная")
    #expect(input.quantity == 4)
    #expect(input.tags.contains("Дом"))
    let stored = try items.get("item-1")
    #expect(stored.item.statusId == "status-2")
  }

  @Test("Слишком длинный тег не добавляется")
  func rejectsLongTag() async throws {
    let model = makeCreateModel(items: FakeItemService())
    await model.loadReferences()
    model.tagInput = String(repeating: "я", count: TagKey.maxLength + 1)
    model.addTagFromInput()

    #expect(model.selectedTags.isEmpty)
    guard case .failure(let message)? = model.alert else {
      Issue.record("Ожидалась ошибка длины тега")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test("Повторный тег схлопывается без учёта регистра и ё")
  func deduplicatesTags() async throws {
    let model = makeCreateModel(items: FakeItemService())
    await model.loadReferences()

    model.tagInput = "Ёлка"
    model.addTagFromInput()
    model.tagInput = "елка"
    model.addTagFromInput()

    #expect(model.selectedTags == ["Ёлка"])
  }

  @Test("Выбор из автодополнения добавляет существующее написание")
  func addsSuggestion() async throws {
    let model = makeCreateModel(items: FakeItemService())
    await model.loadReferences()

    model.selectTagSuggestion(
      TagSuggestion(id: "tag-1", name: "Ёлочные игрушки", itemCount: 2)
    )
    #expect(model.selectedTags == ["Ёлочные игрушки"])
    #expect(model.tagInput.isEmpty)
  }

  private func makeCreateModel(
    items: FakeItemService,
    statuses: FakeStatusService = FakeStatusService(),
    tags: FakeTagService = FakeTagService(),
    dialogs: FakeFileDialogs = FakeFileDialogs(),
    images: FakeImageProcessor = FakeImageProcessor()
  ) -> ItemFormModel {
    ItemFormModel(
      mode: .create(placeId: "place-1"),
      items: items,
      tags: tags,
      statuses: statuses,
      places: FakePlaceService(initial: [makeTestPlace(id: "place-1", name: "Дом")]),
      images: images,
      dialogs: dialogs,
      photos: FakePhotoStore()
    )
  }
}
