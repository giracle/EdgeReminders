import AppKit
import QuartzCore
import SwiftUI

private final class FocusClockWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let host = contentView as? FocusClockHost {
            host.updateHover(at: event.locationInWindow)
        }
        super.sendEvent(event)
    }
}

@MainActor
@Observable
private final class FocusClockHover {
    var isHovered = false
}

private final class FocusClockHost: NSHostingView<FocusClockView> {
    private lazy var hoverArea = NSTrackingArea(
        rect: .zero,
        options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .enabledDuringMouseDrag],
        owner: self, userInfo: nil
    )

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(hoverArea) { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hoverArea { rootView.hover.isHovered = true }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverArea { rootView.hover.isHovered = false }
        super.mouseExited(with: event)
    }

    func updateHover(at windowPoint: NSPoint) {
        rootView.hover.isHovered = bounds.contains(convert(windowPoint, from: nil))
    }
}

private extension FocusTimer {
    var clockFaceTime: String {
        status == .idle ? String(format: "%02d:00", settings.focusMinutes) : displayTime
    }

    var clockFaceWidth: CGFloat {
        let configuredMinutes = phase.map { settings.minutes(for: $0) } ?? settings.focusMinutes
        let digitsWidth: CGFloat = configuredMinutes >= 100 || clockFaceTime.count > 5 ? 159 : 129
        return digitsWidth + FocusClockView.closeSlotWidth
    }
}

@MainActor
final class FocusTimerPanelController: NSObject, NSPopoverDelegate {
    private let timer: FocusTimer
    private let window = FocusClockWindow(
        contentRect: NSRect(x: 0, y: 0, width: 151, height: 38),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    private let popover = NSPopover()
    private var host: FocusClockHost?
    private var hasPositionedWindow = false

    init(timer: FocusTimer) {
        self.timer = timer
        super.init()
        window.title = "计时浮窗"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none

        let host = FocusClockHost(rootView: FocusClockView(timer: timer, open: { [weak self] in
            self?.toggleControls()
        }, close: { [weak self] in
            self?.hide()
        }, sizeChanged: { [weak self] in
            guard let self, self.hasPositionedWindow else { return }
            self.positionWindow()
        }))
        host.sizingOptions = []
        window.contentView = host
        self.host = host

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show(task: FocusTimer.TaskReference? = nil) {
        revealWindow()
        presentControls(task: task)
    }

    func restoreIfNeeded() {
        if timer.status == .running || timer.status == .paused {
            revealWindow()
        }
    }

    func showClock() {
        popover.close()
        revealWindow()
    }

    func hide() {
        popover.close()
        window.orderOut(nil)
        host?.rootView.hover.isHovered = false
    }

    func popoverDidClose(_ notification: Notification) {
        if window.isKeyWindow { window.resignKey() }
    }

    private func revealWindow() {
        positionWindow()
        window.orderFrontRegardless()
        host?.updateHover(at: window.mouseLocationOutsideOfEventStream)
    }

    private func preferredScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    var completionScreen: NSScreen? {
        if hasPositionedWindow, let screen = window.screen { return screen }
        return preferredScreen()
    }

    private func positionWindow() {
        guard let frame = completionScreen?.visibleFrame else { return }
        let width = timer.clockFaceWidth
        let height = window.frame.height
        let origin = hasPositionedWindow ? window.frame.origin
            : CGPoint(x: frame.maxX - width - 8, y: frame.maxY - height - 8)
        let x = max(frame.minX, min(origin.x, frame.maxX - width))
        let y = max(frame.minY, min(origin.y, frame.maxY - height))
        let updatedFrame = NSRect(x: x, y: y, width: width, height: height)
        if updatedFrame != window.frame { window.setFrame(updatedFrame, display: true) }
        hasPositionedWindow = true
    }

    @objc private func displaysChanged() {
        guard hasPositionedWindow else { return }
        popover.close()
        positionWindow()
    }

    private func toggleControls() {
        if popover.isShown {
            popover.close()
        } else {
            presentControls(task: nil)
        }
    }

    private func presentControls(task: FocusTimer.TaskReference?) {
        guard let host else { return }
        if popover.isShown {
            guard timer.status == .idle, task != nil else { return }
            popover.close()
        }
        let controls = FocusClockControls(timer: timer, task: timer.status == .idle ? task : nil, dismiss: { [weak self] in
            self?.popover.close()
        })
        popover.contentViewController = NSHostingController(rootView: controls)
        window.makeKey()
        popover.show(relativeTo: host.bounds, of: host, preferredEdge: .minY)
    }
}

@MainActor
private struct FocusClockView: View {
    static let closeSlotWidth: CGFloat = 22
    @ObservedObject var timer: FocusTimer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hover = FocusClockHover()
    let open: () -> Void
    let close: () -> Void
    let sizeChanged: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            closeButton
            clockButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onChange(of: timer.clockFaceWidth) { sizeChanged() }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .frame(width: Self.closeSlotWidth, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hover.isHovered ? 1 : 0)
        .allowsHitTesting(hover.isHovered)
        .accessibilityHidden(!hover.isHovered)
        .accessibilityLabel("关闭计时窗口")
        .help("关闭窗口，计时继续")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.13), value: hover.isHovered)
    }

    private var clockButton: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                ForEach(Array(timer.clockFaceTime.reversed().enumerated()).reversed(), id: \.offset) { _, character in
                    if character == ":" {
                        Text(":")
                            .font(.system(size: 21, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 9, height: 38)
                    } else {
                        FocusFlipDigit(character: character)
                    }
                }
            }
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(WindowDragGesture())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: Text("关闭计时窗口"), close)
    }

    private var accessibilityLabel: String {
        let label: String
        switch timer.status {
        case .idle: label = "计时设置"
        case .running: label = "计时中"
        case .paused: label = "计时已暂停"
        case .finished: label = "计时结束"
        }
        return "\(label)，\(timer.clockFaceTime)"
    }
}

