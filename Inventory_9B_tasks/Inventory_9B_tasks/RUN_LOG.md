# Журнал выполнения

Статусы обновлены по фактическому коду и прогонам 20 ноября 2026. Подтверждение этапа хранится отдельной записью и не выводится из успешных тестов. Этап 1 и этап 2 подтверждены владельцем. Этап 3 реализован по коду и автотестам (T03.01–T03.14), приёмка T03.15 ожидает владельца и ручных native-проверок. Ранее исправленная боковая панель (`.tag(section)` вместо `Optional`) продолжает работать; разделы «Люди», «Статусы», «Теги» стали рабочими.

| ID | Статус | Коммит / файлы | Проверки | Решение владельца / примечание |
|---|---|---|---|---|
| T00.01 | DONE | `DECISIONS_APPROVED.md` | Документ сверен с D01–D12 | U01–U05 подтверждены владельцем; S01–S12 действуют как временное поведение до отдельного утверждения |
| T00.02 | DONE | `TOOLCHAIN.md`, `Package.swift`, `Package.resolved` | `swift build`, `swift test` | Стек зафиксирован: Swift 6.4.2, GRDB 7.12.0, ZIPFoundation 0.9.20 |
| T00.03 | DONE | `Sources/InventoryCore/Domain/`, `Sources/InventoryCore/Data/` | Контракты проверены тестами ядра | Контракты зафиксированы Swift-протоколами и DTO; отдельные `API_CONTRACT.md`/`RECOVERY_PROTOCOL.md` не создавались |
| T01.01 | DONE | `Package.swift`, `project.yml`, `Inventory.xcodeproj`, `Support/Info.plist` | `swift build`; `xcodebuild ... build` — успешно | Каркас Swift, macOS 12.0, sandbox off, warnings-as-errors; universal-сборка `arm64 x86_64` проверена, запуск на Intel не выполнялся |
| T01.02 | DONE | `Sources/InventoryCore/Data/Schema.swift` | `SchemaTests`: схема, seed, ограничения | places/statuses/people/settings с FK и defaults |
| T01.03 | DONE | `Sources/InventoryCore/Data/Schema.swift` | `SchemaTests.enforcesConstraints` | items/tags/item_tags, CHECK quantity ≥ 1, UNIQUE(name_key) |
| T01.04 | DONE | `Sources/InventoryCore/Data/Schema.swift` | `historyIsImmutable`, `createsIndexes`, `reopensWithForeignKeys` | Четыре триггера истории, семь индексов, FK на каждом открытии |
| T01.05 | DONE | `Sources/InventoryCore/Data/SeedData.swift` | `SchemaTests.seedsOnce` | Семь статусов, три настройки; повторный запуск идемпотентен |
| T01.06 | DONE | `Sources/InventoryCore/Data/RotatingFileLogger.swift`, `Sources/InventoryCore/Domain/DomainError.swift` | `LoggerTests` | Ротация по числу и размеру, ошибка лога не подменяет исходную, доменные ошибки без UI-строк |
| T01.07 | DONE | `Sources/InventoryCore/Data/StorageLock.swift` | `preventsConcurrentOpen`, `lockIsCrossProcess`, `symlinkCannotBypassLock` | `flock` + реестр путей; второй процесс и symlink не обходят блокировку |
| T01.08 | DONE | `Sources/InventoryCore/Data/StorageCoordinator.swift` | `StorageTests`: create/reopen, corrupt, missing path, lock release | Повреждённая БД и пропавший диск не заменяются новой базой, `integrity_check` до работы |
| T01.09 | DONE | `Sources/InventoryCore/Data/MigrationCoordinator.swift` | `MigrationTests`: `VACUUM INTO`, restore с WAL, artificial failure | Копия ДО миграции, откат возвращает прежнюю БД, `user_version` = 1 |
| T01.10 | DONE | `Sources/InventoryPlatform/ImageIOProcessor.swift` | `ImageIOProcessorTests` (8 тестов) | JPEG/PNG/WebP, EXIF, прозрачность → белый фон, лимит 12000 px, ≤2560/400 px |
| T01.11 | DONE | `Sources/InventoryCore/Data/PhotoLifecycle.swift`, `FilePhotoStore.swift` | `PhotoStoreTests`: сбой записи и SQL, удаление после commit, orphans | Новые файлы до SQL, при сбое удаляются, старые — после commit |
| T01.12 | DONE | `Sources/InventoryCore/Data/PlaceServiceImpl.swift` | `PlaceTests`: create/read/update/duplicates/path/reopen | Пустое/длинное имя и отсутствие фото отклоняются; подтверждённые дубли допустимы |
| T01.13 | DONE | `Sources/InventoryCore/Data/PlaceServiceImpl.swift` | `PlaceTests`: `moveKeepsSubtree`, `rejectsCycles` | A→A и перенос под потомка отклоняются; NULL и другой корень работают |
| T01.14 | DONE | `Sources/InventoryCore/Data/PlaceServiceImpl.swift` | `PlaceTests`: `deletesOnlyEmptyPlaces` | Удаляются только пустые места с фото; ошибка содержит `childrenCount` и `itemsCount` |
| T01.15 | DONE | `Sources/InventoryUI/InventoryRootView.swift`, `AppModel.swift`, `Resources/Localizable.xcstrings` | `AppModelTests`; запуск `.app` под временным `CFFIXED_USER_HOME` | Шесть разделов, системная тема, экран сбоя хранилища с повтором/выбором; лог `store created`/`store opened` |
| T01.16 | DONE | `Sources/InventoryUI/PlaceFormModel.swift`, `Sources/InventoryPlatform/SystemFileDialogs.swift` | `PlaceFormModelTests`: выбор, отмена, ошибка обработки | Отмена сохраняет текущее фото; неподдерживаемый файл даёт понятную ошибку |
| T01.17 | DONE | `Sources/InventoryUI/PlaceFormView.swift`, `PlaceFormModel.swift` | `PlaceFormModelTests` (6 тестов) | Без имени/фото не сохраняется, дубль требует подтверждения; ручной осмотр масштабирования и Tab — за владельцем |
| T01.18 | DONE | `Sources/InventoryUI/PlaceBrowserModel.swift`, `PlacesBrowserView.swift` | `PlaceBrowserModelTests` | Три уровня и корень, естественная сортировка, крошки и инспектор обновляются после изменений |
| T01.19 | DONE | `HANDOFF.md` | `swift test` — 63 теста; `xcodebuild test` — 13 UI-тестов | Этап 1 подтверждён владельцем; ручной осмотр HIG остаётся за владельцем |
| T02.01 | DONE | `Sources/InventoryCore/Domain/Tag.swift`, `Data/TagRepository.swift`, `Data/TagServiceImpl.swift` | `TagTests` (7 тестов): нормализация, дубли, автодополнение, удаление неиспользуемых, откат | `TagKey` ≤50, « Ёлка »/«елка»/«ЕЛКА» — один тег; связи меняются в транзакции владельца |
| T02.02 | DONE | `Sources/InventoryCore/Domain/Item.swift`, `Data/ItemServiceImpl.swift`, `Data/ItemRepository.swift` | `ItemTests`: валидации, default status, NULL place, сбой SQL при создании | Фото обязательно, имя ≤200, quantity ≥1, активный статус; откат удаляет новые файлы и теги; история пуста |
| T02.03 | DONE | `Data/ItemServiceImpl.swift` | `ItemTests`: update без смены статуса, NULL place, замена фото, сбой SQL | `ItemDetailsUpdate` не принимает statusId; старое фото и связи сохраняются при сбое; публичного delete вещи нет |
| T02.04 | DONE | `Sources/InventoryPlatform/ImageIOProcessor.swift`, `Tests/InventoryPlatformTests/ImageIOProcessorTests.swift` | `ImageIOProcessorTests` (9 тестов): HEIC и HEIF на реальных fixtures, EXIF, лимит, повреждённый файл | Декодирование вне главного потока; JPEG/thumbnail; ручная проверка HEIC в GUI — за владельцем |
| T02.05 | DONE | `Sources/InventoryUI/PhotoPipeline.swift`, `ItemFormModel.pastePhoto`, `PlaceFormModel.pastePhoto`, обе формы | `ItemFormModelTests`: фото из файла; `PhotoClipboard` читает буфер только по действию | Cmd+V и кнопка «Вставить» в обеих формах; вставка текста в поле имени не перехватывается; GUI-проверка — за владельцем |
| T02.06 | DONE | `Sources/InventoryUI/PhotoPipeline.swift` (`PhotoDrop`), `ItemFormView`, `PlaceFormView` | `ItemFormModelTests.acceptDrop`-путь не покрыт unit-тестом; общий пайплайн `PhotoPipeline` | Подсветка области, один файл на сущность, повреждённый файл не заменяет фото; GUI drag/drop — за владельцем |
| T02.07 | DONE | `Sources/InventoryCore/Data/OrphanPhotoCleaner.swift`, `StorageCoordinator.swift` | `OrphanCleanerTests`: фото вещей и мест сохраняются, сироты удаляются, `_safety` и `_tmp` не затрагиваются | Очистка после lock/integrity/schema; при ошибке БД пропускается и логируется |
| T02.08 | DONE | `Sources/InventoryCore/Domain/Item.swift`, `Data/ItemServiceImpl.swift` | `GalleryTests` (7 тестов): поддерево, noPlace, статусы, AND тегов, сортировки, searchItemIds | Детерминированный tie-break id ASC; несуществующее место — `validationNotFound` |
| T02.09 | DONE | `Sources/InventoryCore/Domain/GalleryState.swift`, `Sources/InventoryUI/GalleryModel.swift`, `AppModel.swift`, `InventoryRootView.swift` | `GalleryStateTests` (5), `GalleryModelTests`, `AppModelTests.persistsSectionMode`; временный AppKit-harness: клики по строкам `tag(section)` переключают раздел | Режим, плитка, сортировка и фильтры вне БД; sanitize исчезнувших id; сброс не трогает вид. Исправлено: `.tag(Optional(section))` не выделялся — заменён на `.tag(section)` |
| T02.10 | DONE | `Sources/InventoryUI/ItemFormModel.swift`, `ItemFormView.swift`, `AppModel.swift`, `InventoryApp.swift` | `ItemFormModelTests` (6): create/edit, read-only status, без фото, теги; `AppModelTests.createsItemWithCurrentPlace` | Все поля, активные статусы при создании, Cmd+N с текущим местом; источник фото — файл/буфер/drag; GUI — за владельцем |
| T02.11 | DONE | `Sources/InventoryUI/GalleryView.swift`, `GalleryModel.swift`, `CommonViews.swift` | `GalleryModelTests`: загрузка, сортировка, размеры; `swift run -c release InventoryFixture` | Ленивая сетка, квадратные thumbnails, loading/empty/error, три размера; прокрутка 500 вещей — ручная проверка |
| T02.12 | DONE | `Sources/InventoryUI/ItemInspectorView.swift`, `GalleryView.swift`, `PlacesBrowserView.swift` | `GalleryModelTests.selectsAndClosesInspector`, `PlaceBrowserModelTests.selectsItemInspector` | Фото без crop, все поля, крошки места, Esc; действия статусов отложены до этапа 3 |
| T02.13 | DONE | `Sources/InventoryUI/PlaceBrowserModel.swift`, `PlacesBrowserView.swift` | `PlaceBrowserModelTests.showsDirectItemsAndNoPlaceCount`, `selectsItemInspector` | «Без места» первым в корне, прямые вещи места, natural sort, создание с предзаполненным местом |
| T02.14 | DONE | `Sources/InventoryUI/GalleryFiltersView.swift`, `GalleryModel.swift` | `GalleryModelTests`: query-параметры, «Без места», архивные статусы, сброс, sanitize | Место с потомками, multiselect статусов и тегов AND; скрытия по статусу нет |
| T02.15 | DONE | `Sources/InventoryFixture/Fixture.swift`, `Package.swift` | `swift run -c release InventoryFixture /tmp/InventoryFixture500` | 500 вещей, 16 мест, 6 тегов, синтетические JPEG; Apple M4: создание 0.25 с, list 1.5 мс, get 0.06 мс; прокрутка GUI — за владельцем |
| T02.16 | DONE | `HANDOFF.md`, этот журнал | `swift test` — 113 тестов; `xcodebuild test` — 31 UI-тест; release universal | Этап 2 подтверждён владельцем 20.11.2026 («все работает»); после исправления сайдбара; этап 3 начат |
| T03.01 | DONE | `Sources/InventoryCore/Domain/Status.swift`, `Data/StatusRepository.swift`, `Data/StatusServiceImpl.swift` | `StatusManagementTests.createsAndRenames`, `validatesName` | Регистронезависимая уникальность среди активных и архивных; `sort_order` только растёт; публичного удаления нет |
| T03.02 | DONE | `Status.swift`, `StatusServiceImpl.swift`, `StorageCoordinator.swift` | `StatusManagementTests.archivesUsedStatusWithReplacement`, `archivesUnusedStatus`, `settingsUpdateIsAtomic` | Три настройки проверяются и меняются одной транзакцией; восстановление не возвращает прежние настройки; вещи сохраняют архивный статус |
| T03.03 | DONE | `Sources/InventoryCore/Domain/Person.swift`, `Data/PeopleRepository.swift`, `Data/PeopleServiceImpl.swift` | `PeopleTests` (4 теста): дубли, архив, история, длина/пустота | `duplicateConfirmed` обязателен при совпадении имени; архивные не предлагаются, история и переименование работают по id |
| T03.04 | DONE | `Sources/InventoryCore/Domain/ItemActions.swift`, `Data/ItemActionServiceImpl.swift` | `ItemActionsTests.changesStatus`, `rejectsInvalidStatusChange`, `rollsBackStatusChange` | Один UPDATE вещи + INSERT истории; тот же/архивный статус отклоняются; сбой триггера откатывает оба |
| T03.05 | DONE | `ItemActions.swift`, `ItemActionServiceImpl.swift` | `ItemActionsTests.giveFlagCombinations` (4 сочетания), `giveSameStatus`, `createsPersonAtomically`, `rollsBackGive` | Дата из `Clock`, quantity не меняется; новый человек коммитится вместе с передачей (D08); при том же статусе нет `status_changes` (D02) |
| T03.06 | DONE | `ItemActions.swift`, `ItemActionServiceImpl.swift` | `ItemActionsTests.returnPlaceAndStatus`, `returnArchivedPerson`, `rollsBackReturn` | D03: архивный человек только из истории вещи; D04: `keep`/`clear`/`place` различимы; текущий статус допустим без истории |
| T03.07 | DONE | `Sources/InventoryCore/Domain/History.swift`, `Data/HistoryReadServiceImpl.swift` | `HistoryTests` (4 теста): смешанная лента, tie-break D12, архивные, отсутствующие id | Только чтение; текущие имена по id; порядок: `created_at` desc, передача раньше статуса, затем id ASC |
| T03.08 | DONE | `Sources/InventoryCore/Domain/Tag.swift`, `Data/TagRepository.swift`, `Data/TagServiceImpl.swift` | `TagManagementTests.renamesAndConflicts`, `mergesWithoutDuplicates`, `mergeRejectsThirdName`, `mergeRollsBack` | Конфликт имени возвращает `tagId` для предложения merge; связи переносятся без дублей; при сбое сохраняются оба тега |
| T03.09 | DONE | `Tag.swift`, `TagRepository.swift`, `TagServiceImpl.swift` | `TagManagementTests.listsCounts`, `deletesFromAllItems`, `deleteRollsBack` | `listWithCounts` считает уникальные вещи; `delete` возвращает `TagDeletion` с itemId; пустой тег отдельно не создаётся |
| T03.10 | DONE | `Sources/InventoryUI/StatusesModel.swift`, `StatusesWorkspaceView.swift` | `Stage3ModelsTests.statusesModel`, `statusesArchiveError`; model-тесты | Активные/архивные, замена при архивации, восстановление, три настройки; галерея перечитывает метки по `statuses.changes` |
| T03.11 | DONE | `Sources/InventoryUI/PeopleModel.swift`, `PeopleWorkspaceView.swift`, `AppModel.swift` | `Stage3ModelsTests.peopleModel`; ручной GUI-переход — за владельцем | Форма имя/телефон/заметка, дубль с подтверждением, архив/восстановление, история с переходом к вещи в галерею |
| T03.12 | DONE | `Sources/InventoryUI/TagsModel.swift`, `TagsWorkspaceView.swift` | `Stage3ModelsTests.tagsSorting`, `tagsRenameConflict`; core-тесты merge/delete | Сортировки имя/количество, inline rename с предложением merge, merge с итоговым именем, delete с числом вещей; обновление по `items.changes` |
| T03.13 | DONE | `Sources/InventoryUI/ItemInspectorView.swift`, `ItemActionsModels.swift`, `ItemActionSheets.swift`, `GalleryModel.swift` | `Stage3ModelsTests.changeStatusModel`, `changeStatusFailure`; core-тесты истории | Меню «Действия» и общий диалог с комментарием; лента с датой/было→стало/человеком; после ошибки строка не появляется |
| T03.14 | DONE | `Sources/InventoryUI/ItemActionSheets.swift`, `ItemActionsModels.swift`, `AppModel.swift`, `InventoryRootView.swift` | `Stage3ModelsTests.giveDefaults`, `giveNewPersonAndDuplicate`, `giveValidation`, `returnDefaults`, `returnPlaceValidation` | Подсказка о части количества дословно из §6.6; оба флажка и `transfer_status_id` по умолчанию; последний получатель и `return_status_id`; повторная отправка блокируется `isSaving` |
| T03.15 | BLOCKED | `HANDOFF.md`, этот журнал | `swift test` — 157 тестов (105 core, 9 platform, 43 UI); `xcodebuild test` — 43 UI; release universal; `swift format lint` чисто | Ожидается подтверждение владельца после ручных native-проверок; этап 4 не начинается |
| T04.01 | TODO | — | Не выполнялись | — |
| T04.02 | TODO | — | Не выполнялись | — |
| T04.03 | TODO | — | Не выполнялись | — |
| T04.04 | TODO | — | Не выполнялись | — |
| T04.05 | TODO | — | Не выполнялись | — |
| T04.06 | TODO | — | Не выполнялись | — |
| T04.07 | TODO | — | Не выполнялись | — |
| T04.08 | TODO | — | Не выполнялись | — |
| T05.01 | TODO | — | Не выполнялись | — |
| T05.02 | TODO | — | Не выполнялись | — |
| T05.03 | TODO | — | Не выполнялись | — |
| T05.04 | TODO | — | Не выполнялись | — |
| T05.05 | TODO | — | Не выполнялись | — |
| T05.06 | TODO | — | Не выполнялись | — |
| T05.07 | TODO | — | Не выполнялись | — |
| T05.08 | TODO | — | Не выполнялись | — |
| T05.09 | TODO | — | Не выполнялись | — |
| T05.10 | TODO | — | Не выполнялись | — |
| T05.11 | TODO | — | Не выполнялись | — |
| T05.12 | TODO | — | Не выполнялись | — |
| T05.13 | TODO | — | Не выполнялись | — |
| T05.14 | TODO | — | Не выполнялись | — |
| T05.15 | TODO | — | Не выполнялись | — |
| T05.16 | TODO | — | Не выполнялись | — |
| T05.17 | TODO | — | Не выполнялись | — |
| T05.18 | TODO | — | Не выполнялись | — |
