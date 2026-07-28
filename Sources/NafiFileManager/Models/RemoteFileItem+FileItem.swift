import Foundation
import UniformTypeIdentifiers

extension FileItem {
  init(remote item: RemoteFileItem, profileID: UUID) {
    let url = NafiURL.remoteURL(profileID: profileID, path: item.path)
    let type = item.isDirectory ? UTType.folder : UTType(filenameExtension: url.pathExtension)
    self.init(
      url: url,
      name: item.name,
      isDirectory: item.isDirectory,
      isPackage: false,
      isHidden: item.name.hasPrefix("."),
      fileSize: item.size.flatMap { value in
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
      },
      creationDate: nil,
      modificationDate: item.modifiedAt,
      contentTypeIdentifier: type?.identifier,
      tagNames: []
    )
  }
}
