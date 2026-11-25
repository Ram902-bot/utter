import SwiftUI

/// Opened from a History entry: "Utter wrote X, I said Y". Fixes the entry, copies it,
/// and (by default) remembers the fix as a replacement and adds the word to the vocabulary.
struct FixWordSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let entry: DictationEntry

    @State private var wrote = ""
    @State private var said = ""
    @State private var alwaysFix = true
    @State private var addToWords = true

    private var wroteTrimmed: String { wrote.trimmingCharacters(in: .whitespaces) }
    private var saidTrimmed: String { said.trimmingCharacters(in: .whitespaces) }
    private var found: Bool {
        !wroteTrimmed.isEmpty && VocabularyStore.containsWholeWord(wroteTrimmed, in: entry.text)
    }
    private var preview: String {
        guard found, !saidTrimmed.isEmpty else { return entry.text }
        return VocabularyStore.replaceWholeWord(wroteTrimmed, with: saidTrimmed, in: entry.text)
    }
    private var canSave: Bool { !wroteTrimmed.isEmpty && !saidTrimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fix a word")
                    .font(.system(size: 17, weight: .semibold))
                Text("Tell Utter what it got wrong. It fixes this entry and remembers for next time.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text(entry.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Utter wrote").foregroundColor(.secondary)
                    TextField("Utter wrote", text: $wrote, prompt: Text("e.g. Wibecraft"))
                        .labelsHidden()
                }
                GridRow {
                    Text("You said").foregroundColor(.secondary)
                    TextField("You said", text: $said, prompt: Text("e.g. VibeCraft"))
                        .labelsHidden()
                        .onSubmit { if canSave { save() } }
                }
            }
            .font(.system(size: 13))

            if !wroteTrimmed.isEmpty && !found {
                Text("\"\(wroteTrimmed)\" isn't in this entry. Copy the wrong word or words exactly as they appear above.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            } else if found && !saidTrimmed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("After the fix").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    Text(preview).font(.system(size: 13))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Always fix \"\(wroteTrimmed.isEmpty ? "this" : wroteTrimmed)\" from now on", isOn: $alwaysFix)
                Toggle("Add \"\(saidTrimmed.isEmpty ? "the right word" : saidTrimmed)\" to my words", isOn: $addToWords)
            }
            .font(.system(size: 12))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fix & Copy", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        if alwaysFix { appState.vocabulary.addReplacement(heard: wroteTrimmed, write: saidTrimmed) }
        if addToWords { appState.vocabulary.add([saidTrimmed]) }
        if found {
            appState.history.updateText(of: entry, to: preview)
            appState.pasteManager.copyToClipboard(preview)
        }
        dismiss()
    }
}
