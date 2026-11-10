import SwiftUI
import UIKit

/// One tap → a folder any agent can read: the notes as a PDF, a Markdown briefing (handwriting,
/// what was being said when each line was written, the transcripts) and the audio. Built and
/// shared entirely on the iPad; no account or server needed.
@MainActor @Observable final class HandoffController {
    enum Step: Int, CaseIterable {
        case reading, packaging
        var label: String {
            switch self {
            case .reading: "Reading your handwriting"
            case .packaging: "Packaging notes, transcript and audio"
            }
        }
    }

    enum State: Equatable {
        case working(Step)
        case ready(files: [URL], prompt: String)
        case failed(String)
    }

    private(set) var state: State = .working(.reading)
    private(set) var copied = false
    private var task: Task<Void, Never>?

    /// Starts a handoff unless one is already running (double taps, Try Again spam).
    func start(editor: EditorModel) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(editor: editor)
            self?.task = nil
        }
    }

    /// The sheet closed: stop, so a late finish can't overwrite the clipboard.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(editor: EditorModel) async {
        state = .working(.reading)
        copied = false
        let note = editor.note
        do {
            editor.flush()
            let timeline = NoteTimeline(note.orderedRecordings.filter { $0.duration > 0 }.map { ($0.id, $0.startedAt, $0.duration) })
            let drawing = editor.canvas.drawing
            let pdfURL = note.pdfBackgroundFile.map { NoteFiles.folder(note.id).appendingPathComponent($0) }
            let (noteID, title, paper, pages, elements) = (note.id, note.title, note.paper, editor.pageCount, editor.elementSnapshots)
            let build = Task.detached(priority: .userInitiated) {
                try await HandoffBuilder.build(noteID: noteID, title: title, paper: paper, pageCount: pages, drawing: drawing,
                                               pdf: pdfURL.flatMap { CGPDFDocument($0 as CFURL) }, elements: elements,
                                               timeline: timeline)
            }
            let package = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
            defer { try? FileManager.default.removeItem(at: package.folder) }
            try Task.checkCancellation()

            state = .working(.packaging)
            let files = try Self.writeFolder(note: note, editor: editor, package: package)
            try Task.checkCancellation()
            let prompt = Self.prompt(note: note, speakers: speakerNames(editor))
            state = .ready(files: files, prompt: prompt)
            copy(prompt)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// tmp/Handoff/<title>/: <title>.pdf, <title> briefing.md, and one .m4a per recording.
    private static func writeFolder(note: Note, editor: EditorModel, package: HandoffBuilder.Package) throws -> [URL] {
        let fm = FileManager.default
        let name = safeName(note.title)
        let dir = fm.temporaryDirectory.appendingPathComponent("Handoff", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let pdf = dir.appendingPathComponent("\(name).pdf")
        try fm.copyItem(at: package.pdfURL, to: pdf)

        var audio: [URL] = []
        for rec in note.orderedRecordings where rec.duration > 0 {
            let src = NoteFiles.audioURL(noteID: note.id, recordingID: rec.id)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dir.appendingPathComponent("\(name) - \(safeName(rec.name)).m4a")
            try fm.copyItem(at: src, to: dst)
            audio.append(dst)
        }

        let md = dir.appendingPathComponent("\(name) briefing.md")
        try briefing(note: note, editor: editor, package: package, audio: audio)
            .write(to: md, atomically: true, encoding: .utf8)
        return [md, pdf] + audio
    }

    private static func briefing(note: Note, editor: EditorModel, package: HandoffBuilder.Package, audio: [URL]) -> String {
        var out = "# \(note.title)\n\n"
        var context = note.createdAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        if let subject = note.subject?.name { context = "\(subject) · \(context)" }
        out += "\(context)\n\n"
        out += "Files: the handwritten pages as a PDF"
        if !audio.isEmpty { out += ", and the audio: " + audio.map { "`\($0.lastPathComponent)`" }.joined(separator: ", ") }
        out += ".\n\n"

        out += "## Handwritten notes\n\n"
        for (i, text) in package.pageText.enumerated() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "### Page \(i + 1)\n\n\(t.isEmpty ? "(no handwriting recognised)" : t)\n\n"
        }

        let timed = package.moments.filter { $0.tStart != nil && !$0.text.isEmpty }
        if !timed.isEmpty {
            out += "## When each note was written (time into the recording)\n\n"
            for m in timed { out += "- [\(clock(m.tStart!))] p\(m.page + 1): \(m.text)\n" }
            out += "\n"
        }

        for rec in note.orderedRecordings where rec.duration > 0 {
            out += "## Transcript: \(rec.name) (\(clock(rec.duration)))\n\n"
            if let t = editor.transcripts[rec.id], !t.segments.isEmpty {
                for seg in t.segments {
                    let who = seg.speaker.map { editor.speakerName(recordingID: rec.id, label: $0) + ": " } ?? ""
                    out += "[\(clock(seg.start))] \(who)\(seg.text.trimmingCharacters(in: .whitespaces))\n\n"
                }
            } else if let text = rec.transcriptText, !text.isEmpty {
                out += text + "\n\n"
            } else {
                out += "(no transcript yet — use the audio file)\n\n"
            }
        }
        return out
    }

    private static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    nonisolated static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Note" : String(cleaned.prefix(80))
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func speakerNames(_ editor: EditorModel) -> [String] {
        var names: [String] = []
        for rec in editor.note.orderedRecordings {
            for label in editor.transcripts[rec.id]?.speakers ?? [] {
                let n = editor.speakerName(recordingID: rec.id, label: label)
                if !n.hasPrefix("Speaker "), !names.contains(n) { names.append(n) }
            }
        }
        return names
    }

    /// Short, agent-agnostic prompt to paste with the shared files.
    static func prompt(note: Note, speakers: [String]) -> String {
        var context = note.createdAt.formatted(.dateTime.month(.abbreviated).day().year())
        if let subject = note.subject?.name { context = "\(subject) · \(context)" }
        if !speakers.isEmpty { context += " · with \(speakers.joined(separator: ", "))" }
        return """
        Here are my notes from a call — “\(note.title)” (\(context)).

        Read the briefing file first: it has my handwritten notes, what was being said when I wrote each one, and the transcript. The PDF is the pages and the .m4a is the audio.

        Pull out the decisions, action items (with owners and due dates), and open questions. Then help me with the next steps.
        """
    }
}

