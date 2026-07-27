import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
  static let namiFileCollection = UTType(exportedAs: "app.nami.file-collection")
  static let namiPaneTab = UTType(exportedAs: "app.nami.pane-tab")
}

struct FileDragPayload: Codable, Transferable {
  let urls: [URL]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .namiFileCollection)
  }
}

struct PaneDragPayload: Codable, Transferable {
  let sourcePaneID: UUID
  let sourceTabID: UUID
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .namiPaneTab)
  }
}
