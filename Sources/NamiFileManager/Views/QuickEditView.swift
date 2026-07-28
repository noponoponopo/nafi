import SwiftUI

struct QuickEditRequest: Identifiable, Equatable {
  let id = UUID()
  let url: URL
}

@MainActor
final class QuickEditDocument: ObservableObject {
  @Published private(set) var url: URL
  @Published var text = ""
  @Published private(set) var isLoading = true
  @Published private(set) var isSaving = false
  @Published private(set) var isDirty = false
  @Published private(set) var isWritable = false
  @Published private(set) var encodingLabel = "—"
  @Published private(set) var lineEnding = QuickEditLineEnding.lineFeed
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published var hasExternalChangeConflict = false

  private var encodingRawValue = String.Encoding.utf8.rawValue
  private var hasByteOrderMark = false
  private var modificationDate: Date?
  private var workingURL: URL?
  private let onSaved: (URL) -> Void
  private var loadTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?

  init(url: URL, onSaved: @escaping (URL) -> Void) {
    self.url = url
    self.onSaved = onSaved
  }

  var characterCount: Int { text.count }
  var lineCount: Int { text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

  func updateText(_ value: String) {
    text = value
    if !isLoading { isDirty = true }
    statusMessage = nil
  }

  func load() {
    loadTask?.cancel()
    isLoading = true
    errorMessage = nil
    statusMessage = "読み込み中…"
    hasExternalChangeConflict = false
    let sourceURL = url

    loadTask = Task { [weak self] in
      let result: Result<(URL, QuickEditSnapshot), Error>
      do {
        let localURL = try await UnifiedFileSystemService.prepareLocalCopy(of: sourceURL)
        let snapshot = try await Task.detached(priority: .userInitiated) {
          try QuickEditService.read(localURL)
        }.value
        result = .success((localURL, snapshot))
      } catch {
        result = .failure(error)
      }
      guard let self, !Task.isCancelled else { return }
      self.isLoading = false
      switch result {
      case .success(let value):
        let (localURL, snapshot) = value
        self.workingURL = localURL
        self.text = snapshot.text
        self.encodingRawValue = snapshot.encodingRawValue
        self.encodingLabel = snapshot.encodingLabel
        self.lineEnding = snapshot.lineEnding
        self.hasByteOrderMark = snapshot.hasByteOrderMark
        self.modificationDate = snapshot.modificationDate
        self.isWritable = snapshot.isWritable
        self.isDirty = false
        self.statusMessage = snapshot.isWritable ? "読み込みました" : "読み取り専用"
      case .failure(let error):
        self.errorMessage = error.localizedDescription
        self.statusMessage = nil
      }
    }
  }

  func save(force: Bool = false) {
    guard !isSaving else { return }
    guard isWritable else {
      errorMessage = QuickEditError.notWritable.localizedDescription
      return
    }

    saveTask?.cancel()
    isSaving = true
    errorMessage = nil
    statusMessage = "保存中…"
    hasExternalChangeConflict = false

    guard let targetURL = workingURL else {
      errorMessage = QuickEditError.readFailed.localizedDescription
      isSaving = false
      return
    }
    let sourceURL = url
    let text = text
    let encodingRawValue = encodingRawValue
    let lineEnding = lineEnding
    let hasByteOrderMark = hasByteOrderMark
    let expectedModificationDate = modificationDate

    saveTask = Task { [weak self] in
      let result: Result<Date?, Error>
      do {
        let modificationDate = try await Task.detached(priority: .userInitiated) {
          try QuickEditService.write(
            text,
            to: targetURL,
            encodingRawValue: encodingRawValue,
            lineEnding: lineEnding,
            hasByteOrderMark: hasByteOrderMark,
            expectedModificationDate: expectedModificationDate,
            force: force
          )
        }.value
        if NafiURL.isRemote(sourceURL) {
          try await UnifiedFileSystemService.uploadEditedLocalCopy(targetURL, to: sourceURL)
        }
        result = .success(modificationDate)
      } catch {
        result = .failure(error)
      }
      guard let self, !Task.isCancelled else { return }
      self.isSaving = false
      switch result {
      case .success(let modificationDate):
        self.modificationDate = modificationDate
        self.isDirty = false
        self.statusMessage = "保存しました"
        self.onSaved(sourceURL)
      case .failure(let error as QuickEditError) where error == .changedExternally:
        self.hasExternalChangeConflict = true
        self.statusMessage = nil
      case .failure(let error):
        self.errorMessage = error.localizedDescription
        self.statusMessage = nil
      }
    }
  }
}

struct QuickEditView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var document: QuickEditDocument
  @FocusState private var editorFocused: Bool
  @State private var showsDiscardConfirmation = false
  @State private var showsReloadConfirmation = false

