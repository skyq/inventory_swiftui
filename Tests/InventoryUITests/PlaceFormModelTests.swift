import Foundation
import InventoryCore
import Testing

@testable import InventoryUI

@Suite("Форма места")
@MainActor
struct PlaceFormModelTests {
  @Test("Без фото форма не сохраняется")
  func requiresPhoto() async {
    let service = FakePlaceService()
    let model = makeModel(mode: .create(parentId: nil), service: service)
    model.name = "Дом"

    #expect(!model.canSave)
    await model.save()
    #expect(service.createdInputs.isEmpty)

    guard case .failure(let message)? = model.alert else {
      Issue.record("Ожидалось сообщение об обязательном фото")
      return
    }
    #expect(message == L10n.string("places.photoRequired"))
  }

  @Test("Новому месту сразу подставляется фото-заглушка")
  func fillsDefaultPhoto() async {
    let images = FakeImageProcessor()
    let model = makeModel(mode: .create(parentId: nil), service: FakePlaceService(), images: images)
    await model.loadReferences()

    #expect(model.hasPhoto)
    #expect(model.previewImage != nil)
    #expect(await images.callCount() == 1)

    model.name = "Кладовая"
    #expect(model.canSave)
  }

  @Test("Выбор фото включает сохранение и передаёт PreparedPhoto в сервис")
  func choosePhotoEnablesSave() async throws {
    let url = try makeTemporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }

    let dialogs = FakeFileDialogs()
    dialogs.imageURL = url
    let images = FakeImageProcessor()
    let service = FakePlaceService()
    let model = makeModel(
      mode: .create(parentId: nil), service: service, images: images, dialogs: dialogs)
    model.name = "Дом"

    await model.choosePhoto()
    #expect(model.hasPhoto)
    #expect(model.canSave)

    await model.save()
    #expect(model.didSave)
    #expect(service.createdInputs.count == 1)
    #expect(service.createdInputs.first?.0.photo != nil)
    let calls = await images.calls
    #expect(calls == 1)
  }

  @Test("Отмена диалога оставляет текущее фото и не вызывает обработку")
  func cancelKeepsCurrentPhoto() async {
    let dialogs = FakeFileDialogs()
    let images = FakeImageProcessor()
    let service = FakePlaceService(initial: [makeTestPlace(id: "a", name: "Дом")])
    let model = makeModel(
      mode: .edit(makeTestPlace(id: "a", name: "Дом")),
      service: service,
      images: images,
      dialogs: dialogs
    )
    await model.loadReferences()
    #expect(model.hasPhoto)

    await model.choosePhoto()
    #expect(dialogs.imageRequestCount == 1)
    #expect(model.hasPhoto)
    let calls = await images.calls
    #expect(calls == 0)
    #expect(model.alert == nil)
  }

  @Test("Дубль требует подтверждения и повтор сохраняет с флагом")
  func duplicateNeedsConfirmation() async throws {
    let url = try makeTemporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }

    let dialogs = FakeFileDialogs()
    dialogs.imageURL = url
    let service = FakePlaceService()
    service.createError = AppException(.duplicateName, params: ["name": .string("Полка")])
    service.duplicateUntilConfirmed = true
    let model = makeModel(mode: .create(parentId: nil), service: service, dialogs: dialogs)
    model.name = "Полка"
    await model.choosePhoto()

    await model.save()
    #expect(!model.didSave)
    guard case .duplicate(let name)? = model.alert else {
      Issue.record("Ожидалось предупреждение о дубле")
      return
    }
    #expect(name == "Полка")

    await model.save(duplicateConfirmed: true)
    #expect(model.didSave)
    #expect(service.createdInputs.map { $0.1 } == [false, true])
  }

  @Test("Себя и потомков нельзя выбрать родителем")
  func excludesSelfAndDescendants() async {
    let a = makeTestPlace(id: "a", name: "Дом")
    let b = makeTestPlace(id: "b", parentId: "a", name: "Комната")
    let c = makeTestPlace(id: "c", name: "Гараж")
    let service = FakePlaceService(initial: [a, b, c])
    let model = makeModel(mode: .edit(a), service: service)

    await model.loadReferences()
    #expect(model.parentChoices.map(\.id) == ["c"])
    #expect(model.parentId == nil)
  }

  @Test("Слишком длинное имя не сохраняется")
  func rejectsLongName() async throws {
    let url = try makeTemporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }

    let dialogs = FakeFileDialogs()
    dialogs.imageURL = url
    let service = FakePlaceService()
    let model = makeModel(mode: .create(parentId: nil), service: service, dialogs: dialogs)
    model.name = String(repeating: "Я", count: NameKey.maxLength + 1)
    await model.choosePhoto()

    #expect(!model.canSave)
    await model.save()
    #expect(service.createdInputs.isEmpty)
    #expect(model.alert != nil)
  }

  private func makeModel(
    mode: PlaceFormMode,
    service: FakePlaceService,
    images: FakeImageProcessor = FakeImageProcessor(),
    dialogs: FakeFileDialogs = FakeFileDialogs()
  ) -> PlaceFormModel {
    PlaceFormModel(
      mode: mode,
      places: service,
      images: images,
      dialogs: dialogs,
      photos: FakePhotoStore()
    )
  }
}
