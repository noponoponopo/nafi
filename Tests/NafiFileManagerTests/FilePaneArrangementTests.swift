import Foundation
import XCTest

@testable import NafiFileManager

final class FilePaneArrangementTests: XCTestCase {
  private func item(
    _ name: String,
    isDirectory: Bool,
    modified: Date?,
    size: Int64? = nil
  ) -> FileItem {
    FileItem(
      url: URL(fileURLWithPath: "/tmp/\(name)"),
      name: name,
      isDirectory: isDirectory,
      isPackage: false,
      isHidden: false,
      fileSize: size,
      creationDate: nil,
      modificationDate: modified,
      contentTypeIdentifier: isDirectory ? "public.folder" : "public.plain-text",
      tagNames: []
    )
  }

  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  func testModifiedSortInterleavesFoldersAndFilesByDate() {
    let items = [
      item("古いファイル.txt", isDirectory: false, modified: base.addingTimeInterval(-300)),
      item("新しいフォルダ", isDirectory: true, modified: base.addingTimeInterval(+300)),
      item("中間のファイル.md", isDirectory: false, modified: base),
      item("古いフォルダ", isDirectory: true, modified: base.addingTimeInterval(-600)),
      item("新しいファイル.png", isDirectory: false, modified: base.addingTimeInterval(+100)),
    ]

    let arranged = FilePaneModel.arranged(
      items,
      query: "",
      filter: .all,
      sort: .modified,
      descending: false
    )

    // フォルダ/ファイルに関係なく、更新日の古い順に混ざって並ぶ。
    XCTAssertEqual(
      arranged.map(\.name),
      [
        "古いフォルダ",
        "古いファイル.txt",
        "中間のファイル.md",
        "新しいファイル.png",
        "新しいフォルダ",
      ]
    )
  }

  func testModifiedSortDescendingInterleavesFoldersAndFilesByDate() {
    let items = [
      item("古いファイル.txt", isDirectory: false, modified: base.addingTimeInterval(-300)),
      item("新しいフォルダ", isDirectory: true, modified: base.addingTimeInterval(+300)),
      item("古いフォルダ", isDirectory: true, modified: base.addingTimeInterval(-600)),
    ]

    let arranged = FilePaneModel.arranged(
      items,
      query: "",
      filter: .all,
      sort: .modified,
      descending: true
    )

    XCTAssertEqual(arranged.map(\.name), ["新しいフォルダ", "古いファイル.txt", "古いフォルダ"])
  }

  func testNameSortStillGroupsFoldersFirst() {
    let items = [
      item("zeta.txt", isDirectory: false, modified: base),
      item("alpha", isDirectory: true, modified: base),
      item("beta.txt", isDirectory: false, modified: base),
    ]

    let arranged = FilePaneModel.arranged(
      items,
      query: "",
      filter: .all,
      sort: .name,
      descending: false
    )

    XCTAssertEqual(arranged.map(\.name), ["alpha", "beta.txt", "zeta.txt"])
  }
}
