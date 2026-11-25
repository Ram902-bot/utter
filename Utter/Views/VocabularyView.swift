import SwiftUI
import UniformTypeIdentifiers

/// "Utter learns your words". Three ways in, each with its own button:
/// fix words from History, import a Markdown file (with a review step), or add words by hand.
struct VocabularyView: View {
    @EnvironmentObject var appState: AppState
    @State private var newTerm = ""
    @State private var importReview: ImportReview?
    @State private var addedMessage: String?
    @State private var confirmClear = false
    @FocusState private var termFieldFocused: Bool

    private var vocab: VocabularyStore { appState.vocabulary }

    struct ImportReview: Identifiable {
        let id = UUID()
        let fileLabel: String
        let terms: [String]
        let unreadable: Int
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Teach Utter your words")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Product names, people, acronyms and code terms often come out wrong. Teach Utter once and it spells them right from then on.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    guideStep(1, "Fix words as you go",
                              "When a word comes out wrong, open History and click Fix on that entry. Utter corrects it and remembers.") {
                        Button("Open History") { appState.selectedPage = .history }
                    }
                    guideStep(2, "Import your work words",
                              "Have a glossary, README, wiki page or notes saved as Markdown (.md)? Utter picks out the names and terms, and you choose which to keep.") {
                        Button("Import .md File...") { pickMarkdown() }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    TextField("Add a word", text: $newTerm, prompt: Text("Add a word before it goes wrong, e.g. a new teammate's name"))
                        .focused($termFieldFocused)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let addedMessage {
                    Label(addedMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                if vocab.terms.isEmpty {
                    Text("No words yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(vocab.terms, id: \.self) { term in
                            chip(term)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("My words")
                    Spacer()
                    if !vocab.terms.isEmpty {
                        Text("\(vocab.terms.count)").foregroundColor(.secondary)
                        Button("Clear All...") { confirmClear = true }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text(vocab.terms.count > VocabularyStore.maxHintTerms
                     ? "Only the first \(VocabularyStore.maxHintTerms) words are used. Remove the ones you rarely say."
                     : "Utter gives these words to the speech model before it listens, so it leans towards these spellings.")
                    .font(.caption)
                    .foregroundColor(vocab.terms.count > VocabularyStore.maxHintTerms ? .orange : .secondary)
            }

            Section {
                if vocab.replacements.isEmpty {
                    Text("None yet. Click Fix on a History entry when a word comes out wrong.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(vocab.replacements) { rule in
                    HStack {
                        Text(rule.heard).foregroundColor(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
                        Text(rule.write).fontWeight(.medium)
                        Spacer()
                        Button {
                            vocab.removeReplacement(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                        .accessibilityLabel("Remove fix for \(rule.heard)")
                    }
                }
            } header: {
                Text("Always fix")
            } footer: {
                Text("Saved from Fix in History. They always apply, to whole words, any capitalisation. Everything on this page stays on this Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .sheet(item: $importReview) { review in
            ImportReviewSheet(review: review) { selected in
                let added = vocab.add(selected)
                addedMessage = "Added \(added) words from \(review.fileLabel)"
            }
        }
        .confirmationDialog("Remove all words?", isPresented: $confirmClear) {
            Button("Remove All Words", role: .destructive) { vocab.clearTerms() }
        } message: {
            Text("Your fixes are kept.")
        }
    }

    private func guideStep<A: View>(_ n: Int, _ title: String, _ detail: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
    }

    private func chip(_ term: String) -> some View {
        HStack(spacing: 4) {
            Text(term)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                vocab.remove(term)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(term)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }

    private func addTerm() {
        let added = vocab.add(newTerm.components(separatedBy: ","))
        if added > 0 {
            addedMessage = added == 1 ? "Added 1 word" : "Added \(added) words"
            newTerm = ""
        }
    }

    private func pickMarkdown() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.prompt = "Find Words"
        panel.message = "Choose Markdown files with the words you use: glossaries, READMEs, wiki pages, notes"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let (terms, unreadable) = vocab.previewImport(from: panel.urls)
        let label = panel.urls.count == 1 ? panel.urls[0].lastPathComponent : "\(panel.urls.count) files"
        importReview = ImportReview(fileLabel: label, terms: terms, unreadable: unreadable)
    }
}

/// Review step after picking a Markdown file: all found words ticked, untick what you never say
struct ImportReviewSheet: View {
    let review: VocabularyView.ImportReview
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.terms.isEmpty ? "No new words found" : "Found \(review.terms.count) words in \(review.fileLabel)")
                    .font(.system(size: 17, weight: .semibold))
                Text(review.terms.isEmpty
                     ? "Utter looks for names, acronyms and terms. This file had none that aren't already in your list."
                     : "Untick anything you never say out loud. Keep product names, people and jargon.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if review.unreadable > 0 {
                    Text("\(review.unreadable) file(s) couldn't be read.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }

            if !review.terms.isEmpty {
                HStack {
                    Button("Select All") { selected = Set(review.terms) }
                    Button("Select None") { selected = [] }
                    Spacer()
                    Text("\(selected.count) selected").font(.system(size: 11)).foregroundColor(.secondary)
                }
                .controlSize(.small)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(review.terms, id: \.self) { term in
                            Toggle(term, isOn: Binding(
                                get: { selected.contains(term) },
                                set: { on in if on { selected.insert(term) } else { selected.remove(term) } }))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
            }

            HStack {
                Spacer()
                Button(review.terms.isEmpty ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !review.terms.isEmpty {
                    Button("Add \(selected.count) Words") {
                        onAdd(review.terms.filter { selected.contains($0) })
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { selected = Set(review.terms) }
    }
}
