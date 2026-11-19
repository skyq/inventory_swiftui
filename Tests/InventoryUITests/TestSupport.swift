import Foundation
import InventoryCore

@testable import InventoryUI

func makeTestPlace(
  id: String,
  parentId: String? = nil,
  name: String,
  description: String = "",
  photo: Bool = true
) -> Place {
  Place(
    id: id,
    parentId: parentId,
    name: name,
    description: description,
    photoFile: photo ? "photos/\(id).jpg" : nil,
    thumbFile: photo ? "thumbs/\(id).jpg" : nil,
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000
  )
}

func makeTestPhoto() -> ProcessedPhoto {
  ProcessedPhoto(
    photoBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01]),
    thumbBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x02]),
    width: 100,
    height: 80,
    thumbWidth: 40,
    thumbHeight: 32,
    originalWidth: 200,
    originalHeight: 160
  )
}

final class FakePlaceService: PlaceService, @unchecked Sendable {
  private let lock = NSLock()
  private var placesById: [String: Place] = [:]
  private var created: [(PlaceCreate, Bool)] = []
  private var updated: [(PlaceDetailsUpdate, Bool)] = []
  private var idCounter = 0
  private let continuation: AsyncStream<MutationEvent>.Continuation
  let changes: AsyncStream<MutationEvent>

  var createError: AppException?
  var duplicateUntilConfirmed = false
  var updateError: AppException?
  var childrenError: AppException?
  var deleteError: AppException?

  init(initial: [Place] = []) {
    for place in initial {
      placesById[place.id] = place
    }
    (changes, continuation) = AsyncStream.makeStream(of: MutationEvent.self)
  }

  var allPlaces: [Place] {
    lock.lock()
    defer { lock.unlock() }
    return sorted(Array(placesById.values))
  }

  var createdInputs: [(PlaceCreate, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return created
  }

  var updatedInputs: [(PlaceDetailsUpdate, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return updated
  }

  func emit(_ event: MutationEvent) {
    continuation.yield(event)
  }

  func create(_ input: PlaceCreate, duplicateConfirmed: Bool) throws -> Place {
    lock.lock()
    created.append((input, duplicateConfirmed))
    if let createError, !(duplicateUntilConfirmed && duplicateConfirmed) {
      lock.unlock()
      throw createError
    }
    idCounter += 1
    let id = "created-\(idCounter)"
    let place = Place(
      id: id,
      parentId: input.parentId,
      name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
      description: input.description,
      photoFile: input.photo == nil ? nil : "photos/\(id).jpg",
      thumbFile: input.photo == nil ? nil : "thumbs/\(id).jpg",
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_000_000
    )
    placesById[id] = place
    lock.unlock()
    continuation.yield(.placesChanged(affectedIds: [id], parentId: place.parentId, kind: .created))
    return place
  }

  func get(_ id: String) throws -> Place {
    lock.lock()
    defer { lock.unlock() }
    guard let place = placesById[id] else {
      throw AppException(.validationNotFound, params: ["id": .string(id)])
    }
    return place
  }

  func updateDetails(_ input: PlaceDetailsUpdate, duplicateConfirmed: Bool) throws -> Place {
    lock.lock()
    updated.append((input, duplicateConfirmed))
    if let updateError {
      lock.unlock()
      throw updateError
    }
    guard let existing = placesById[input.id] else {
      lock.unlock()
      throw AppException(.validationNotFound, params: ["id": .string(input.id)])
    }
    let place = Place(
      id: existing.id,
      parentId: input.parentId,
      name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
      description: input.description,
      photoFile: existing.photoFile,
      thumbFile: existing.thumbFile,
      createdAt: existing.createdAt,
      updatedAt: 1_700_000_000_100
    )
    placesById[place.id] = place
    lock.unlock()
    continuation.yield(
      .placesChanged(affectedIds: [place.id], parentId: place.parentId, kind: .updated))
    return place
  }

  func move(_ id: String, newParentId: String?) throws -> Place {
    lock.lock()
    defer { lock.unlock() }
    guard let existing = placesById[id] else {
      throw AppException(.validationNotFound, params: ["id": .string(id)])
    }
    let moved = Place(
      id: existing.id,
      parentId: newParentId,
      name: existing.name,
      description: existing.description,
      photoFile: existing.photoFile,
      thumbFile: existing.thumbFile,
      createdAt: existing.createdAt,
      updatedAt: 1_700_000_000_100
    )
    placesById[moved.id] = moved
    return moved
  }

  func deleteEmpty(_ id: String) throws {
    lock.lock()
    if let deleteError {
      lock.unlock()
      throw deleteError
    }
    if placesById.values.contains(where: { $0.parentId == id }) {
      lock.unlock()
      throw AppException(.placeNotEmpty, params: ["childrenCount": .int(1), "itemsCount": .int(0)])
    }
    placesById[id] = nil
    lock.unlock()
    continuation.yield(.placesChanged(affectedIds: [id], parentId: nil, kind: .deleted))
  }

  func children(of parentId: String?) throws -> [Place] {
    lock.lock()
    if let childrenError {
      lock.unlock()
      throw childrenError
    }
    let result = sorted(placesById.values.filter { $0.parentId == parentId })
    lock.unlock()
    return result
  }

  func descendants(of id: String) throws -> [Place] {
    lock.lock()
    defer { lock.unlock() }
    return descendants(id, in: Array(placesById.values))
  }

  func path(to id: String) throws -> PlacePath {
    lock.lock()
    defer { lock.unlock() }
    var segments: [Place] = []
    var visited: Set<String> = []
    var current: String? = id
    while let cursor = current {
      guard visited.insert(cursor).inserted else {
        throw AppException(.placeCycle, params: ["placeId": .string(id)])
      }
      guard let place = placesById[cursor] else {
        throw AppException(.validationNotFound, params: ["id": .string(cursor)])
      }
      segments.append(place)
      current = place.parentId
    }
    return PlacePath(segments: segments.reversed())
  }

  func all() throws -> [Place] {
    lock.lock()
    defer { lock.unlock() }
    return sorted(Array(placesById.values))
  }

  func invalidParentIds(for placeId: String?) throws -> Set<String> {
    guard let placeId else { return [] }
    lock.lock()
    defer { lock.unlock() }
    var result = Set(descendants(placeId, in: Array(placesById.values)).map(\.id))
    result.insert(placeId)
    return result
  }

  private func descendants(_ id: String, in all: [Place]) -> [Place] {
    var result: [Place] = []
    var queue = [id]
    var visited: Set<String> = [id]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      for child in all where child.parentId == current && visited.insert(child.id).inserted {
        result.append(child)
        queue.append(child.id)
      }
    }
    return result
  }

  private func sorted<S: Sequence>(_ places: S) -> [Place] where S.Element == Place {
    places.sorted { NaturalSort.compare($0.name, $1.name) < 0 }
  }
}

final class FakePhotoStore: PhotoStore, @unchecked Sendable {
  let layout: StoreLayout

