import SwiftUI

struct QuickOpenView: View {
  @ObservedObject var model: QuickOpenModel
  let open: (QuickOpenResult) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selection: QuickOpenResult.ID?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("場所、接続、ファイルを検索", text: $model.query)
          .textFieldStyle(.plain)
          .focused($focused)
          .onSubmit { openSelection() }
        if model.isSearching { ProgressView().controlSize(.small) }
      }
      .padding(14)
      Divider()
      List(model.results, selection: $selection) { item in
        HStack(spacing: 10) {
          Image(systemName: item.systemImage).frame(width: 22)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1)
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
        }
        .tag(item.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openItem(item) }
      }
      .listStyle(.inset)
    }
    .frame(minWidth: 680, minHeight: 460)
    .onAppear {
      selection = model.results.first?.id
      focused = true
    }
    .onChange(of: model.results) { _, values in
      if selection == nil || !values.contains(where: { $0.id == selection }) { selection = values.first?.id }
    }
  }

  private func openSelection() {
    guard let selection, let item = model.results.first(where: { $0.id == selection }) else { return }
    openItem(item)
  }

  private func openItem(_ item: QuickOpenResult) {
    open(item)
    dismiss()
  }
}
