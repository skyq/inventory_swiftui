import SwiftUI
import UIKit

/// Квадратная обрезка фото: фото сдвигается под неподвижной рамкой, масштаб увеличивает фото (IOS.06).
struct SquareCropView: View {
  /// Изображение в ориентации «вверх» и с масштабом 1 (см. `normalizedForCrop`).
  let image: UIImage
  let onCancel: () -> Void
  let onDone: (Data) -> Void

  @State private var scale: CGFloat = 1
  @State private var lastScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var lastOffset: CGSize = .zero

  private let maxScale: CGFloat = 5
  /// Рамка занимает эту долю короткой стороны фото, чтобы оставался ход для сдвига в обе стороны.
  private let frameRatio: CGFloat = 0.8

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let layout = layout(in: geometry.size)

        ZStack {
          Image(uiImage: image)
            .resizable()
            .frame(width: layout.displayWidth, height: layout.displayHeight)
            .offset(offset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
              DragGesture()
                .onChanged { value in
                  let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                  )
                  offset = clamped(proposed, layout: layout)
                }
                .onEnded { _ in
                  lastOffset = offset
                }
            )
            .simultaneousGesture(
              MagnificationGesture()
                .onChanged { value in
                  scale = min(max(lastScale * value, 1), maxScale)
                  offset = clamped(offset, layout: self.layout(in: geometry.size))
                }
                .onEnded { _ in
                  lastScale = scale
                  offset = clamped(offset, layout: self.layout(in: geometry.size))
                  lastOffset = offset
                }
            )

          Rectangle()
            .stroke(Color.white, lineWidth: 2)
            .frame(width: layout.frameSide, height: layout.frameSide)
            .allowsHitTesting(false)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .navigationTitle("Обрезка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Отмена") {
              onCancel()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Готово") {
              if let data = crop(layout: layout) {
                onDone(data)
              }
            }
          }
        }
      }
    }
  }

  private struct Layout {
    /// Масштаб «фото целиком» в точках на пиксель изображения.
    let fitFactor: CGFloat
    /// Текущий масштаб отображения: fitFactor * scale.
    let factor: CGFloat
    let displayWidth: CGFloat
    let displayHeight: CGFloat
    /// Сторона рамки в точках экрана (не меняется при масштабе).
    let frameSide: CGFloat
  }

  private func layout(in size: CGSize) -> Layout {
    let width = image.size.width
    let height = image.size.height
    let fit = min(size.width / width, size.height / height)
    let factor = fit * scale
    return Layout(
      fitFactor: fit,
      factor: factor,
      displayWidth: width * factor,
      displayHeight: height * factor,
      frameSide: min(width, height) * fit * frameRatio
    )
  }

  private func clamped(_ value: CGSize, layout: Layout) -> CGSize {
    let maxX = max(0, (layout.displayWidth - layout.frameSide) / 2)
    let maxY = max(0, (layout.displayHeight - layout.frameSide) / 2)
    return CGSize(
      width: min(max(value.width, -maxX), maxX),
      height: min(max(value.height, -maxY), maxY)
    )
  }

  private func crop(layout: Layout) -> Data? {
    let side = layout.frameSide / layout.factor
    let centerX = image.size.width / 2 - offset.width / layout.factor
    let centerY = image.size.height / 2 - offset.height / layout.factor
    let rect = CGRect(
      x: centerX - side / 2,
      y: centerY - side / 2,
      width: side,
      height: side
    ).intersection(CGRect(origin: .zero, size: image.size))
    guard let cgImage = image.cgImage?.cropping(to: rect) else { return nil }
    return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
  }
}

extension UIImage {
  /// Перерисовка в ориентации «вверх» с масштабом 1: координаты обрезки совпадают с пикселями.
  func normalizedForCrop() -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
