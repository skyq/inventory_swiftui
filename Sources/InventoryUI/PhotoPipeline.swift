import Foundation
import InventoryCore
import UniformTypeIdentifiers

/// Единый путь чтения и обработки фото для обеих форм и drag/drop.
enum PhotoPipeline {
  static func process(url: URL, images: any ImageProcessor) async throws -> ProcessedPhoto {
    let data = try await Task.detached(priority: .userInitiated) {
      try Data(contentsOf: url)
    }.value
    return try await images.process(
      PhotoInput(bytes: data, sourceName: url.lastPathComponent)
    )
  }

  static func process(
    data: Data,
    sourceName: String?,
    images: any ImageProcessor
  ) async throws -> ProcessedPhoto {
    try await images.process(PhotoInput(bytes: data, sourceName: sourceName))
  }
}

/// Загрузка перетащенных файлов и изображений. У сущности одно фото, поэтому
/// используется только первый подходящий элемент, без пакетного создания.
@MainActor
enum PhotoDrop {
  static let acceptedTypes: [UTType] = [.image, .fileURL]

  static func load(_ providers: [NSItemProvider]) async -> (data: Data, name: String?)? {
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      guard let url = await loadFileURL(provider) else { continue }
      if let data = try? await Task.detached(
        priority: .userInitiated,
        operation: { try Data(contentsOf: url) }
      ).value {
        return (data, url.lastPathComponent)
      }
    }

    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      if let data = await loadImageData(provider) {
        return (data, "drop")
      }
    }
    return nil
  }

  private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        if let data = item as? Data,
          let url = URL(dataRepresentation: data, relativeTo: nil)
        {
          continuation.resume(returning: url)
        } else if let url = item as? URL {
          continuation.resume(returning: url)
        } else if let url = item as? NSURL {
          continuation.resume(returning: url as URL)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }
}

/// Чтение изображения из системного буфера обмена. Вне действия пользователя не вызывается.
#if os(macOS)
  import AppKit

  enum PhotoClipboard {
    static func read() -> (data: Data, sourceName: String?)? {
      let pasteboard = NSPasteboard.general
      if let urls = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL], let url = urls.first {
        if let data = try? Data(contentsOf: url) {
          return (data, url.lastPathComponent)
        }
      }

      if let data = pasteboard.data(forType: .png) {
        return (data, "clipboard.png")
      }
      if let data = pasteboard.data(forType: .tiff),
        let rep = NSBitmapImageRep(data: data),
        let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
      {
        return (jpeg, "clipboard.jpg")
      }
      for type in ["public.jpeg", "public.heic", "public.heif"] {
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) {
          return (data, "clipboard")
        }
      }
      return nil
    }
  }
#else
  import UIKit

  enum PhotoClipboard {
    static func read() -> (data: Data, sourceName: String?)? {
      guard let image = UIPasteboard.general.image, let data = image.pngData() else { return nil }
      return (data, "clipboard.png")
    }
  }
#endif
