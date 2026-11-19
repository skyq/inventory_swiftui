import Foundation
import InventoryCore

enum AsyncCore {
  /// Выполняет блокирующую работу ядра вне главного потока.
  static func run<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async -> Result<T, AppException> {
    await Task.detached(priority: .userInitiated) {
      do {
        return Result<T, AppException>.success(try work())
      } catch let error as AppException {
        return .failure(error)
      } catch {
        return .failure(AppException(.internalError, debugMessage: String(describing: error)))
      }
    }.value
  }
}
