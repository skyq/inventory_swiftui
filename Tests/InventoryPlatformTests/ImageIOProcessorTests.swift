import CryptoKit
import Foundation
import ImageIO
import InventoryCore
import Testing

@testable import InventoryPlatform

@Suite("Обработка фото через ImageIO")
struct ImageIOProcessorTests {
  private let processor = ImageIOProcessor()

  @Test("JPEG обрабатывается без апскейла, оригинал не меняется")
  func processesJPEG() async throws {
    let url = fixture("sample.jpg")
    let original = try Data(contentsOf: url)
    let hashBefore = SHA256.hash(data: original)

    let result = try await processor.process(PhotoInput(bytes: original, sourceName: "sample.jpg"))

    #expect(result.width == 100)
    #expect(result.height == 100)
    #expect(result.thumbWidth == 100)
    #expect(result.thumbHeight == 100)
    #expect(result.originalWidth == 100)
    #expect(result.originalHeight == 100)
    #expect(isJPEG(result.photoBytes))
    #expect(isJPEG(result.thumbBytes))
    #expect((try Data(contentsOf: url)).count == original.count)
    #expect(SHA256.hash(data: try Data(contentsOf: url)) == hashBefore)
  }

  @Test("PNG с прозрачностью превращается в JPEG на белом фоне")
  func flattensTransparentPNG() async throws {
    let data = try Data(contentsOf: fixture("sample_transparent.png"))
    let result = try await processor.process(
      PhotoInput(bytes: data, sourceName: "sample_transparent.png"))

    #expect(result.width == 100)
    #expect(result.height == 100)
    #expect(isJPEG(result.photoBytes))

    let source = try #require(CGImageSourceCreateWithData(result.photoBytes as CFData, nil))
    let type = try #require(CGImageSourceGetType(source) as String?)
    #expect(type == "public.jpeg")
  }

  @Test("EXIF orientation 6 применяется до ресайза")
  func appliesEXIFOrientation() async throws {
    let data = try Data(contentsOf: fixture("sample_exif_orientation_6.jpg"))
    let result = try await processor.process(PhotoInput(bytes: data, sourceName: "exif.jpg"))

    #expect(result.originalWidth == 200)
    #expect(result.originalHeight == 100)
    #expect(result.width == 100)
    #expect(result.height == 200)
    #expect(result.thumbWidth == 100)
    #expect(result.thumbHeight == 200)
  }

  @Test("WebP принимается")
  func processesWebP() async throws {
    let data = try Data(contentsOf: fixture("sample.webp"))
    let result = try await processor.process(PhotoInput(bytes: data, sourceName: "sample.webp"))
    #expect(result.width == 100)
    #expect(result.height == 100)
    #expect(isJPEG(result.photoBytes))
  }

  @Test("Слишком большое изображение отклоняется до полного декодирования")
  func rejectsTooLargeImage() async throws {
    let data = try Data(contentsOf: fixture("sample_huge_12000px.jpg"))
    do {
      _ = try await processor.process(PhotoInput(bytes: data, sourceName: "huge.jpg"))
      Issue.record("Ожидалась ошибка photoTooLarge")
    } catch let error as AppException {
      #expect(error.code == .photoTooLarge)
      #expect(error.int("max") == 12_000)
      #expect(error.int("width") == 12_001)
    }
  }

  @Test("Повреждённый файл даёт photoCorrupt")
  func rejectsCorruptImage() async throws {
    let data = try Data(contentsOf: fixture("sample_corrupted.jpg"))
    do {
      _ = try await processor.process(PhotoInput(bytes: data, sourceName: "corrupt.jpg"))
      Issue.record("Ожидалась ошибка photoCorrupt")
    } catch let error as AppException {
      #expect(error.code == .photoCorrupt)
    }
  }

  @Test("HEIC пока не принимается (этап 2)")
  func rejectsHEICForNow() async throws {
    let data = try Data(contentsOf: fixture("sample.heic"))
    do {
      _ = try await processor.process(PhotoInput(bytes: data, sourceName: "sample.heic"))
      Issue.record("Ожидалась ошибка photoUnsupportedFormat")
    } catch let error as AppException {
      #expect(error.code == .photoUnsupportedFormat)
    }
  }

  @Test("Пустые байты отклоняются")
  func rejectsEmptyInput() async {
    do {
      _ = try await processor.process(PhotoInput(bytes: Data()))
      Issue.record("Ожидалась ошибка photoCorrupt")
    } catch let error as AppException {
      #expect(error.code == .photoCorrupt)
    } catch {
      Issue.record("Неожиданная ошибка: \(error)")
    }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures")
      .appendingPathComponent(name)
  }

  private func isJPEG(_ data: Data) -> Bool {
    data.count > 2 && data[0] == 0xFF && data[1] == 0xD8
  }
}
