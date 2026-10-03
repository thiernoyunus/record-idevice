import SwiftUI
import AVKit
import AppKit

struct EditorView: View {
    @ObservedObject var editor: EditorState
    @EnvironmentObject var engine: CaptureEngine
    @State private var confirmTrash = false
    @State private var addingScene = false
    @State private var hexDraft = "#FFFFFF"
    @State private var sceneDragBase: [UUID: Double] = [:]
    @State private var sceneDurationBase: [UUID: Double] = [:]
    @State private var lookOpen = false
    @State private var cameraSelected = false
    @State private var timelineHeightBase: CGFloat?
    @State private var timelineScrollMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var showShortcuts = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                stage
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                switch editor.mode {
                case .edit:
                    editorToolbar
                    ZoomInspector(editor: editor)
                    timelineDeck
                case .scenes:
                    sceneHeader
                    sceneTimeline
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
            }
            if lookOpen {
                Color.clear.frame(width: Frame.panelWidth)
            }
        }
        .background(Frame.bg)
        .preferredColorScheme(.light)
        .overlay(alignment: .trailing) {
            if lookOpen {
                LookPanel(
                    engine: engine,
                    showsCamera: editor.hasCamera,
                    showsMic: editor.hasMic,
                    cameraStatus: editor.cameraClipStatus,
                    phoneMix: $editor.phoneMix,
                    micMix: $editor.micMix,
                    onChange: {
                        editor.applyPlaybackVolumes()
                        editor.refreshPreview(immediate: true)
                    },
                    onClose: { lookOpen = false }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: lookOpen)
        .overlay { if let p = editor.exportProgress { exportOverlay(p) } }
        .frame(minWidth: 1060, minHeight: 700)
        .onAppear {
            hexDraft = hexString(from: (
                engine.customBackgroundRGB?[safe: 0] ?? 1,
                engine.customBackgroundRGB?[safe: 1] ?? 1,
                engine.customBackgroundRGB?[safe: 2] ?? 1
            ))
            timelineScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard event.modifierFlags.contains(.command) else { return event }
                // Trackpad momentum and sideways swipes send ~0 vertical
                // deltas; treating those as "zoom out" made the ruler jump.
                let delta = event.scrollingDeltaY
                guard abs(delta) > 0.2 else { return nil }
                editor.bumpTimelineZoom(delta > 0 ? 1.12 : 1 / 1.12)
                return nil
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKey(event) ? nil : event
            }
        }
        .onDisappear {
            if let timelineScrollMonitor {
                NSEvent.removeMonitor(timelineScrollMonitor)
            }
            timelineScrollMonitor = nil
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
        .confirmationDialog("Move this recording to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let dir = editor.dir
                editor.close()
                engine.trashProject(at: dir)
            }
        } message: {
            Text("The raw recordings, edits, and any exports in this project folder go to the Trash.")
        }
    }

    // MARK: - Editor

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            Button { editor.close() } label: {
                Label("Home", systemImage: "house")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Frame.label)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Frame.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Back to your clips")

            Spacer()

            if editor.cameraClipStatus == .wantedButMissing {
                Text("Camera was on — clip didn’t save")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Frame.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }

            Button {
                lookOpen.toggle()
                if lookOpen, editor.hasCamera { cameraSelected = true }
            } label: {
                Text("Look")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(lookOpen ? .white : Frame.label)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(lookOpen ? Frame.accent : Frame.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(lookOpen ? Color.clear : Frame.pillStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Same look controls as before you recorded")

            Button { confirmTrash = true } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Frame.delete)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Frame.delete.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - Keyboard (editor-style shortcuts)

    static let shortcuts: [(String, String)] = [
        ("Space", "Play / pause"),
        ("← →", "Step one frame"),
        ("⇧← ⇧→", "Jump one second"),
        ("↑ / Home", "Go to start"),
        ("↓ / End", "Go to end"),
        ("Q", "Trim start to playhead"),
        ("W", "Trim end to playhead"),
        ("Z", "Add zoom at playhead"),
        ("⌫", "Delete selected zoom / scene"),
        ("⌘=  ⌘-", "Zoom timeline in / out"),
        ("⌘0", "Fit timeline"),
        ("Pinch / ⌘ scroll", "Zoom timeline"),
        ("⌘Z  ⇧⌘Z", "Undo / redo"),
    ]

    /// Returns true when the key was used. Never steals typing: text fields,
    /// sheets and dialogs get their keys untouched.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow,
              window.attachedSheet == nil,
              !(window.firstResponder is NSText) else { return false }
        guard editor.isReady, editor.exportProgress == nil else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == [.command] || mods == [.command, .shift] {
            switch chars {
            case "=", "+": editor.bumpTimelineZoom(1.25); return true
            case "-", "_": editor.bumpTimelineZoom(1 / 1.25); return true
            case "0": editor.setTimelineZoom(1); return true
            default: return false
            }
        }
        guard mods.isEmpty || mods == [.shift] else { return false }
        let bigStep = mods == [.shift]
        switch event.keyCode {
        case 49: editor.togglePlay(); return true                           // space
        case 123: editor.nudge(by: bigStep ? -1 : -EditorState.frameStep); return true  // ←
        case 124: editor.nudge(by: bigStep ? 1 : EditorState.frameStep); return true    // →
        case 115, 126: editor.jumpToStart(); return true                    // home, ↑
        case 119, 125: editor.jumpToEnd(); return true                      // end, ↓
        case 51, 117:                                                       // ⌫, ⌦
            if editor.mode == .scenes, editor.selectedSceneID != nil {
                editor.deleteSelectedScene(); return true
            }
            if editor.selectedZoomID != nil {
                editor.deleteSelectedZoom(); return true
            }
            return false
        default:
            break
        }
        guard mods.isEmpty, editor.mode == .edit else { return false }
        switch chars {
        case "q": editor.trimStartAtPlayhead(); return true
        case "w": editor.trimEndAtPlayhead(); return true
        case "z": editor.addZoom(); return true
        default: return false
        }
    }

    private func pickAndExport() {
        let settings = AppSettings.shared
        switch settings.exportPlace {
        case .ask:
            if let url = EditorState.askWhereToSave(suggestedName: "Recording.mp4",
                                                    startingIn: settings.lastExportDirectory) {
                settings.rememberExportDirectory(url)
                editor.export(to: url)
            }
        case .recordingFolder:
            editor.export(to: editor.nextExportURL(in: editor.dir))
        case .customFolder:
            let folder = settings.customFolderURL ?? editor.dir
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            editor.export(to: editor.nextExportURL(in: folder))
        }
    }

    // MARK: - Scene editor

    private var sceneHeader: some View {
        HStack {
                Button { editor.mode = .edit } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Frame.label)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Frame.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(spacing: 2) {
                    Text("Scene Editor").font(.system(size: 13, weight: .semibold)).foregroundStyle(Frame.label)
                    Text("Arrange what viewers see. Trim and playback settings are unchanged.")
                        .font(.system(size: 11)).foregroundStyle(Frame.tertiary)
                }
                Spacer()
                Button { editor.mode = .edit } label: {
                    Label("Done", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Frame.save, in: Capsule())
                }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var sceneTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                jumpToStartButton
                playButton
                transportClock
                Spacer()
            }
            GeometryReader { geo in
                let pps = geo.size.width / max(editor.duration, 0.1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Frame.hairline))
                    if editor.scenes.isEmpty {
                        Text("Drag to add a scene")
                            .font(.system(size: 12))
                            .foregroundStyle(Frame.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(editor.scenes) { clip in
                        sceneChip(clip, pps: pps)
                    }
                    ScenePlayhead(clock: editor.clock, pps: pps)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 6).onChanged { value in
                    editor.seekRaw(to: value.location.x / pps)
                })
                .contextMenu {
                    Button("Camera") { addScene(.camera) }
                    if editor.hasPhone {
                        Button("Camera + Device") { addScene(.both) }
                        Button("Device") { addScene(.device) }
                    }
                }
                .onTapGesture { } // keep context menu
            }
            .frame(height: 64)
            HStack {
                ForEach(SceneKind.allCases.filter { editor.hasPhone || $0 == .camera }) { kind in
                    Button { addScene(kind) } label: {
                        Text(kind.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Frame.label)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.black.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let scene = editor.scenes.first(where: { $0.id == editor.selectedSceneID }) {
                    Text("Drag the ends to make it longer")
                        .font(.system(size: 11))
                        .foregroundStyle(Frame.tertiary)
                    Slider(value: Binding(
                        get: { scene.duration },
                        set: { v in
                            var next = scene
                            let sized = SceneTiming.resize(start: scene.start, duration: scene.duration,
                                                           delta: v - scene.duration, leading: false,
                                                           timeline: editor.duration)
                            next.start = sized.start
                            next.duration = sized.duration
                            editor.updateScene(next, rebuild: false)
                        }
                    ), in: SceneTiming.minDuration...max(SceneTiming.minDuration, editor.duration - scene.start)) { editing in
                        if !editing, let current = editor.scenes.first(where: { $0.id == scene.id }) {
                            editor.updateScene(current, rebuild: true)
                        }
                    }
                    .frame(maxWidth: 180)
                    Button("Remove scene") { editor.deleteSelectedScene() }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Frame.delete)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Frame.hairline))
    }

    private func addScene(_ kind: SceneKind) {
        let start = editor.currentTime
        let remaining = max(1, editor.duration - start)
        editor.addScene(kind: kind, start: start, duration: min(4, remaining))
    }

    private func sceneChip(_ clip: SceneClip, pps: CGFloat) -> some View {
        let on = editor.selectedSceneID == clip.id
        let width = max(56, clip.duration * pps)
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(on ? Frame.accent.opacity(0.18) : Color.black.opacity(0.06))
            Text("\(clip.kind.rawValue)  \(String(format: "%.1fs", clip.duration))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Frame.label)
                .lineLimit(1)
            HStack {
                Capsule().fill(Color.black.opacity(0.35)).frame(width: 3, height: 16)
                Spacer()
                Capsule().fill(Color.black.opacity(0.35)).frame(width: 3, height: 16)
            }
            .padding(.horizontal, 5)
        }
        .frame(width: width, height: 36)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(on ? Frame.accent : Color.clear, lineWidth: 1)
        )
        .offset(x: clip.start * pps)
        .onTapGesture {
            editor.selectedSceneID = clip.id
            editor.seek(to: clip.start + 0.1)
        }
        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
            if sceneDragBase[clip.id] == nil { sceneDragBase[clip.id] = clip.start }
            let moved = SceneTiming.move(start: sceneDragBase[clip.id] ?? clip.start,
                                         duration: clip.duration,
                                         delta: value.translation.width / pps,
                                         timeline: editor.duration)
            var c = clip
            c.start = moved.start
            c.duration = moved.duration
            editor.updateScene(c, rebuild: false)
        }.onEnded { _ in
            if let current = editor.scenes.first(where: { $0.id == clip.id }) {
                editor.updateScene(current, rebuild: true)
            }
            sceneDragBase[clip.id] = nil
        })
        .overlay(alignment: .leading) {
            Color.clear.frame(width: 12, height: 36).contentShape(Rectangle())
                .highPriorityGesture(sceneResize(clip, pps: pps, leading: true))
        }
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 12, height: 36).contentShape(Rectangle())
                .highPriorityGesture(sceneResize(clip, pps: pps, leading: false))
        }
        .help("Drag the middle to move. Drag either end to make this scene longer or shorter.")
    }

    private func sceneResize(_ clip: SceneClip, pps: CGFloat, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            if sceneDragBase[clip.id] == nil {
                sceneDragBase[clip.id] = clip.start
                sceneDurationBase[clip.id] = clip.duration
            }
            let sized = SceneTiming.resize(start: sceneDragBase[clip.id] ?? clip.start,
                                           duration: sceneDurationBase[clip.id] ?? clip.duration,
                                           delta: value.translation.width / pps,
                                           leading: leading,
                                           timeline: editor.duration)
            var c = clip
            c.start = sized.start
            c.duration = sized.duration
            editor.updateScene(c, rebuild: false)
        }.onEnded { _ in
            if let current = editor.scenes.first(where: { $0.id == clip.id }) {
                editor.updateScene(current, rebuild: true)
            }
            sceneDragBase[clip.id] = nil
            sceneDurationBase[clip.id] = nil
        }
    }

    // MARK: - Stage

    private var stage: some View {
        GeometryReader { geo in
            let ratio = engine.canvas.size(phoneAspect: engine.phoneAspect).width
                / engine.canvas.size(phoneAspect: engine.phoneAspect).height
            let maxW = max(0, geo.size.width - 16)
            let maxH = max(0, geo.size.height - 8)
            let fitW = min(maxW, maxH * ratio)
            let fitH = ratio > 0 ? max(0, fitW) / ratio : 0
            ZStack {
                if editor.isReady {
                    DualReviewCanvas(
                        editor: editor,
                        clock: editor.clock,
                        engine: engine,
                        cameraSelected: $cameraSelected
                    )
                } else if editor.loadFailed == nil {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Opening recording…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Frame.secondary)
                    }
                }
                if let failure = editor.loadFailed {
                    VStack(spacing: 10) {
                        Text("Couldn’t open this take")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Frame.label)
                        Text(failure)
                            .font(.system(size: 13))
                            .foregroundStyle(Frame.secondary)
                            .multilineTextAlignment(.center)
                        Button("Back to Home") { editor.close() }
                            .buttonStyle(.borderedProminent)
                            .tint(Frame.accent)
                    }
                    .padding(24)
                }
            }
            .frame(width: fitW, height: fitH)
            .background(stageFill)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var stageFill: some View {
        CanvasBackdrop(customRGB: engine.customBackgroundRGB, preset: engine.background,
                       time: editor.currentTime, playing: editor.isPlaying)
    }

    // MARK: - Transport + timeline

    private var playButton: some View {
        Button { editor.togglePlay() } label: {
            Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Frame.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .help(editor.isPlaying ? "Pause (Space)" : "Play (Space)")
    }

    private var jumpToStartButton: some View {
        Button { editor.jumpToStart() } label: {
            Image(systemName: "backward.end.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Frame.label)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to start")
    }

    private var transportClock: some View {
        TransportClock(clock: editor.clock, trimStart: editor.trimStart,
                       trimEnd: editor.trimEnd)
    }

    private func deckIcon(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Frame.label)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var timelineTools: some View {
        HStack(spacing: 6) {
            deckIcon(editor.timelineHidden
                     ? "rectangle.bottomhalf.inset.filled"
                     : "rectangle.bottomhalf.filled",
                     help: editor.timelineHidden ? "Show timeline" : "Hide timeline") {
                editor.timelineHidden.toggle()
            }
            deckIcon("keyboard", help: "Keyboard shortcuts") {
                showShortcuts.toggle()
            }
            .popover(isPresented: $showShortcuts, arrowEdge: .top) {
                shortcutsCard
            }
            deckIcon("arrow.left.and.right.square", help: "Fit timeline (⌘0)") {
                editor.setTimelineZoom(1)
            }
            deckIcon("minus.magnifyingglass", help: "Zoom out (⌘-)") {
                editor.bumpTimelineZoom(1 / 1.25)
            }
            Slider(value: Binding(
                get: { TimelineZoomScale.sliderValue(zoom: editor.timelineZoom,
                                                     maxZoom: EditorState.maxTimelineZoom) },
                set: { editor.setTimelineZoom(TimelineZoomScale.zoom(
                    sliderValue: $0, maxZoom: EditorState.maxTimelineZoom)) }
            ), in: 0...1)
            .controlSize(.mini)
            .tint(Frame.accent)
            .frame(width: 96)
            .help("Timeline zoom — or pinch / hold ⌘ and scroll")
            deckIcon("plus.magnifyingglass", help: "Zoom in (⌘=)") {
                editor.bumpTimelineZoom(1.25)
            }
            Button { editor.addZoom() } label: {
                Label("Add Zoom", systemImage: "plus.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Frame.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!editor.isReady)
            Button { editor.mode = .scenes } label: {
                Text("Scenes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Frame.label)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.black.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var timelineDeck: some View {
        VStack(alignment: .leading, spacing: 8) {
            timelineResizeHandle
            ZStack {
                HStack(alignment: .center, spacing: 8) {
                    jumpToStartButton
                    transportClock
                    Spacer(minLength: 8)
                    timelineTools
                }
                playButton
            }
            .frame(height: 48)
            if !editor.timelineHidden {
                TimelineScroller(editor: editor)
                    .frame(height: editor.timelineHeight)
            }
            editorChromeBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(Rectangle().fill(Frame.hairline).frame(height: 1), alignment: .top)
    }

    private var timelineResizeHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.black.opacity(0.18))
                .frame(width: 36, height: 4)
            Spacer()
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if timelineHeightBase == nil { timelineHeightBase = editor.timelineHeight }
                    let next = (timelineHeightBase ?? 248) - value.translation.height
                    editor.timelineHeight = min(420, max(96, next))
                    if editor.timelineHeight <= 100 { editor.timelineHidden = false }
                }
                .onEnded { _ in timelineHeightBase = nil }
        )
        .help("Drag to make the timeline taller or shorter")
    }

    private var editorChromeBar: some View {
        let canvasSize = engine.canvas.size(phoneAspect: engine.phoneAspect)
        return HStack(spacing: 10) {
            chromeMenu(title: "Canvas", value: "\(Int(canvasSize.width)) × \(Int(canvasSize.height))") {
                ForEach(CanvasPreset.allCases) { preset in
                    Button(preset.displayTitle) {
                        engine.canvas = preset
                        editor.refreshPreview(immediate: true)
                    }
                }
            }
            chromeMenu(title: "Fit", value: engine.phoneScale > 0.86 ? "Fill" : "Fit") {
                Button("Fit") {
                    engine.phoneScale = 0.78
                    editor.refreshPreview(immediate: true)
                }
                Button("Fill") {
                    engine.phoneScale = ExportLayout.phoneScaleMax
                    editor.refreshPreview(immediate: true)
                }
            }
            chromeMenu(title: "Style", value: styleName) {
                ForEach(SolidSwatch.styleMenu) { swatch in
                    Button(swatch.name) {
                        engine.wallpaperID = nil
                        engine.customBackgroundRGB = [swatch.rgb.0, swatch.rgb.1, swatch.rgb.2]
                        editor.refreshPreview(immediate: true)
                    }
                }
                Divider()
                ForEach(WallpaperCatalog.live) { paper in
                    Button(paper.name) {
                        engine.wallpaperID = paper.id
                        editor.refreshPreview(immediate: true)
                    }
                }
                ForEach(WallpaperCatalog.stills.prefix(8)) { paper in
                    Button(paper.name) {
                        engine.wallpaperID = paper.id
                        editor.refreshPreview(immediate: true)
                    }
                }
            } trailing: {
                styleSwatch
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
            }
            Spacer()
            Button { pickAndExport() } label: {
                Label("Save", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Frame.save, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!editor.isReady)
            .help("Save the finished movie")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Frame.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
    }

    private var styleName: String {
        if let paper = WallpaperCatalog.paper(id: engine.wallpaperID) {
            return paper.name
        }
        let rgb = (
            engine.customBackgroundRGB?[safe: 0] ?? 1,
            engine.customBackgroundRGB?[safe: 1] ?? 1,
            engine.customBackgroundRGB?[safe: 2] ?? 1
        )
        if let named = (SolidSwatch.styleMenu + SolidSwatch.pastels + SolidSwatch.solids)
            .first(where: {
                abs($0.rgb.0 - rgb.0) < 0.04 && abs($0.rgb.1 - rgb.1) < 0.04 && abs($0.rgb.2 - rgb.2) < 0.04
            }) {
            return named.name
        }
        return "Custom"
    }

    @ViewBuilder
    private var styleSwatch: some View {
        if let id = engine.wallpaperID, let image = WallpaperCatalog.nsImage(id: id) {
            WallpaperFill(image: image, corner: 5)
        } else {
            Color(red: engine.customBackgroundRGB?[safe: 0] ?? 1,
                  green: engine.customBackgroundRGB?[safe: 1] ?? 1,
                  blue: engine.customBackgroundRGB?[safe: 2] ?? 1)
        }
    }

    private func chromeMenu<C: View, T: View>(
        title: String, value: String, @ViewBuilder content: () -> C, @ViewBuilder trailing: () -> T
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 6) {
                Text("\(title)  \(value)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Frame.label)
                trailing()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Frame.tertiary)
            }
        }
        .menuIndicator(.hidden)
        .tint(Frame.label)
        .fixedSize()
    }

    private func chromeMenu<C: View>(title: String, value: String, @ViewBuilder content: () -> C) -> some View {
        chromeMenu(title: title, value: value, content: content, trailing: { EmptyView() })
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard shortcuts")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 2)
            ForEach(Self.shortcuts, id: \.0) { item in
                HStack {
                    Text(item.0)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 120, alignment: .leading)
                    Text(item.1).font(.system(size: 12))
                }
            }
        }
        .padding(14)
    }

    private func exportOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 14) {
                if editor.exportSucceeded || progress >= 0.999 {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(Frame.export)
                    Text("Exported").font(.headline)
                    Text(editor.exportedURL?.lastPathComponent ?? "Finishing…")
                        .font(.callout).foregroundStyle(Frame.secondary)
                } else {
                    ProgressView(value: progress).frame(width: 240).tint(Frame.accent)
                    Text("Exporting… \(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Button("Cancel") { editor.cancelExport() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Frame.secondary)
                }
            }
            .padding(28)
            .background(Frame.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 24)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Phone + camera as two layers — same layout as the live window.
/// Avoids AVPlayer's custom compositor, which freezes the Mac.
private struct DualReviewCanvas: View {
    @ObservedObject var editor: EditorState
    /// The stage animates zooms / scene cuts, so it redraws on every tick.
    @ObservedObject var clock: PlayheadClock
    @ObservedObject var engine: CaptureEngine
    @Binding var cameraSelected: Bool
    @State private var resizeStart: CGFloat?
    @State private var hoveringCamera = false
    @AppStorage("recordidevice.didMoveCameraTip") private var didMoveCameraTip = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let layout: ExportLayout = {
                var next = engine.currentLayout()
                next.scenes = editor.scenes
                return next
            }()
            let kind = layout.scene(at: editor.currentTime)
            let showPhone = kind != .camera && editor.hasPhone && layout.hasPhoneSource
            let showCamera = kind != .device && engine.cameraEnabled && editor.hasCamera
            let dest = layout.soloCentered(showPhone: showPhone, showCamera: showCamera)
            let appear = ExportLayout.appearanceProgress(at: editor.currentTime, layout: layout)
            let placed = layout.blended(toward: dest, progress: appear)
            let isSplit = placed.presenterLayout == .split
            let t = editor.currentTime
            let selected = editor.selectedZoom
            let aiming = selected != nil && !editor.isPlaying
            let activeZoom = editor.zooms
                .filter { t >= $0.start && t <= $0.end }
                .max(by: { $0.scale(at: t) < $1.scale(at: t) })
            let zoomScale = aiming ? 1 : (activeZoom?.scale(at: t) ?? 1)
            let phoneCenter = (aiming ? selected?.center : activeZoom?.center)
                ?? CGPoint(x: 0.5, y: 0.45)
            let presented = editor.player.currentItem?.presentationSize ?? .zero
            let phoneAspect = presented.height > 1
                ? presented.width / presented.height
                : max(engine.phoneAspect, 0.3)
            let screen = CanvasDraw.phoneScreenRect(
                canvas: size, layout: placed, phoneAspect: phoneAspect)
            let canvasAim = CanvasDraw.canvasUnit(
                fromPhone: phoneCenter, screen: screen, canvas: size)
            ZStack {
                canvasFill
                    .contentShape(Rectangle())
                    .onTapGesture { cameraSelected = false }
                if isSplit {
                    ZStack {
                        if showPhone {
                            phoneLayer(screen: screen, zoomScale: 1,
                                       zoomAnchor: .center, aiming: aiming)
                        }
                        if showCamera {
                            cameraLayer(in: size, layout: placed, lockedCenter: !showPhone)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoomScale, anchor: UnitPoint(x: canvasAim.x, y: canvasAim.y))
                } else {
                    if showPhone {
                        phoneLayer(screen: screen,
                                   zoomScale: zoomScale,
                                   zoomAnchor: UnitPoint(x: phoneCenter.x, y: phoneCenter.y),
                                   aiming: aiming)
                    }
                    if showCamera {
                        cameraLayer(in: size, layout: placed, lockedCenter: !showPhone)
                    }
                }
            }
            .coordinateSpace(name: "reviewCanvas")
        }
    }

    private var canvasFill: some View {
        CanvasBackdrop(customRGB: engine.customBackgroundRGB, preset: engine.background,
                       wallpaperID: engine.wallpaperID,
                       time: editor.currentTime, playing: editor.isPlaying)
    }

    private func phoneLayer(screen: CGRect, zoomScale: CGFloat,
                            zoomAnchor: UnitPoint, aiming: Bool) -> some View {
        let w = screen.width
        let h = screen.height
        let selected = editor.selectedZoom
        return FramedPhoneChrome(
            width: w,
            height: h,
            style: engine.frameStyle,
            showBezel: engine.frameStyle.showsBezel,
            screenCorners: engine.screenCorners
        ) {
            PlayerContainerView(player: editor.player, gravity: .resizeAspectFill)
                .id("phone-player")
                .allowsHitTesting(false)
        }
        .scaleEffect(zoomScale, anchor: zoomAnchor)
        .overlay {
            if aiming, let selected {
                Circle()
                    .strokeBorder(Frame.accent, lineWidth: 2)
                    .background(Circle().fill(Frame.accent.opacity(0.18)))
                    .frame(width: 22, height: 22)
                    .position(x: selected.center.x * w, y: selected.center.y * h)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard let id = editor.selectedZoomID, !editor.isPlaying else { return }
            editor.setZoomCenter(id, center: CGPoint(
                x: value.location.x / max(w, 1),
                y: value.location.y / max(h, 1)))
        }.onEnded { _ in
            if editor.selectedZoomID != nil { editor.refreshPreview(immediate: true) }
        })
        .position(x: screen.midX, y: screen.midY)
    }

    private func cameraLayer(in size: CGSize, layout: ExportLayout, lockedCenter: Bool) -> some View {
        let frac = min(max(layout.bubbleFraction, ExportLayout.bubbleMin), ExportLayout.bubbleMax)
        let aspect: CGFloat = engine.cameraShape == .rectangle ? 4 / 5 : 1
        let (w, h, center, corner): (CGFloat, CGFloat, CGPoint, CGFloat) = {
            switch layout.presenterLayout {
            case .floating:
                let s = frac * min(size.width, size.height)
                let cr: CGFloat = engine.cameraShape == .circle ? 0.5
                    : (engine.cameraShape == .square ? 0.18 : 0.14)
                return (s * aspect, s, layout.bubbleCenter, cr)
            case .split:
                let zone = ExportLayout.splitZones(canvas: size, layout: layout).camera
                let fit = min(zone.width / aspect, zone.height) * 0.92
                let cr: CGFloat = engine.cameraShape == .circle ? 0.5 : 0.10
                return (fit * aspect, fit,
                        CGPoint(x: zone.midX / size.width, y: zone.midY / size.height), cr)
            }
        }()
        let ring = engine.ringRGB
        let ringColor = Color(red: ring.indices.contains(0) ? ring[0] : 1,
                              green: ring.indices.contains(1) ? ring[1] : 1,
                              blue: ring.indices.contains(2) ? ring[2] : 1)
        let highlighted = cameraSelected || hoveringCamera
        return PlayerContainerView(player: editor.cameraPlayer, gravity: .resizeAspectFill)
            .allowsHitTesting(false)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: max(2, min(w, h) * 0.018))
            )
            .overlay {
                RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous)
                    .strokeBorder(highlighted ? Frame.accent : Color.white.opacity(0.35),
                                  lineWidth: cameraSelected ? 2.5 : 1.5)
            }
            .overlay { resizeHandles(canvas: size, width: w, height: h,
                                     floating: layout.presenterLayout == .floating,
                                     lockedCenter: lockedCenter) }
            .background {
                RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous)
                    .fill(Color.black.opacity(0.001))
            }
            .overlay {
                if engine.showBorder {
                    RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { hoveringCamera = $0 }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("reviewCanvas"))
                    .onChanged { value in
                        cameraSelected = true
                        guard !lockedCenter, layout.presenterLayout == .floating else { return }
                        engine.bubbleCenter = CGPoint(
                            x: min(max(value.location.x / max(size.width, 1), 0.08), 0.92),
                            y: min(max(value.location.y / max(size.height, 1), 0.08), 0.92))
                    }
                    .onEnded { _ in
                        didMoveCameraTip = true
                        editor.commitBubbleMove()
                    }
            )
            .onTapGesture { cameraSelected = true }
            .help(layout.presenterLayout == .floating && !lockedCenter ? "Drag to move the camera" : "Camera")
            .position(x: center.x * size.width, y: center.y * size.height)
    }

    @ViewBuilder
    private func resizeHandles(canvas: CGSize, width: CGFloat, height: CGFloat,
                               floating: Bool, lockedCenter: Bool) -> some View {
        if cameraSelected, floating, !lockedCenter {
            let corners: [Alignment] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
            ForEach(Array(corners.enumerated()), id: \.offset) { _, align in
                handleDot
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
                    .offset(x: align == .topLeading || align == .bottomLeading ? -5 : 5,
                            y: align == .topLeading || align == .topTrailing ? -5 : 5)
                    .highPriorityGesture(resizeGesture(canvas: canvas, invert: align == .topLeading))
            }
        }
    }

    private var handleDot: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Frame.accent, lineWidth: 2))
            .frame(width: 12, height: 12)
    }

    private func resizeGesture(canvas: CGSize, invert: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                cameraSelected = true
                if resizeStart == nil { resizeStart = engine.bubbleFraction }
                let raw = (value.translation.width + value.translation.height) / 2
                let delta = invert ? -raw : raw
                let next = (resizeStart ?? engine.bubbleFraction)
                    + delta / max(min(canvas.width, canvas.height), 1)
                engine.bubbleFraction = min(max(next, ExportLayout.bubbleMin), ExportLayout.bubbleMax)
            }
            .onEnded { _ in
                resizeStart = nil
                didMoveCameraTip = true
                editor.commitBubbleMove()
            }
    }

}

