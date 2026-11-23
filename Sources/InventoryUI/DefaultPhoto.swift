import Foundation
import InventoryCore

/// Пустое фото для новой вещи и нового места. Взято из ThingsMap2
/// (`app/assets/images/place_placeholder.png`) и проходит тот же обработчик,
/// что и пользовательские снимки, поэтому сохраняется как обычное фото.
enum DefaultPhoto {
  static let resourceName = "place_placeholder"

  static func process(images: any ImageProcessor) async -> ProcessedPhoto? {
    guard
      let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? await PhotoPipeline.process(
      data: data,
      sourceName: "\(resourceName).png",
      images: images
    )
  }
}
