import OpenClickyKit
import SwiftUI

/// Home → Drawings: replies that drew something, re-rendered from their saved programs by the drawing engine.
struct HomeDrawingsView: View {
    @Environment(HomeServices.self) private var services

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)]

    var body: some View {
        let model = services.drawings
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent drawings").font(.title2.weight(.semibold))
                Spacer()
                Text("\(model.drawings.count) drawing\(model.drawings.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.drawings.isEmpty {
                ContentUnavailableView("No drawings yet", systemImage: "scribble.variable",
                                       description: Text("When OpenClicky draws on your screen to explain something, the drawing shows up here."))
            } else {
                if let selected = model.selected {
                    DrawingDetail(drawing: selected, image: model.thumbnails[selected.id]) { model.selectedID = nil }
                }
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(model.drawings) { drawing in
                            DrawingCard(drawing: drawing, image: model.thumbnails[drawing.id], failure: model.failures[drawing.id],
                                        selected: drawing.id == model.selectedID)
                                .onTapGesture { model.selectedID = drawing.id }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.reload() }
    }
}

private struct DrawingCard: View {
    let drawing: HistoryDrawing
    let image: NSImage?
    let failure: String?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.1))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if failure != nil {
                    Label("Couldn't redraw", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            Text(drawing.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text(HomeFormat.relative(drawing.createdAt) + (drawing.spokenLines.isEmpty ? "" : " · \(drawing.spokenLines.count) line\(drawing.spokenLines.count == 1 ? "" : "s")"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var aspect: CGFloat {
        guard let canvas = drawing.canvas, canvas.height > 0 else { return 1280.0 / 832.0 }
        return canvas.width / canvas.height
    }
}

private struct DrawingDetail: View {
    let drawing: HistoryDrawing
    let image: NSImage?
    let close: () -> Void
    @ViewState private var replay = LessonReplayModel()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    if let frame = replay.frame ?? image {
                        Image(nsImage: frame)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    if let caption = replay.caption {
                        Text(caption)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.62)))
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    Button(replay.isPlaying ? "Stop" : "Replay") {
                        if replay.isPlaying { replay.stop() } else { replay.play(drawing) }
                    }
                    .controlSize(.small)
                    if let problem = replay.problem {
                        Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if drawing.lessonFolder != nil {
                        Text("Saved lesson").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: drawing.id) { replay.reset() }
            .onDisappear { replay.stop() }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(drawing.title).font(.headline)
                    Spacer()
                    Button("Close", action: close).buttonStyle(.borderless)
                }
                Text(drawing.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(drawing.spokenLines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(line).font(.callout)
                    }
                }
                Button("Copy program") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(drawing.program, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }
}

/// Plays a saved drawing in the detail panel: `DrawingLessonReplay` reruns its program at the pace its lines were heard
/// (or an average speaking rate), over the stored screenshot when the lesson kept one, with the lines as captions.
/// Frames are composited offscreen about twelve times a second; there is no sound.
@MainActor
@Observable
final class LessonReplayModel {
    private(set) var frame: NSImage?
    private(set) var caption: String?
    private(set) var isPlaying = false
    private(set) var problem: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Which `play` the running task belongs to: a cancelled replay winding down must not touch the next one's state.
    @ObservationIgnored private var generation = 0

    func play(_ drawing: HistoryDrawing) {
        stop()
        problem = nil
        let replay: DrawingLessonReplay
        do {
            replay = try Self.replay(for: drawing)
        } catch {
            problem = "Couldn't replay: \(error)"
            return
        }
        isPlaying = true
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                replay.advance(to: Date().timeIntervalSince(started))
                guard let self else { return }
                self.show(replay)
                if replay.isDone { break }
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard let self, self.generation == mine else { return }
            self.isPlaying = false
            self.caption = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isPlaying = false
        caption = nil
    }

    /// Another drawing was chosen: stop, and drop this one's last replay frame and problem so the new drawing's
    /// thumbnail shows.
    func reset() {
        stop()
        frame = nil
        problem = nil
    }

    private func show(_ replay: DrawingLessonReplay) {
        if let image = try? replay.frame(maxWidth: 720) {
            frame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        caption = replay.caption()?.text
    }

    /// The saved lesson when there is one; otherwise the history's program and lines on a plain card.
    static func replay(for drawing: HistoryDrawing) throws -> DrawingLessonReplay {
        if let folder = drawing.lessonFolder {
            let store = DrawingLessonStore(historyDirectory: folder.deletingLastPathComponent().deletingLastPathComponent())
            if let lesson = store.load(folder: folder) {
                return try DrawingLessonReplay(lesson: lesson, screenshot: store.screenshot(folder: folder))
            }
        }
        let canvas = drawing.canvas ?? DrawingThumbnailer.defaultCanvas
        let lesson = DrawingLesson(turnID: drawing.turnID, sessionID: drawing.sessionID, createdAt: drawing.createdAt, question: drawing.question,
                                   program: drawing.program, canvas: canvas,
                                   lines: drawing.spokenLines.enumerated().map { DrawingLesson.Line(index: $0.offset, text: $0.element) })
        return try DrawingLessonReplay(lesson: lesson, screenshot: nil)
    }
}
