import Foundation
import os

/// Файловый лог с ротацией: `logs/app.log`, `logs/app.1.log` … `logs/app.4.log`.
/// Ошибка записи лога не пробрасывается наружу и не скрывает исходную ошибку.
public final class RotatingFileLogger: AppLogger, @unchecked Sendable {
  public struct Configuration: Sendable {
    public var maxFileSize: Int
    public var maxFiles: Int
    public var echoToStandardError: Bool

    /// - Parameters:
    ///   - maxFileSize: порог ротации одного файла.
    ///   - maxFiles: всего файлов, включая текущий `app.log`.
    public init(
      maxFileSize: Int = 1_048_576,
      maxFiles: Int = 5,
      echoToStandardError: Bool = false
    ) {
      self.maxFileSize = max(1_024, maxFileSize)
      self.maxFiles = max(1, maxFiles)
      self.echoToStandardError = echoToStandardError
    }
  }

  private let directory: URL
  private let configuration: Configuration
  private let fileManager: FileManager
  private let systemLog = os.Logger(subsystem: "app.inventory", category: "core")
  private let lock = NSLock()
  private var warnedAboutFailure = false

  public init(
    directory: URL,
    configuration: Configuration = Configuration(),
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.configuration = configuration
    self.fileManager = fileManager
  }

  public var currentLogURL: URL {
    directory.appendingPathComponent("app.log")
  }

  public func debug(_ message: String, data: [String: String]?) {
    write(.debug, message, error: nil, data: data)
  }

  public func info(_ message: String, data: [String: String]?) {
    write(.info, message, error: nil, data: data)
  }

  public func warning(_ message: String, error: String?, data: [String: String]?) {
    write(.warning, message, error: error, data: data)
  }

  public func error(_ message: String, error: String?, data: [String: String]?) {
    write(.error, message, error: error, data: data)
  }

  private func write(
    _ level: LogLevel,
    _ message: String,
    error: String?,
    data: [String: String]?
  ) {
    switch level {
    case .debug: systemLog.debug("\(message, privacy: .public)")
    case .info: systemLog.info("\(message, privacy: .public)")
    case .warning: systemLog.warning("\(message, privacy: .public)")
    case .error: systemLog.error("\(message, privacy: .public)")
    }

    let line = format(level, message, error: error, data: data)
    lock.lock()
    defer { lock.unlock() }
    do {
      try append(line)
    } catch {
      reportFailureOnce(error)
    }
  }

  private func format(
    _ level: LogLevel,
    _ message: String,
    error: String?,
    data: [String: String]?
  ) -> String {
    let timestamp = Self.timestampFormatter.string(from: Date())
    var parts = ["\(timestamp) \(level.rawValue.uppercased()) \(message)"]
    if let error, !error.isEmpty {
      parts.append("error=\(error)")
    }
    if let data, !data.isEmpty {
      let pairs = data.keys.sorted().map { "\($0)=\(data[$0] ?? "")" }
      parts.append(pairs.joined(separator: " "))
    }
    return parts.joined(separator: " ") + "\n"
  }

  private func append(_ line: String) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = currentLogURL
    let data = Data(line.utf8)
    if fileManager.fileExists(atPath: url.path) {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      if size > 0 && size + data.count > configuration.maxFileSize {
        try rotate()
      }
    }
    if !fileManager.fileExists(atPath: currentLogURL.path) {
      fileManager.createFile(atPath: currentLogURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: currentLogURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private func rotate() throws {
    let archives = max(0, configuration.maxFiles - 1)
    if archives == 0 {
      try? fileManager.removeItem(at: currentLogURL)
      return
    }
    let oldest = self.archiveURL(index: archives)
    try? fileManager.removeItem(at: oldest)
    if archives > 1 {
      for index in stride(from: archives - 1, through: 1, by: -1) {
        let source = archiveURL(index: index)
        let destination = archiveURL(index: index + 1)
        if fileManager.fileExists(atPath: source.path) {
          try? fileManager.removeItem(at: destination)
          try fileManager.moveItem(at: source, to: destination)
        }
      }
    }
    let first = archiveURL(index: 1)
    try? fileManager.removeItem(at: first)
    try fileManager.moveItem(at: currentLogURL, to: first)
  }

  private func archiveURL(index: Int) -> URL {
    directory.appendingPathComponent("app.\(index).log")
  }

  private func reportFailureOnce(_ error: Error) {
    guard !warnedAboutFailure else { return }
    warnedAboutFailure = true
    let text = "Inventory: file logging is unavailable: \(error)\n"
    if let data = text.data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
  }

  nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
