import SwiftUI

@main
struct InventoryAppIOSApp: App {
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 12) {
        Image(systemName: "shippingbox")
          .font(.system(size: 48))
          .foregroundColor(.accentColor)
        Text("Инвентарь")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Сборка iOS: IOS.01")
          .font(.callout)
          .foregroundColor(.secondary)
      }
      .padding()
    }
  }
}
