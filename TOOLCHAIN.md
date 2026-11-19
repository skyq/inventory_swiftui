# TOOLCHAIN — зафиксированный стек

Версия: 1.0
Дата: 19 ноября 2026
Основание: T00.02, §4.1, §11, §17 ТЗ. Факты получены на реальной машине разработки, не из документации.
Правило: версии ниже не меняются в отдельных задачах без записи в этом файле и подтверждения владельца.

## Проверенное окружение

| Компонент | Факт | Примечание |
|---|---|---|
| Машина разработки | macOS 26.7.1 (25G241), arm64 (Apple Silicon) | Intel и macOS 12/13/14 не проверялись (см. S01) |
| Xcode | 27.2 (27B52) | `xcode-select` указывает на `/Applications/Xcode.app/Contents/Developer` |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) | Swift 6 language mode |
| macOS SDK | 27.2 (`MacOSX27.2.sdk`) | `MinimumDeploymentTarget` в SDK = 13.1 — это не целевой минимум приложения |
| swift-format | из тулчейна Xcode | `xcrun --find swift-format` |
| Git | 2.54.0 | |
| Homebrew | 7.0.13 | `/opt/homebrew/bin/brew` |
| Свободно на диске | 37 ГиБ | |

## Зависимости приложения

Подтягиваются SwiftPM из GitHub; версии фиксируются в `Package.resolved`, который коммитится.

| Пакет | Версия (факт) | Ограничение в `Package.swift` | Назначение |
|---|---|---|---|
| GRDB.swift | 7.12.0 | `from: "7.0.0"` | SQLite: `DatabasePool`, миграции, `ValueObservation` |
| ZIPFoundation | 0.9.20 | `from: "0.9.0"` | `.inventory.zip` |

Системные фреймворки без зависимостей: Foundation, SwiftUI, AppKit, ImageIO, CoreGraphics, UniformTypeIdentifiers.

## Проверенные команды

Выполнены на этой машине 19.11.2026:

| Команда | Результат |
|---|---|
| `swift build` (проба с GRDB 7.12.0 и ZIPFoundation 0.9.20, `platforms: [.macOS(.v12)]`, arm64) | Build complete |
| `swift build --arch x86_64` (та же проба) | Build complete, с предупреждением (см. ниже) |
| `swift build -c release --arch arm64` (та же проба) | Build complete |
| `clang -target arm64-apple-macos12.0` / `macos13.1` | exit 0 |
| `swiftc -target arm64-apple-macos12.0` / `x86_64-apple-macos12.0` | OK; `lipo -info` подтвердил архитектуры |

Команды, которые ещё не выполнялись (будут фиксироваться по мере появления проекта):
`swift test`, `swift format lint --recursive Sources Tests`, `xcodebuild ... build`, `xcodebuild ... test`.

## Предупреждения и ограничения

- **x86_64 deprecated.** Xcode 27.2 при сборке x86_64 выводит: «The x86_64 architecture is deprecated for your deployment target (macOS 27.2)». Сборка проходит. Universal-сборка остаётся целью до решения S01.
- **Deployment target 12.0.** Сборка под `macos12.0` проходит на Xcode 27.2. Запуск на реальной macOS 12 не проверен.
- **Swift Testing и Xcode.** Машина разработки должна быть новее целевой macOS; целевая macOS 12.0 — только минимум для запуска приложения.
- **Совместимость API.** `NavigationSplitView` недоступен на macOS 12: для раскладки используется `HSplitView`/AppKit-мост (см. план, раздел «Нативный внешний вид»).

## Инструменты разработки (не входят в поставку)

| Инструмент | Статус | Зачем |
|---|---|---|
| XcodeGen | рекомендован, установка — см. ниже | генерация `.xcodeproj` из `project.yml` |
| xcbeautify | рекомендован | читаемые логи `xcodebuild` |

Не используются: Flutter, Dart, CocoaPods, Carthage, fastlane, SwiftLint. Стиль проверяется `swift format`.

## Что не входит в стек

Core Data, SwiftData, FTS5, системные токенизаторы, `NaturalLanguage` (S05), любые Dart/Flutter-пакеты (см. раздел «Только Swift» в плане).

## История изменений

- 1.0 (19.11.2026): первая фиксация по факту проверки на машине разработки.
