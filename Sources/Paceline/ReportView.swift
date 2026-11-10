import AppKit
import SwiftUI

/// Report a Problem…: the diagnostics, shown in full before anything leaves.
/// Copy puts them on the clipboard; Open GitHub Issue opens an empty bug form
/// (nothing in its URL) for the user to paste into.
struct ReportView: View {
    let model: AppModel
    @State private var text: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem").font(.headline)
            Text("This is everything Paceline adds to a report: versions, and each AI's status and what was found. No email, account name, project, path or token. Nothing is sent: copy it, then paste it into the issue.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text ?? "Reading…")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    guard let text else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .disabled(text == nil)
                Button("Open GitHub Issue") { NSWorkspace.shared.open(Diagnostics.issueURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
        .task {
            let accounts = await Task.detached { AccountsReader.all() }.value
            text = Diagnostics.current(model: model, accounts: accounts)
        }
    }
}