/// Plain player layer — AVPlayerView can steal the audio device so the
/// iPhone player goes silent when the camera player is also on screen.
private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.player = player
        v.gravity = gravity
        return v
    }
    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        nsView.player = player
        nsView.gravity = gravity
    }
}

final class PlayerLayerNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }

    var gravity: AVLayerVideoGravity = .resizeAspectFill {
        didSet { (layer as? AVPlayerLayer)?.videoGravity = gravity }
    }
}

/// Transport time. Watches only the clock, so ticking it redraws one label.
private struct TransportClock: View {
    @ObservedObject var clock: PlayheadClock
    let trimStart: Double
    let trimEnd: Double

    var body: some View {
        HStack(spacing: 4) {
            Text(TimecodeText.clock(max(0, clock.time - trimStart)))
                .foregroundStyle(Frame.label)
            Text("/")
                .foregroundStyle(Frame.tertiary)
            Text(TimecodeText.clock(max(0, trimEnd - trimStart)))
                .foregroundStyle(Frame.secondary)
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .frame(minWidth: 132, alignment: .leading)
    }
}

private struct ScenePlayhead: View {
    @ObservedObject var clock: PlayheadClock
    let pps: CGFloat

    var body: some View {
        Rectangle().fill(Frame.accent).frame(width: 2)
            .offset(x: clock.time * pps)
            .allowsHitTesting(false)
    }
}

/// Horizontal scroller around the timeline strip, with the CapCut habits:
/// zoom keeps the playhead where it is on screen, the view pages along
/// with the playhead during playback, and a trackpad pinch zooms.
private struct TimelineScroller: View {
    @ObservedObject var editor: EditorState
    @State private var position = ScrollPosition(edge: .leading)
    @State private var metrics = ScrollMetrics()
    @State private var pinchBase: Double?

