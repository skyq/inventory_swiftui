import SwiftUI

@main
struct InventoryAppIOSApp: App {
  var body: some Scene {
    WindowGroup {
      SelfCheckView()
    }
  }
}

struct SelfCheckView: View {
  @State private var lines: [StorageSelfCheck.Line] = []
  @State private var running = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button(running ? "Проверка…" : "Запустить проверку хранилища") {
            Task {
              running = true
              lines = await StorageSelfCheck.run()
              running = false
            }
          }
          .disabled(running)
        }
        if !lines.isEmpty {
          Section("Результаты") {
            ForEach(lines) { line in
              VStack(alignment: .leading, spacing: 4) {
                Label(line.title, systemImage: line.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                  .foregroundColor(line.passed ? .green : .red)
                Text(line.detail)
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }
        }
      }
      .navigationTitle("Инвентарь")
    }
  }
}