  init(url: URL, onSaved: @escaping (URL) -> Void) {
    _document = StateObject(wrappedValue: QuickEditDocument(url: url, onSaved: onSaved))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      ZStack {
        TextEditor(
          text: Binding(
            get: { document.text },
            set: { document.updateText($0) }
          )
        )
        .font(.system(.body, design: .monospaced))
        .focused($editorFocused)
        .disabled(document.isLoading || document.errorMessage != nil)
        .padding(8)

        if document.isLoading {
          ProgressView("読み込み中…")
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      footer
    }
    .frame(minWidth: 560, idealWidth: 760, minHeight: 420, idealHeight: 580)
    .interactiveDismissDisabled(document.isDirty)
    .task {
      document.load()
      try? await Task.sleep(nanoseconds: 180_000_000)
      editorFocused = true
    }
    .alert(
      "クイックエディット",
      isPresented: Binding(
        get: { document.errorMessage != nil },
        set: { if !$0 { document.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { document.errorMessage = nil }
    } message: {
      Text(document.errorMessage ?? "不明なエラーです。")
    }
    .confirmationDialog(
      "外部で変更されています",
      isPresented: $document.hasExternalChangeConflict,
      titleVisibility: .visible
    ) {
      Button("再読み込み") { document.load() }
      Button("現在の内容で強制保存", role: .destructive) { document.save(force: true) }
      Button("キャンセル", role: .cancel) {}
    } message: {
      Text(QuickEditError.changedExternally.localizedDescription)
    }
    .confirmationDialog(
      "未保存の変更を破棄して再読み込みしますか？",
      isPresented: $showsReloadConfirmation,
      titleVisibility: .visible
    ) {
      Button("変更を破棄して再読み込み", role: .destructive) { document.load() }
      Button("キャンセル", role: .cancel) {}
    }
    .confirmationDialog(
      "保存せずに閉じますか？",
      isPresented: $showsDiscardConfirmation,
      titleVisibility: .visible
    ) {
      Button("変更を破棄", role: .destructive) { dismiss() }
      Button("キャンセル", role: .cancel) {}
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "square.and.pencil")
        .font(.title3)
        .foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 2) {
        Text(document.url.lastPathComponent)
          .font(.headline)
          .lineLimit(1)
        Text(
          NafiURL.isRemote(document.url)
            ? (NafiURL.remotePath(in: NafiURL.parent(of: document.url)) ?? "/")
            : document.url.deletingLastPathComponent().path
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }
      Spacer()
      if document.isDirty {
        Label("未保存", systemImage: "circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 58)
    .background(.bar)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text("\(document.encodingLabel) · \(document.lineEnding.label)")
      Text("·")
      Text("\(document.lineCount)行 · \(document.characterCount)文字")
      if let status = document.statusMessage {
        Text("·")
        Text(status)
      }
      Spacer()
      Button("再読み込み") {
        if document.isDirty {
          showsReloadConfirmation = true
        } else {
          document.load()
        }
      }
      .disabled(document.isLoading || document.isSaving)
      Button("閉じる") {
        if document.isDirty {
          showsDiscardConfirmation = true
        } else {
          dismiss()
        }
      }
      Button("保存") { document.save() }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(
          document.isLoading || document.isSaving || !document.isDirty || !document.isWritable)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .frame(height: 44)
    .background(.bar)
  }
}