    /// Must match TimelineStrip's label column and padding.
    private let labelW: CGFloat = 64
    private let pad: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let contentW = max(viewport, viewport * editor.timelineZoom)
            ScrollView(.horizontal, showsIndicators: true) {
                TimelineStrip(editor: editor)
                    .frame(width: contentW, height: editor.timelineHeight)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                metrics.offset = x
            }
            .onChange(of: editor.timelineZoom) { old, new in
                keepPlayheadPinned(oldZoom: old, newZoom: new, viewport: viewport)
            }
            .background {
                PlayheadFollower(clock: editor.clock) { time in
                    follow(time: time, viewport: viewport)
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = editor.timelineZoom }
                        editor.setTimelineZoom((pinchBase ?? 1) * value.magnification)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .onAppear { metrics.viewport = viewport }
            .onChange(of: viewport) { _, w in metrics.viewport = w }
        }
    }

    /// Content x of the playhead needle at a given zoom.
    private func playheadX(time: Double, zoom: Double, viewport: CGFloat) -> CGFloat {
        let contentW = max(viewport, viewport * zoom)
        let trackW = max(contentW - pad * 2 - labelW, 1)
        let window = TimelineLayout.keepWindow(
            trimStart: editor.trimStart, trimEnd: editor.trimEnd,
            duration: editor.duration, trackWidth: trackW)
        return pad + labelW + window.x(for: time)
    }

