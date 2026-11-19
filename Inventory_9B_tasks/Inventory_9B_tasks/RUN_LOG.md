# Журнал выполнения

Статусы этапа 1 обновлены по фактическому коду и прогонам 20 ноября 2026. Подтверждение этапа хранится отдельной записью и не выводится из успешных тестов.

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
| T01.06 | DONE | `Sources/InventoryCore/Infrastructure/` | `LoggerTests` | Ротация по числу и размеру, ошибка лога не подменяет исходную, доменные ошибки без UI-строк |
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
| T01.19 | BLOCKED | `HANDOFF.md` | `swift test` — 63 теста; `xcodebuild test` — 13 UI-тестов | Ожидается подтверждение владельца этапа 1 и ручной осмотр HIG; без него этап 2 не начинается |
| T02.01 | TODO | — | Не выполнялись | — |
| T02.02 | TODO | — | Не выполнялись | — |
| T02.03 | TODO | — | Не выполнялись | — |
| T02.04 | TODO | — | Не выполнялись | — |
| T02.05 | TODO | — | Не выполнялись | — |
| T02.06 | TODO | — | Не выполнялись | — |
| T02.07 | TODO | — | Не выполнялись | — |
| T02.08 | TODO | — | Не выполнялись | — |
| T02.09 | TODO | — | Не выполнялись | — |
| T02.10 | TODO | — | Не выполнялись | — |
| T02.11 | TODO | — | Не выполнялись | — |
| T02.12 | TODO | — | Не выполнялись | — |
| T02.13 | TODO | — | Не выполнялись | — |
| T02.14 | TODO | — | Не выполнялись | — |
| T02.15 | TODO | — | Не выполнялись | — |
| T02.16 | TODO | — | Не выполнялись | — |
| T03.01 | TODO | — | Не выполнялись | — |
| T03.02 | TODO | — | Не выполнялись | — |
| T03.03 | TODO | — | Не выполнялись | — |
| T03.04 | TODO | — | Не выполнялись | — |
| T03.05 | TODO | — | Не выполнялись | — |
| T03.06 | TODO | — | Не выполнялись | — |
| T03.07 | TODO | — | Не выполнялись | — |
| T03.08 | TODO | — | Не выполнялись | — |
| T03.09 | TODO | — | Не выполнялись | — |
| T03.10 | TODO | — | Не выполнялись | — |
| T03.11 | TODO | — | Не выполнялись | — |
| T03.12 | TODO | — | Не выполнялись | — |
| T03.13 | TODO | — | Не выполнялись | — |
| T03.14 | TODO | — | Не выполнялись | — |
| T03.15 | TODO | — | Не выполнялись | — |
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
