import Foundation

/// Технические коды доменных ошибок. Русский текст живёт только в UI-локализации.
public enum AppErrorCode: String, Sendable, CaseIterable {
  case validationRequired
  case validationTooLong
  case validationOutOfRange
  case validationNotFound
  case duplicateName
  case placeCycle
  case placeNotEmpty
  case statusArchived
  case statusInUse
  case statusUnchanged
  case statusNameDuplicate
  case personNameDuplicate
  case personArchived
  case tagNameConflict
  case storageUnavailable
  case storageBusy
  case storageCorrupt
  case storageNewerSchema
  case storageIntegrityFailed
  case migrationFailed
  case photoUnsupportedFormat
  case photoTooLarge
  case photoCorrupt
  case photoWriteFailed
  case photoReadFailed
  case backupInvalidZip
  case backupManifestInvalid
  case backupNewerFormat
  case backupIntegrityFailed
  case backupLimitExceeded
  case importFailed
  case rollbackFailed
  case ioError
  case internalError
}

/// Параметр ошибки: только примитивы, пригодные для подстановки в UI-строку.
public enum ErrorParam: Sendable, Equatable {
  case string(String)
  case int(Int)
  case bool(Bool)
}

/// Доменная ошибка без UI-строк и зависимостей от SwiftUI/AppKit.
public struct AppException: Error, Sendable, CustomStringConvertible {
  public let code: AppErrorCode
  public let params: [String: ErrorParam]
  public let debugMessage: String?

  public init(
    _ code: AppErrorCode,
    params: [String: ErrorParam] = [:],
    debugMessage: String? = nil
  ) {
    self.code = code
    self.params = params
    self.debugMessage = debugMessage
  }

  /// Ключ локализации сообщения.
  public var localizationKey: String { "error.\(code.rawValue)" }

  public var description: String {
    if let debugMessage {
      return "AppException(\(code.rawValue)): \(debugMessage)"
    }
    return "AppException(\(code.rawValue))"
  }

  public func int(_ key: String) -> Int? {
    if case .int(let value) = params[key] { return value }
    return nil
  }

  public func string(_ key: String) -> String? {
    if case .string(let value) = params[key] { return value }
    return nil
  }
}

extension ErrorParam: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension ErrorParam: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .int(value) }
}