private struct FocusFlipDigit: View {
    private struct Flip {
        let previous: Character
        let start: CFTimeInterval
    }

    private static let width: CGFloat = 27
    private static let height: CGFloat = 38
    private static let fold = 0.10
    private static let unfold = 0.12
    private static let duration = fold + unfold

    let character: Character
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var flip: Flip?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120, paused: flip == nil || reduceMotion)) { _ in
            faces(elapsed: flip.map { CACurrentMediaTime() - $0.start } ?? Self.duration)
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(.rect(cornerRadius: 4))
        .onChange(of: character) { previous, _ in
            flip = reduceMotion ? nil : Flip(previous: previous, start: CACurrentMediaTime())
        }
        .onChange(of: reduceMotion) { if reduceMotion { flip = nil } }
        .task(id: flip?.start) {
            guard let start = flip?.start else { return }
            do { try await Task.sleep(for: .seconds(Self.duration)) } catch { return }
            if flip?.start == start { flip = nil }
        }
    }

    private func faces(elapsed: TimeInterval) -> some View {
        let previous = flip?.previous ?? character
        let folding = !reduceMotion && elapsed < Self.fold
        let unfolding = !reduceMotion && elapsed >= Self.fold && elapsed < Self.duration

        return ZStack(alignment: .top) {
            VStack(spacing: 0) {
                half(character, top: true)
                half(folding || unfolding ? previous : character, top: false)
            }
            if folding {
                let progress = max(0, elapsed / Self.fold)
                half(previous, top: true)
                    .rotation3DEffect(.degrees(-90 * progress * progress), axis: (1, 0, 0), anchor: .bottom)
            } else if unfolding {
                let remaining = 1 - (elapsed - Self.fold) / Self.unfold
                half(character, top: false)
                    .rotation3DEffect(.degrees(90 * remaining * remaining), axis: (1, 0, 0), anchor: .top)
                    .offset(y: Self.height / 2)
            }
            Rectangle()
                .fill(.black.opacity(colorScheme == .dark ? 0.38 : 0.20))
                .frame(height: 0.5)
                .offset(y: Self.height / 2)
        }
    }

    private func half(_ value: Character, top: Bool) -> some View {
        let lightness = colorScheme == .dark ? (top ? 0.17 : 0.21) : (top ? 0.90 : 0.94)
        return Text(String(value))
            .font(.system(size: 28, weight: .medium, design: .monospaced))
            .foregroundStyle(colorScheme == .dark ? Color(white: 0.83) : Color(white: 0.26))
            .frame(width: Self.width, height: Self.height)
            .frame(width: Self.width, height: Self.height / 2, alignment: top ? .top : .bottom)
            .clipped()
            .background(Color(white: lightness))
    }
}

