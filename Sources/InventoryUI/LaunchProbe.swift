import Foundation

/// Замер запуска (T05.17, D11): от старта приложения до готовой галереи.
///
/// Ничего не делает без переменной окружения `INVENTORY_LAUNCH_PROBE`:
/// в файл по этому пути записывается время от создания модели до загрузки галереи.
@MainActor
public enum LaunchProbe {
  private static var startedAt: Date?
  private static var reported = false

  public static func begin() {
    if startedAt == nil {
      startedAt = Date()
    }
  }

  public static func markReady() {
    guard !reported, let startedAt else { return }
    reported = true
    guard
      let path = ProcessInfo.processInfo.environment["INVENTORY_LAUNCH_PROBE"],
      !path.isEmpty
    else { return }
    let elapsed = Date().timeIntervalSince(startedAt)
    try? Data("\(elapsed)\n".utf8).write(to: URL(fileURLWithPath: path))
  }
}
