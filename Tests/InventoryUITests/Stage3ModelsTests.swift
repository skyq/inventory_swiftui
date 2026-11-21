import Foundation
import InventoryCore
import Testing

@testable import InventoryUI

@MainActor
@Suite("Модели этапа 3: действия и справочники")
struct Stage3ModelsTests {
  // MARK: - Смена статуса

  @Test("Диалог статуса исключает текущий и отправляет команду")
  func changeStatusModel() async {
    let current = makeTestStatus(id: "s1", name: "В наличии")
    let other = makeTestStatus(id: "s2", name: "В ремонте")
    let details = makeTestItemDetails(
      id: "item-1", name: "Куртка", statusId: "s1", status: current)
    let actions = FakeItemActions(details: details)
    let model = ChangeStatusModel(
      item: details,
      actions: actions,
      statuses: FakeStatusService(statuses: [current, other])
    )

    await model.load()
    #expect(model.statuses.map(\.id) == ["s2"])
    #expect(model.statusId == "s2")
    #expect(model.canSave)

    model.comment = "порвалась"
    await model.save()
    #expect(model.didSave)
    #expect(actions.changeStatusCommands.count == 1)
    #expect(actions.changeStatusCommands.first?.toStatusId == "s2")
    #expect(actions.changeStatusCommands.first?.comment == "порвалась")
  }

  @Test("Ошибка смены статуса не закрывает диалог")
  func changeStatusFailure() async {
    let current = makeTestStatus(id: "s1", name: "В наличии")
    let details = makeTestItemDetails(
      id: "item-1", name: "Куртка", statusId: "s1", status: current)
    let actions = FakeItemActions(details: details)
    actions.error = AppException(.statusArchived, params: ["statusId": .string("s2")])
    let model = ChangeStatusModel(
      item: details,
      actions: actions,
      statuses: FakeStatusService(
        statuses: [current, makeTestStatus(id: "s2", name: "В ремонте")])
    )

    await model.load()
    await model.save()
    #expect(!model.didSave)
    #expect(model.alertMessage != nil)
  }

  // MARK: - Передача

  @Test("Передача по умолчанию: transfer_status, оба флажка включены")
  func giveDefaults() async {
    let current = makeTestStatus(id: "s1", name: "В наличии")
    let transfer = makeTestStatus(id: "s2", name: "Одолжил")
    let person = Person(
      id: "p1", name: "Анна", phone: "", notes: "", isArchived: false,
      createdAt: 1, updatedAt: 1)
    let people = FakePeopleService(initial: [person])
    let actions = FakeItemActions()
    let model = GiveModel(
      item: makeTestItemDetails(id: "item-1", name: "Куртка", statusId: "s1", status: current),
      actions: actions,
      people: people,
      statuses: FakeStatusService(statuses: [current, transfer]),
      settings: FakeStatusSettingsService(
        value: StatusSettings(
          defaultStatusId: "s1", transferStatusId: "s2", returnStatusId: "s1"))
    )

    await model.load()
    #expect(model.selectedPersonId == "p1")
    #expect(model.changeStatus)
    #expect(model.clearPlace)
    #expect(model.statusId == "s2")

    await model.save()
    let command = actions.giveCommands.first
    #expect(command?.person == .existing(id: "p1"))
    #expect(command?.changeStatus == true)
    #expect(command?.clearPlace == true)
    #expect(command?.statusId == "s2")
  }