    private func keepPlayheadPinned(oldZoom: Double, newZoom: Double, viewport: CGFloat) {
        guard viewport > 0 else { return }
        let t = editor.currentTime
        let onScreen = playheadX(time: t, zoom: oldZoom, viewport: viewport) - metrics.offset
        // If the playhead was off screen, zoom around the middle instead.
        let anchor = (onScreen >= 0 && onScreen <= viewport) ? onScreen : viewport / 2
        let target = playheadX(time: t, zoom: newZoom, viewport: viewport) - anchor
        let maxOffset = max(0, viewport * newZoom - viewport)
        let x = min(max(0, target), maxOffset)
        metrics.offset = x
        position.scrollTo(x: x)
    }

    private func follow(time: Double, viewport: CGFloat) {
        guard editor.timelineZoom > 1.01, !editor.clock.scrubbing, viewport > 0 else { return }
        let x = playheadX(time: time, zoom: editor.timelineZoom, viewport: viewport)
        let visible = metrics.offset...(metrics.offset + viewport)
        let margin = viewport * 0.08
        guard x < visible.lowerBound + labelW || x > visible.upperBound - margin else { return }
        // Page forward like CapCut: put the playhead near the left edge.
        let maxOffset = max(0, viewport * editor.timelineZoom - viewport)
        let target = min(max(0, x - labelW - viewport * 0.12), maxOffset)
        metrics.offset = target
        position.scrollTo(x: target)
    }
}

/// Plain box: scroll offset changes every frame of a scroll and must not
/// trigger SwiftUI updates.
private final class ScrollMetrics {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
}

/// Invisible view that reports clock ticks without making its parent
/// (the scroller) observe the clock.
private struct PlayheadFollower: View {
    @ObservedObject var clock: PlayheadClock
    let onTick: (Double) -> Void

    var body: some View {
        Color.clear
            .onChange(of: clock.time) { _, t in onTick(t) }
    }
}
