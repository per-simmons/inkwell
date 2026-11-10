import SwiftUI
import SwiftData
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

/// The note editor (PRD §6.4): top chrome, floating toolbar + sub-bar, paged canvas,
/// page navigator, and the right-side rail (recordings panel / pages).
struct NoteEditorView: View {
    @Bindable var editor: EditorModel
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var moving = false
    @State private var goToPageText = ""
    @State private var sharePDF: URL?
    @State private var shareAudio: [URL]?
    @State private var photoItem: PhotosPickerItem?

    private var recorder: AudioRecorder { .shared }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .zIndex(2)
            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    CanvasHost(controller: editor.canvas)
                        .ignoresSafeArea(.container, edges: .bottom)

                    subBar
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            Spacer()
                            if editor.isEmpty && editor.pageCount == 1 {
                                PaperQuickPicker(editor: editor)
                                    .transition(.opacity)
                            }
                            Spacer()
                        }
                        .padding(.bottom, 22)
                    }
                    .allowsHitTesting(editor.isEmpty)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            PageNavigator(editor: editor)
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 18)
                    }
                }
                .animation(.snappy(duration: 0.22), value: subBarKind)
                .animation(.easeOut(duration: 0.2), value: editor.isEmpty)

                if editor.rail == .recordings {
                    RecordingPanel(editor: editor)
                        .frame(width: 368)
                        .transition(.move(edge: .trailing))
                } else if editor.rail == .pages {
                    ContentManagerPanel(editor: editor)
                        .frame(width: 200)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.3), value: editor.rail)
        }
        .background(Theme.editorChrome)
        .sheet(isPresented: $editor.showPaperSheet) {
            PaperSheet(initial: editor.note.paper) { paper in editor.applyPaper(paper) }
        }
        .photosPicker(isPresented: $editor.showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { editor.addImage(data: data) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $editor.showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { editor.importPDF(from: url) }
        }
        .sheet(isPresented: $editor.showHandoff) {
            HandoffSheet(editor: editor)
        }
        .sheet(isPresented: $moving) {
            MoveToSubjectSheet(notes: [editor.note]) { moving = false }
        }
        .sheet(item: $sharePDF) { url in
            ShareSheet(items: [url])
        }
        .sheet(isPresented: Binding(get: { shareAudio != nil }, set: { if !$0 { shareAudio = nil } })) {
            ShareSheet(items: shareAudio ?? [])
        }
        .alert("Go to Page", isPresented: $editor.showGoToPage) {
            TextField("Page", text: $goToPageText).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Go") {
                if let n = Int(goToPageText) { editor.goToPage(n - 1) }
                goToPageText = ""
            }
        } message: {
            Text("1–\(editor.pageCount)")
        }
        .confirmationDialog("Delete “\(editor.note.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Note", role: .destructive) { model.delete(editor.note) }
        } message: {
            Text("It stays in Recently Deleted for 30 days.")
        }
        .alert(isPresented: Binding(get: { recorder.lastError != nil }, set: { if !$0 { recorder.lastError = nil } })) {
            Alert(title: Text("Recording"), message: Text(recorder.lastError ?? ""), dismissButton: .default(Text("OK")))
        }
        .onChange(of: ToolState.shared.current) { _, _ in editor.applyTool() }
        .onChange(of: AppSettings.shared.drawWithFinger) { _, on in editor.canvas.setDrawWithFinger(on) }
        .background {
            // Hardware keyboard: Space = play/pause (PRD §9).
            Button("") { editor.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
            Button("") { editor.undo() }.keyboardShortcut("z", modifiers: .command).opacity(0)
            Button("") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).opacity(0)
        }
    }

    // MARK: - Top chrome

    private var topBar: some View {
        // Toolbar centered in the space between the left and right groups, so nothing
        // overlaps when the library is open and the editor is narrow.
        HStack(spacing: 8) {
            ChromePill {
                ChromeIconButton(systemName: "sidebar.left", isActive: false, label: "Library") {
                    editor.flush()
                    model.libraryVisible.toggle()
                }
            }
            Spacer(minLength: 6)
            MainToolbar(editor: editor)
                .layoutPriority(1)
            Spacer(minLength: 6)
            ChromePill {
                ChromeIconButton(systemName: "arrow.uturn.backward", tint: editor.canUndo ? Theme.textPrimary : Theme.textTertiary,
                                 label: "Undo") { editor.undo() }
                    .disabled(!editor.canUndo)
                ChromeIconButton(systemName: "arrow.uturn.forward", tint: editor.canRedo ? Theme.textPrimary : Theme.textTertiary,
                                 label: "Redo") { editor.redo() }
                    .disabled(!editor.canRedo)
            }
            ChromePill {
                // Hand off to agent (Phase 3): one button → a link any agent can read, copied.
                ChromeIconButton(systemName: "paperplane", tint: Theme.accent, label: "Hand off to agent") {
                    editor.showHandoff = true
                }
                noteMenu
                ChromeIconButton(systemName: "waveform", isActive: editor.rail == .recordings,
                                 tint: editor.isRecordingHere ? Theme.recordRed : Theme.textPrimary,
                                 label: "Recordings") {
                    editor.rail = editor.rail == .recordings ? .none : .recordings
                }
                ChromeIconButton(systemName: "rectangle.portrait.on.rectangle.portrait", isActive: editor.rail == .pages,
                                 label: "Pages") {
                    editor.flush()
                    editor.rail = editor.rail == .pages ? .none : .pages
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(Theme.editorChrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1) }
    }

    /// Note ⋯ menu (PRD §6.4).
    private var noteMenu: some View {
        Menu {
            Button { exportPDF() } label: { Label("Share PDF", systemImage: "square.and.arrow.up") }
            Button { exportAudio() } label: { Label("Share Audio", systemImage: "waveform") }
                .disabled(!editor.note.recordings.contains { $0.duration > 0 })
            Button { editor.showPaperSheet = true } label: { Label("Paper…", systemImage: "doc.richtext") }
            Menu {
                ForEach(ViewMode.allCases) { mode in
                    Button { editor.setViewMode(mode) } label: {
                        if editor.currentViewMode == mode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                    }
                }
            } label: { Label("View", systemImage: "rectangle.stack") }
            Divider()
            Button { editor.canvas.beginEditingTitle() } label: { Label("Rename", systemImage: "pencil") }
            Button { moving = true } label: { Label("Move to…", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Note", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 42)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Note options")
    }

    /// Every recording in the note as .m4a, named "<note> - <recording>.m4a" (copies in tmp).
    private func exportAudio() {
        let fm = FileManager.default
        let note = editor.note
        let name = HandoffController.safeName(note.title)
        let dir = fm.temporaryDirectory.appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for rec in note.orderedRecordings where rec.duration > 0 {
            let src = NoteFiles.audioURL(noteID: note.id, recordingID: rec.id)
            let dst = dir.appendingPathComponent("\(name) - \(HandoffController.safeName(rec.name)).m4a")
            if (try? fm.copyItem(at: src, to: dst)) != nil { urls.append(dst) }
        }
        if !urls.isEmpty { shareAudio = urls }
    }

    private func exportPDF() {
        editor.flush()
        sharePDF = PDFExporter.export(note: editor.note, drawing: editor.canvas.drawing,
                                      pdf: editor.pdfDocument, elements: editor.elementSnapshots)
    }

    // MARK: - Sub-bar

    enum SubBarKind: Equatable { case none, tool(ToolKind), recording, playback }

    private var subBarKind: SubBarKind {
        let railShowsAudio = editor.rail == .recordings
        // An explicitly opened tool sub-bar wins, so pen colour and width stay reachable mid-recording.
        if editor.toolBarBeatsRecording && editor.subBarVisible && editor.tools.current.hasSubBar {
            return .tool(editor.tools.current)
        }
        if editor.isRecordingHere && !railShowsAudio { return .recording }
        if editor.playback.isEngaged && !railShowsAudio { return .playback }
        if editor.subBarVisible && editor.tools.current.hasSubBar { return .tool(editor.tools.current) }
        return .none
    }

    @ViewBuilder
    private var subBar: some View {
        switch subBarKind {
        case .none:
            EmptyView()
        case .tool(let tool):
            ToolSubBar(tool: tool, editor: editor)
        case .recording:
            RecordingBar(editor: editor)
        case .playback:
            PlaybackBar(editor: editor)
        }
    }
}

// MARK: - Canvas host

struct CanvasHost: UIViewRepresentable {
    let controller: CanvasController
    func makeUIView(context: Context) -> CanvasContainerView { controller.container }
    func updateUIView(_ uiView: CanvasContainerView, context: Context) {}
}

// MARK: - Page navigator (PRD §6.9)

struct PageNavigator: View {
    let editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            Button { editor.pageUp() } label: {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                    .frame(width: 38, height: 30)
            }
            .disabled(editor.visiblePage == 0)
            Button { editor.showGoToPage = true } label: {
                VStack(spacing: 1) {
                    Text("\(editor.visiblePage + 1)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Rectangle().fill(Theme.textTertiary).frame(width: 12, height: 1)
                    Text("\(editor.pageCount)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Page \(editor.visiblePage + 1) of \(editor.pageCount). Go to page.")
            Button { editor.pageDown() } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    .frame(width: 38, height: 30)
            }
            .disabled(editor.visiblePage >= editor.pageCount - 1)
        }
        .foregroundStyle(Theme.textSecondary)
        .buttonStyle(PressableStyle())
        .background(Capsule().fill(Theme.pill.opacity(0.94)))
        .overlay(Capsule().strokeBorder(Theme.pillBorder))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }
}

// MARK: - Empty-note paper footer (PRD §6.4 / §6.11)

struct PaperQuickPicker: View {
    let editor: EditorModel

    var body: some View {
        HStack(spacing: 4) {
            item("Rule", icon: "line.3.horizontal", style: .ruled)
            item("Grid", icon: "grid", style: .grid)
            item("Dot", icon: "circle.grid.3x3", style: .dot)
            Rectangle().fill(Theme.footerText.opacity(0.35)).frame(width: 1, height: 22).padding(.horizontal, 8)
            Button { editor.showPDFImporter = true } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .padding(.horizontal, 6)
            Button { editor.showPaperSheet = true } label: {
                Label("Templates", systemImage: "doc.text")
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.footerText)
        .buttonStyle(PressableStyle())
        .labelStyle(FooterLabelStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.92)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    private func item(_ title: String, icon: String, style: PaperStyle) -> some View {
        Button { editor.applyPaperStyle(style) } label: { Label(title, systemImage: icon) }
            .padding(.horizontal, 6)
            .foregroundStyle(editor.note.paper.style == style ? Theme.accent : Theme.footerText)
    }
}

private struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 14, weight: .regular))
            configuration.title
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
