import SwiftUI
import UIKit

/// Системная камера (IOS.05). Возвращает JPEG-данные снимка или nil при отмене.
struct CameraPicker: UIViewControllerRepresentable {
  let onFinish: (Data?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onFinish: onFinish)
  }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.allowsEditing = true
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate
  {
    private let onFinish: (Data?) -> Void

    init(onFinish: @escaping (Data?) -> Void) {
      self.onFinish = onFinish
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
      let data = image?.jpegData(compressionQuality: 0.95)
      onFinish(data)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      onFinish(nil)
    }
  }
}