@MainActor
private struct FocusClockControls: View {
    @ObservedObject var timer: FocusTimer
    let dismiss: () -> Void
    @State private var task: FocusTimer.TaskReference?
    @State private var mode = FocusTimer.Mode.focus
    @State private var draft: FocusTimer.Settings
    @State private var showsDurations = false

    init(timer: FocusTimer, task: FocusTimer.TaskReference?, dismiss: @escaping () -> Void) {
        self.timer = timer
        self.dismiss = dismiss
        _draft = State(initialValue: timer.settings)
        _task = State(initialValue: task)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if timer.status == .idle {
                setup
            } else {
                activeControls
            }
        }
        .padding(13)
        .frame(width: 246)
        .onExitCommand(perform: dismiss)
    }

    @ViewBuilder private var setup: some View {
        Picker("计时方式", selection: $mode) {
            Text("专注计时").tag(FocusTimer.Mode.focus)
            Text("普通倒计时").tag(FocusTimer.Mode.countdown)
        }
        .labelsHidden()
        .pickerStyle(.segmented)

        if mode == .focus, let task {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .accessibilityHidden(true)
                Text(task.title).lineLimit(2)
                Spacer()
                Button("解除任务关联", systemImage: "xmark.circle.fill") { self.task = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("解除任务关联")
            }
        }

        durationRow(mode == .focus ? "专注时长" : "倒计时", value: duration)
        HStack(spacing: 6) {
            ForEach(mode == .focus ? [15, 25, 45] : [5, 15, 30], id: \.self) { preset in
                Button("\(preset) 分钟") { duration.wrappedValue = preset }
                    .controlSize(.small)
            }
        }

        if mode == .focus {
            DisclosureGroup("休息时长", isExpanded: $showsDurations) {
                VStack(spacing: 5) {
                    durationRow("短休息", value: $draft.shortBreakMinutes)
                    durationRow("长休息", value: $draft.longBreakMinutes)
                }
                .padding(.top, 5)
            }
        }

        Divider()
        Toggle("到点播放提示音", isOn: $draft.soundEnabled)
        Toggle("在菜单栏显示时间", isOn: $draft.showInMenuBar)
        Button(mode == .focus ? "开始专注" : "开始倒计时") {
            timer.configure(draft)
            timer.start(mode: mode, task: mode == .focus ? task : nil)
            dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(!validDurations)
    }

    @ViewBuilder private var activeControls: some View {
        let phase: FocusTimer.Phase? = timer.phase
        let title = phase?.title ?? "计时"
        Text(timer.status == .finished ? "\(title)结束" : timer.status == .paused ? "已暂停" : title)
            .font(.headline)
        if let task = timer.task {
            Text(task.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        HStack {
            switch timer.status {
            case .idle:
                EmptyView()
            case .running:
                Button("暂停") { timer.pause() }
            case .paused:
                Button("继续") { timer.resume(); dismiss() }
            case .finished:
                if let phase = timer.nextPhase {
                    Button("开始\(phase.title)") { timer.startNext(); dismiss() }
                } else {
                    Button("再计一次") { timer.startNext(); dismiss() }
                }
            }
            Button(timer.status == .finished ? "返回设置" : "结束计时") {
                draft = timer.settings
                task = timer.task
                mode = phase == .countdown ? .countdown : .focus
                timer.stop()
            }
        }
        Divider()
        Toggle("在菜单栏显示时间", isOn: Binding(
            get: { timer.settings.showInMenuBar },
            set: { enabled in
                var settings = timer.settings
                settings.showInMenuBar = enabled
                timer.configure(settings)
            }
        ))
    }

    private var duration: Binding<Int> {
        mode == .focus ? $draft.focusMinutes : $draft.countdownMinutes
    }

    private var validDurations: Bool {
        let allowed = FocusTimer.Settings.allowedMinutes
        return allowed.contains(duration.wrappedValue)
            && (mode == .countdown || (allowed.contains(draft.shortBreakMinutes)
                                       && allowed.contains(draft.longBreakMinutes)))
    }

    private func durationRow(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
            Text("分钟").foregroundStyle(.secondary)
        }
    }
}
