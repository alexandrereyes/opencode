import OpenCodeKit
import Photos
import UIKit

/// The most recent photos' metadata, with small JPEG thumbnails attached as tool images.
@MainActor final class DevicePhotosCollector {
  private static let thumbnailSide: CGFloat = 384
  private static let thumbnailBytes = 220_000

  var authorization: DeviceAuthorization {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized: .authorized
    case .limited: .limited
    case .denied: .denied
    case .restricted: .restricted
    default: .notDetermined
    }
  }

  func requestAuthorization() async -> DeviceAuthorization {
    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    return authorization
  }

  func collect(_ query: DeviceQuery) async -> DeviceAnswer {
    struct Place: Encodable { let latitude: Double; let longitude: Double }
    struct Photo: Encodable {
      let id: String
      let created: Date?
      let kind: String
      let width: Int
      let height: Int
      let favorite: Bool
      let place: Place?
      let thumbnail: String?
    }
    struct Photos: Encodable { let count: Int; let photos: [Photo] }
    guard authorization.usable else {
      return .failure(.denied,
        "Photo library access is not granted (Você → Dados do iPhone or iOS Settings).")
    }
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    options.fetchLimit = min(max(query.limit ?? 5, 1), 10)
    let result = PHAsset.fetchAssets(with: options)
    var assets: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in assets.append(asset) }
    var photos: [Photo] = []
    var files: [DeviceFile] = []
    var skipped = 0
    for (index, asset) in assets.enumerated() {
      let name = "photo-\(index + 1).jpg"
      var attached: String?
      if query.thumbnails ?? true {
        if let data = await thumbnail(asset), data.count <= Self.thumbnailBytes {
          files.append(DeviceFile(name: name, mime: "image/jpeg", data: data.base64EncodedString()))
          attached = name
        } else { skipped += 1 }
      }
      let subtypes = asset.mediaSubtypes
      let kind = subtypes.contains(.photoScreenshot) ? "screenshot" : subtypes.contains(.photoLive) ? "live"
        : subtypes.contains(.photoPanorama) ? "panorama" : subtypes.contains(.photoDepthEffect) ? "portrait" : "photo"
      photos.append(Photo(id: asset.localIdentifier, created: asset.creationDate, kind: kind, width: asset.pixelWidth,
        height: asset.pixelHeight, favorite: asset.isFavorite,
        place: asset.location.map { Place(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
        thumbnail: attached))
    }
    return .ok(Photos(count: photos.count, photos: photos), files: files.isEmpty ? nil : files,
      note: skipped > 0 ? "\(skipped) thumbnail(s) were unavailable on the device (for example, only in iCloud)." : nil)
  }

  private func thumbnail(_ asset: PHAsset) async -> Data? {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    options.isSynchronous = false
    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: Self.thumbnailSide, height: Self.thumbnailSide),
        contentMode: .aspectFit, options: options) { @Sendable image, _ in
        continuation.resume(returning: image?.jpegData(compressionQuality: 0.6))
      }
    }
  }
}