  @Test("Новый человек уходит одной командой до подтверждения дубля")
  func giveNewPersonAndDuplicate() async {
    let current = makeTestStatus(id: "s1", name: "В наличии")
    let people = FakePeopleService()
    people.requiresDuplicateConfirmation = true
    let actions = FakeItemActions()
    let model = GiveModel(
      item: makeTestItemDetails(id: "item-1", name: "Куртка", statusId: "s1", status: current),
      actions: actions,
      people: people,
      statuses: FakeStatusService(statuses: [current]),
      settings: FakeStatusSettingsService(
        value: StatusSettings(
          defaultStatusId: "s1", transferStatusId: "s1", returnStatusId: "s1"))
    )

    await model.load()
    model.isCreatingPerson = true
    model.newPersonName = "Новый"
    model.newPersonPhone = "123"
    model.newPersonNotes = "из формы"
    model.changeStatus = false
    model.clearPlace = false
    #expect(model.canSave)

    actions.error = AppException(.personNameDuplicate, params: ["name": .string("Новый")])
    await model.save()
    #expect(model.pendingDuplicate)
    #expect(actions.giveCommands.isEmpty)

    actions.error = nil
    await model.saveDuplicate()
    #expect(model.didSave)
    #expect(
      actions.giveCommands.first?.person
        == .new(name: "Новый", phone: "123", notes: "из формы", duplicateConfirmed: true))
  }

  @Test("Без человека и без статуса передать нельзя")
  func giveValidation() async {
    let current = makeTestStatus(id: "s1", name: "В наличии")
    let model = GiveModel(
      item: makeTestItemDetails(id: "item-1", name: "Куртка", statusId: "s1", status: current),
      actions: FakeItemActions(),
      people: FakePeopleService(),
      statuses: FakeStatusService(statuses: [current]),
      settings: FakeStatusSettingsService(
        value: StatusSettings(
          defaultStatusId: "s1", transferStatusId: "s1", returnStatusId: "s1"))
    )

    await model.load()
    model.isCreatingPerson = false
    model.selectedPersonId = nil
    #expect(!model.canSave)
    model.isCreatingPerson = true
    model.newPersonName = "  "
    #expect(!model.canSave)
    model.newPersonName = "Анна"
    #expect(model.canSave)
  }

  // MARK: - Возврат

  @Test("Возврат предлагает последнего получателя, return_status и «оставить место»")
  func returnDefaults() async {
    let current = makeTestStatus(id: "s1", name: "В наличии")
    let transfer = makeTestStatus(id: "s2", name: "Одолжил")
    let returned = makeTestStatus(id: "s3", name: "В наличии снова")
    let participant = Person(
      id: "p1", name: "Анна", phone: "", notes: "", isArchived: true,
      createdAt: 1, updatedAt: 1)
    let stranger = Person(
      id: "p2", name: "Чужой", phone: "", notes: "", isArchived: true,
      createdAt: 1, updatedAt: 1)
    let active = Person(
      id: "p3", name: "Борис", phone: "", notes: "", isArchived: false,
      createdAt: 1, updatedAt: 1)
    let people = FakePeopleService(initial: [participant, stranger, active])
    people.setLastGiven(itemId: "item-1", personId: "p1")

    let history = FakeHistoryReadService()
    history.itemEntries = [
      ItemHistoryEntry(
        id: "t1", kind: .give, occurredAt: 1_700_000_000_000, comment: "",
        personId: "p1", personName: "Анна")
    ]

    let details = makeTestItemDetails(
      id: "item-1", name: "Куртка", statusId: "s1", status: current)
    let actions = FakeItemActions(details: details)
    let model = ReturnModel(
      item: details,
      actions: actions,
      people: people,
      statuses: FakeStatusService(statuses: [current, transfer, returned]),
      settings: FakeStatusSettingsService(
        value: StatusSettings(
          defaultStatusId: "s1", transferStatusId: "s2", returnStatusId: "s3")),
      places: FakePlaceService(),
      history: history
    )

    await model.load()
    // Архивный участник истории допустим, архивный посторонний — нет.
    #expect(Set(model.people.map(\.id)) == ["p1", "p3"])
    #expect(model.selectedPersonId == "p1")
    #expect(model.statusId == "s3")
    #expect(model.placeMode == .keep)
    #expect(model.canSave)

    model.comment = "вернула"
    await model.save()
    let command = actions.returnCommands.first
    #expect(command?.personId == "p1")
    #expect(command?.statusId == "s3")
    #expect(command?.place == .keep)
  }

  @Test("Возврат с новым местом требует выбора места")
  func returnPlaceValidation() async {
    let current = makeTestStatus(id: "s1", name: "В наличии")
    let person = Person(
      id: "p1", name: "Анна", phone: "", notes: "", isArchived: false,
      createdAt: 1, updatedAt: 1)
    let places = FakePlaceService(initial: [makeTestPlace(id: "place-1", name: "Шкаф")])
    let model = ReturnModel(
      item: makeTestItemDetails(id: "item-1", name: "Куртка", statusId: "s1", status: current),
      actions: FakeItemActions(),
      people: FakePeopleService(initial: [person]),
      statuses: FakeStatusService(statuses: [current]),
      settings: FakeStatusSettingsService(
        value: StatusSettings(
          defaultStatusId: "s1", transferStatusId: "s1", returnStatusId: "s1")),
      places: places,
      history: FakeHistoryReadService()
    )

    await model.load()
    model.placeMode = .place
    model.placeId = nil
    #expect(!model.canSave)
    model.placeId = "place-1"
    #expect(model.canSave)
  }

  // MARK: - Люди

  @Test("Справочник людей: архив, история и выбор")
  func peopleModel() async {
    let active = Person(
      id: "p1", name: "Анна", phone: "123", notes: "", isArchived: false,
      createdAt: 1, updatedAt: 1)
    let archived = Person(
      id: "p2", name: "Борис", phone: "", notes: "", isArchived: true,
      createdAt: 1, updatedAt: 1)
    let people = FakePeopleService(initial: [active, archived])
    let history = FakeHistoryReadService()
    history.personEntries = [
      PersonHistoryEntry(
        id: "t1", kind: .give, occurredAt: 1, comment: "", itemId: "item-1",
        itemName: "Куртка")
    ]
    let model = PeopleModel(
      people: people, history: history, items: FakeItemService())

    await model.start()
    #expect(model.people.map(\.id) == ["p1"])
    await model.select("p1")
    #expect(model.selectedPerson?.id == "p1")
    #expect(model.selectedHistory.first?.itemName == "Куртка")

    await model.archiveSelected()
    #expect(model.people.isEmpty)

    model.includeArchived = true
    await model.reload()
    #expect(Set(model.people.map(\.id)) == ["p1", "p2"])
    await model.select("p1")
    #expect(model.selectedPerson?.isArchived == true)
  }

  // MARK: - Статусы

  @Test("Статусы: архивные, использование в настройках, сохранение")
  func statusesModel() async {
    let active = makeTestStatus(id: "s1", name: "В наличии")
    let transfer = makeTestStatus(id: "s2", name: "Одолжил")
    let archived = makeTestStatus(id: "s3", name: "Старый", archived: true)
    let settings = FakeStatusSettingsService(
      value: StatusSettings(
        defaultStatusId: "s1", transferStatusId: "s1", returnStatusId: "s2"))
    let model = StatusesModel(
      statuses: FakeStatusService(statuses: [active, transfer, archived]),
      settings: settings
    )

    await model.start()
    #expect(model.activeStatuses.map(\.id) == ["s1", "s2"])
    #expect(model.archivedStatuses.map(\.id) == ["s3"])
    #expect(model.settingsSlots(using: "s1") == [.defaultStatus, .transferStatus])
    #expect(model.replacementCandidates(excluding: "s1").map(\.id) == ["s2"])

    let saved = await model.updateSettings(
      defaultStatusId: "s2",
      transferStatusId: "s2",
      returnStatusId: "s2"
    )
    #expect(saved)
    #expect(
      settings.value
        == StatusSettings(
          defaultStatusId: "s2", transferStatusId: "s2", returnStatusId: "s2"))
  }

  @Test("Ошибка архивации показывается пользователю")
  func statusesArchiveError() async {
    let active = makeTestStatus(id: "s1", name: "В наличии")
    let settings = FakeStatusSettingsService(
      value: StatusSettings(
        defaultStatusId: "s1", transferStatusId: "s1", returnStatusId: "s1"))
    let statuses = FakeStatusService(statuses: [active])
    let model = StatusesModel(statuses: statuses, settings: settings)
    await model.start()
    statuses.archiveError = AppException(
      .statusInUse, params: ["statusId": .string("s1")])
    #expect(await model.archive("s1", replacementId: nil) == false)
    #expect(model.alertMessage != nil)
  }

  // MARK: - Теги

  @Test("Теги сортируются по имени и количеству")
  func tagsSorting() async {
    let model = TagsModel(
      tags: FakeTagService(suggestions: [
        TagSuggestion(id: "t1", name: "Дом", itemCount: 1),
        TagSuggestion(id: "t2", name: "Свет", itemCount: 5),
        TagSuggestion(id: "t3", name: "Ёлка", itemCount: 2),
      ]),
      items: FakeItemService()
    )

    await model.start()
    model.sortMode = .name
    #expect(model.sortedTags.map(\.name) == ["Дом", "Свет", "Ёлка"])
    model.sortMode = .count
    #expect(model.sortedTags.map(\.name) == ["Свет", "Ёлка", "Дом"])
  }

  @Test("Конфликт переименования превращается в предложение объединения")
  func tagsRenameConflict() async {
    let tags = FakeTagService(suggestions: [
      TagSuggestion(id: "t1", name: "Ёлка", itemCount: 1),
      TagSuggestion(id: "t2", name: "Свет", itemCount: 2),
    ])
    let model = TagsModel(tags: tags, items: FakeItemService())
    await model.start()

    tags.renameError = AppException(
      .tagNameConflict,
      params: ["tagId": .string("t2"), "name": .string("Свет")]
    )
    let renamed = await model.rename("t1", to: "свет")
    #expect(!renamed)
    let suggestion = model.renameSuggestion
    #expect(suggestion?.sourceId == "t1")
    #expect(suggestion?.targetId == "t2")
    #expect(suggestion?.resultName == "свет")
  }
}