struct HandoffSheet: View {
    let editor: EditorModel
    @State private var controller = HandoffController()
    @State private var shareFiles: [URL]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hand off to agent")
                    .font(Theme.serif(21, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.fieldBackground))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 18)

            switch controller.state {
            case .working(let step):
                steps(current: step)
            case .ready(let files, let prompt):
                ready(files: files, prompt: prompt)
            case .failed(let message):
                failed(message)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
        // Size to content (steps → result) instead of a mostly-empty form sheet.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .onAppear { controller.start(editor: editor) }
        .onDisappear { controller.cancel() }
    }

    private func steps(current: HandoffController.Step) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(HandoffController.Step.allCases, id: \.self) { step in
                HStack(spacing: 12) {
                    ZStack {
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        } else if step == current {
                            ProgressView().controlSize(.small).tint(Theme.textSecondary)
                        } else {
                            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5).frame(width: 16, height: 16)
                        }
                    }
                    .frame(width: 22)
                    Text(step.label)
                        .font(.system(size: 15, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(step.rawValue <= current.rawValue ? Theme.textPrimary : Theme.textTertiary)
                }
            }
        }
    }

    private func ready(files: [URL], prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready. Prompt copied")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Share the files to Claude, ChatGPT, AirDrop or Files, then paste the prompt.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: url.pathExtension == "m4a" ? "waveform" :
                            url.pathExtension == "pdf" ? "doc.richtext" : "doc.text")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.noteList))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))

            HStack(spacing: 10) {
                actionButton("Share Files", systemImage: "square.and.arrow.up", primary: true) { shareFiles = files }
                actionButton("Copy Prompt", systemImage: "doc.on.doc") { controller.copy(prompt) }
            }
        }
        .sheet(isPresented: Binding(get: { shareFiles != nil }, set: { if !$0 { shareFiles = nil } })) {
            ShareSheet(items: shareFiles ?? [])
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.orange)
            actionButton("Try Again", systemImage: "arrow.clockwise", primary: true) {
                controller.start(editor: editor)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(primary ? Theme.accent : Theme.fieldBackground))
                .foregroundStyle(primary ? .white : Theme.textPrimary)
        }
        .buttonStyle(PressableStyle())
    }
}
