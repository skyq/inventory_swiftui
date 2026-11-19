# HANDOFF — состояние проекта после задачи

Задача: этап 1 (T01.01–T01.18), приёмка T01.19
Результат: DONE по коду и автотестам; BLOCKED по подтверждению владельца
Коммит или точные изменённые файлы: см. `git status` после коммита этапа 1; основные каталоги — `Package.swift`, `project.yml`, `Support/`, `Sources/`, `Tests/`, `fixtures/`, `DECISIONS_APPROVED.md`, `TOOLCHAIN.md`, `Inventory.xcodeproj/`

## Что уже работает

- Swift-пакет из трёх библиотек (`InventoryCore`, `InventoryPlatform`, `InventoryUI`) и тонкого исполняемого таргета `InventoryApp`; Xcode-проект генерируется `project.yml` через XcodeGen.
- Схема SQLite v1: places, statuses, people, items, tags, item_tags, status_changes, transfers, settings; FK, CHECK, UNIQUE, четыре триггера неизменяемой истории и семь индексов.
- Seed: семь статусов и три настройки, повторный запуск идемпотентен и не перезаписывает выбор владельца.
- Файловый лог с ротацией, доменные `AppException` без русских UI-строк.
- Блокировка папки через `flock` + реестр путей; повторное открытие, symlink и второй процесс не обходят lock.
- Создание/открытие хранилища, `integrity_check`, отказ от создания пустой базы при пропавшем пути или повреждённом файле.
- Резервная копия `VACUUM INTO` перед миграцией, откат с удалением `-wal`/`-shm`/`-journal`, `PRAGMA user_version = 1`.
- Обработка фото через ImageIO: JPEG/PNG/WebP, EXIF, белый фон вместо alpha, лимит 12000 px, фото ≤2560 px и превью ≤400 px, вне UI-потока.
- Согласование файлов и SQL: новые файлы до commit, удаление при сбое SQL, старые — после commit, очистка сирот.
- Места: CRUD, обязательное фото, дубли после подтверждения, путь, потомки, естественная сортировка, перенос поддерева без циклов, удаление только пустых мест с фото.
- Нативный SwiftUI-каркас: source-list сайдбар из шести разделов, toolbar-поиск, вложенный `HSplitView`, хлебные крошки, сетка мест, инспектор, модальная форма, экран сбоя хранилища, `Settings`, Cmd+N/K/W/Esc.
- 98 русских строк в String Catalog; `L10n` и `ErrorPresenter` переводят доменные ошибки.

## Действующие контракты

- `DECISIONS_APPROVED.md`: U01–U05 подтверждены; S01–S12 — временное поведение до отдельного утверждения.
- `TOOLCHAIN.md`: Swift 6.4.2, GRDB 7.12.0, ZIPFoundation 0.9.20; macOS 12.0, sandbox и hardened runtime выключены.
- Контракты ядра — публичные протоколы и DTO в `Sources/InventoryCore/Domain/`; UI не содержит SQL.
- Данные совместимы с Flutter-редакцией: `user_version = 1`, служебная таблица `grdb_migrations` сохранена для будущих миграций GRDB.
- Новых решений без подтверждения нет.

## Проверки

- `swift test` → 63 теста в 12 сюитах: 42 core, 8 platform, 13 UI; все прошли.
- `swift format lint --recursive Sources Tests` → без замечаний.
- `swift build -c release` → `Build complete`.
- `xcodebuild ... -configuration Debug ... test` → `TEST SUCCEEDED`, 13 UI-тестов.
- `xcodebuild ... -configuration Release -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` → `BUILD SUCCEEDED`, `lipo -info` показывает `x86_64 arm64`.
- Запуск `.app` с временным `CFFIXED_USER_HOME` → создан `inventory.db`, каталоги `photos/`, `thumbs/`, `logs/`, `_safety/`, `_tmp/`; лог содержит `store created` и `store opened`.
- Не выполнено: запуск на Intel Mac, ручной осмотр HIG/масштабирования текста/Tab, скриншот окна (среда без доступа к дисплею).

## Входы для следующей задачи

- Следующий ID: T01.19 (приёмка этапа 1), затем T02.01.
- Точные файлы кода/тестов: `Sources/InventoryCore/`, `Sources/InventoryPlatform/`, `Sources/InventoryUI/`, `Tests/`, `project.yml`, `Inventory.xcodeproj/`, `RUN_LOG.md`.
- Ограничения, незавершённое, временные заглушки: поиск в toolbar намеренно показывает заглушку «следующий этап»; тема и локализация готовы к расширению; `Inventory.xcodeproj` генерируется из `project.yml` и не редактируется вручную.
- Для конца этапа: подтверждение владельца ожидается.
