#if os(macOS)
  import AppKit
  import Foundation
  import InventoryCore

  /// Системные диалоги macOS за протоколом ядра.
  @MainActor
  public final class SystemFileDialogs: FileDialogs {
    public init() {}

    public func chooseDirectory(startingAt url: URL?) -> URL? {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = "Выбрать"
      panel.message = "Выберите папку данных"
      if let url {
        panel.directoryURL = url
      }
      return panel.runModal() == .OK ? panel.url : nil
    }

    public func chooseImageFile() -> URL? {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.allowedContentTypes = [.jpeg, .png, .webP, .heic, .heif]
      panel.prompt = "Выбрать"
      panel.message = "Выберите фотографию"
      return panel.runModal() == .OK ? panel.url : nil
    }

    public func chooseArchiveFile() -> URL? {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.allowedContentTypes = [.zip]
      panel.prompt = "Выбрать"
      panel.message = "Выберите архив .inventory.zip"
      return panel.runModal() == .OK ? panel.url : nil
    }
  }
#endif