  init(root: URL = URL(fileURLWithPath: "/tmp/inventory-ui-tests", isDirectory: true)) {
    self.layout = StoreLayout(rootURL: root)
  }

  func store(_ photo: ProcessedPhoto) throws -> StoredPhoto {
    StoredPhoto(photoFile: "photos/fake.jpg", thumbFile: "thumbs/fake.jpg")
  }

  func deleteFiles(photoFile: String, thumbFile: String) {}

  func fileURL(for relativePath: String) throws -> URL {
    try layout.fileURL(forRelativePath: relativePath)
  }

  func cleanupOrphans(referencedRelativePaths: Set<String>) {}
}

actor FakeImageProcessor: ImageProcessor {
  private var result: ProcessedPhoto
  private var error: AppException?
  private(set) var calls = 0

  init(result: ProcessedPhoto = makeTestPhoto(), error: AppException? = nil) {
    self.result = result
    self.error = error
  }

  func process(_ input: PhotoInput) async throws -> ProcessedPhoto {
    calls += 1
    if let error {
      throw error
    }
    return result
  }

  func callCount() -> Int { calls }

  func setError(_ error: AppException?) {
    self.error = error
  }
}

@MainActor
final class FakeFileDialogs: FileDialogs {
  var imageURL: URL?
  var directoryURL: URL?
  private(set) var imageRequestCount = 0
  private(set) var directoryRequestCount = 0

  func chooseDirectory(startingAt url: URL?) -> URL? {
    directoryRequestCount += 1
    return directoryURL
  }

  func chooseImageFile() -> URL? {
    imageRequestCount += 1
    return imageURL
  }
}

func makeTemporaryFile(contents: String = "image") throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("InventoryUITest-\(UUID().uuidString).jpg")
  try Data(contents.utf8).write(to: url)
  return url
}
