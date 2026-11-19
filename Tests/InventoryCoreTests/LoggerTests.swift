import Foundation
import InventoryCore
import Testing

@Suite("Файловый лог")
struct LoggerTests {
  @Test("Ротация ограничивает число и размер файлов")
  func rotatesFiles() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let logger = RotatingFileLogger(
      directory: logs,
      configuration: .init(maxFileSize: 2_048, maxFiles: 3)
    )

    let message = String(repeating: "я", count: 60)
    for _ in 0..<400 {
      logger.info(message, data: ["key": "value"])
    }

    let files = try FileManager.default.contentsOfDirectory(
      at: logs, includingPropertiesForKeys: nil)
    #expect(files.count <= 3)
    #expect(files.contains(where: { $0.lastPathComponent == "app.log" }))
    for file in files {
      let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
      #expect((size?.intValue ?? 0) <= 2_048 + 256)
    }
  }

  @Test("Недоступный каталог логов не бросает ошибку и не мешает работе")
  func brokenDirectoryDoesNotThrow() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let fileAsDirectory = root.appendingPathComponent("logs")
    try Data("not a directory".utf8).write(to: fileAsDirectory)

    let logger = RotatingFileLogger(directory: fileAsDirectory)
    logger.info("сообщение не должно уронить приложение")
    logger.error("ошибка", error: "details", data: ["key": "value"])
    #expect(true)
  }

  @Test("NullLogger ничего не делает")
  func nullLoggerIsNoOp() {
    let logger = NullLogger()
    logger.debug("d", data: nil)
    logger.info("i", data: nil)
    logger.warning("w", error: nil, data: nil)
    logger.error("e", error: "err", data: nil)
    #expect(true)
  }
}
