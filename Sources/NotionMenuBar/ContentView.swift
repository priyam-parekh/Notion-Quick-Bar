import SwiftUI
import AppKit

/// Makes the MenuBarExtra's hosting window transparent so the material pane
/// renders with its own rounded corners, like the system Sound/Control Center panels.
private final class WindowObservingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

private struct WindowChromeRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObservingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct TaskRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum LightModeTheme {
    static let overdueRed = Color(red: 0.72, green: 0.15, blue: 0.12)
    static let successGreen = Color(red: 0.18, green: 0.54, blue: 0.28)
    static let reorderBlue = Color(red: 0.20, green: 0.38, blue: 0.68)
    /// Ultra-thin blur for translucency; white overlays add brightness without a heavy fill.
    static let panelMaterial: Material = .ultraThinMaterial
    static let panelOverlay = Color.white.opacity(0.28)
    static let panelHighlight = Color.white.opacity(0.10)
    static let panelBorder = Color.white.opacity(0.32)
    static let fieldFill = Color.white.opacity(0.16)
    static let fieldFillFocused = Color.white.opacity(0.22)
    static let hoverFill = Color.white.opacity(0.14)
    static let selectionFill = Color.white.opacity(0.24)
}

enum DefaultTheme {
    static let reorderBlue = Color(red: 0.28, green: 0.48, blue: 0.80)
}

enum LunarTheme {
    static let background = Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.94)
    static let border = Color(red: 0.42, green: 0.45, blue: 0.62).opacity(0.45)
    static let primaryText = Color(red: 0.94, green: 0.95, blue: 0.98)
    static let secondaryText = Color(red: 0.62, green: 0.65, blue: 0.74)
    static let hoverFill = Color(red: 0.37, green: 0.40, blue: 0.58).opacity(0.24)
    static let selectionFill = Color(red: 0.33, green: 0.27, blue: 0.72).opacity(0.34)
    static let focusGlow = Color(red: 0.36, green: 0.46, blue: 1.00).opacity(0.38)
    static let fieldFill = Color.white.opacity(0.10)
    static let reorderBlue = Color(red: 0.34, green: 0.42, blue: 0.76)
}

private extension View {
    @ViewBuilder
    func lightAppearance(_ enabled: Bool) -> some View {
        if enabled {
            environment(\.colorScheme, .light)
        } else {
            self
        }
    }
}

private struct KeyboardShortcutMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onKeyDown: (NSEvent) -> Bool
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool) {
            self.onKeyDown = onKeyDown
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.onKeyDown(event) else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            stop()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    let removesWindowChrome: Bool
    @State private var newTaskTitle = ""
    @State private var showingSettings = false
    @State private var selectedTaskId: String?
    @State private var completingTaskId: String?
    @State private var draggedTaskId: String?
    @State private var insertionTargetId: String?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragOffset: CGSize = .zero
    @FocusState private var fieldFocused: Bool

    init(removesWindowChrome: Bool = false) {
        self.removesWindowChrome = removesWindowChrome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 8)

            if showingSettings {
                SettingsView(isPresented: $showingSettings)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                Group {
                    content
                        .padding(.horizontal, 10)

                    statusArea

                    addTaskField
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(width: 320)
        .background(panelBackground)
        .overlay(panelBorder)
        .shadow(
            color: panelShadowColor,
            radius: store.lunarMode ? 22 : 18,
            y: store.lunarMode ? 10 : 8
        )
        .lightAppearance(store.lightMode)
        .background(removesWindowChrome ? AnyView(WindowChromeRemover()) : AnyView(EmptyView()))
        .background(KeyboardShortcutMonitor(onKeyDown: handleKeyDown))
        .animation(.spring(duration: 0.35, bounce: 0.3), value: store.addState)
        .animation(.snappy(duration: 0.25), value: store.errorMessage)
        .animation(.snappy(duration: 0.25), value: showingSettings)
        .onChange(of: store.keyboardTasks) { _, _ in
            keepSelectionValid()
        }
        .task { await store.refreshIfStale() }
        .onAppear {
            if !store.isConfigured { showingSettings = true }
            // Focus the field whenever the widget opens so typing lands there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
    }

    private var panelBackground: some View {
        Group {
            if store.lunarMode {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LunarTheme.background)
                    )
            } else if store.lightMode {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LightModeTheme.panelMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LightModeTheme.panelOverlay)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LightModeTheme.panelHighlight,
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
                panelBorderColor,
                lineWidth: 1
            )
    }

    private var panelBorderColor: Color {
        if store.lunarMode { return LunarTheme.border }
        if store.lightMode { return LightModeTheme.panelBorder }
        return .clear
    }

    private var panelShadowColor: Color {
        if store.lunarMode { return Color.black.opacity(0.42) }
        return .clear
    }

    private var primaryTextStyle: AnyShapeStyle {
        if store.lunarMode { return AnyShapeStyle(LunarTheme.primaryText) }
        return AnyShapeStyle(.primary)
    }

    private var secondaryTextStyle: AnyShapeStyle {
        if store.lunarMode { return AnyShapeStyle(LunarTheme.secondaryText) }
        return AnyShapeStyle(.secondary)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(showingSettings ? "Settings" : "Today")
                .font(.headline)
                .foregroundStyle(primaryTextStyle)
                .lineLimit(1)
                .contentTransition(.opacity)
            if !showingSettings && !store.todayTasks.isEmpty {
                Text("\(store.todayTasks.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(secondaryTextStyle)
                    .contentTransition(.numericText(value: Double(store.todayTasks.count)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Spacer(minLength: 6)
            if store.undoableDoneTask != nil && !showingSettings {
                HoverIconButton(systemName: "arrow.uturn.backward", help: "Undo Complete", lunarMode: store.lunarMode) {
                    Task { await store.undoLastDone() }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if !showingSettings && store.isConfigured {
                MinimalPillToggle(isOn: store.minimalMode, lunarMode: store.lunarMode) {
                    withAnimation(.snappy(duration: 0.25)) {
                        store.setMinimalMode(!store.minimalMode)
                    }
                }
                HeaderIconToggle(
                    systemName: "calendar",
                    help: "Week mode",
                    accessibilityLabel: "Week mode",
                    isOn: store.weekMode,
                    lunarMode: store.lunarMode
                ) {
                    withAnimation(.snappy(duration: 0.25)) {
                        store.setWeekMode(!store.weekMode)
                    }
                }
                HoverIconButton(systemName: "arrow.up.right", help: "Open in Notion", lunarMode: store.lunarMode) {
                    if let url = URL(string: "https://notion.so/\(store.databaseId)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            HoverIconButton(
                systemName: showingSettings ? "xmark" : "gearshape",
                help: showingSettings ? "Close settings" : "Settings",
                lunarMode: store.lunarMode
            ) {
                showingSettings.toggle()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.isConfigured {
            emptyState(icon: "link.circle", text: "Connect Notion in Settings to get started")
        } else if store.isLoading && store.visibleCount == 0 {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else if store.visibleCount == 0 {
            emptyState(icon: "checkmark.circle", text: "All clear")
        } else {
            taskList
        }
    }

    private var taskList: some View {
        Group {
            if store.visibleCount > 12 {
                ScrollView {
                    listRows
                }
                .frame(height: 440)
            } else {
                listRows
            }
        }
        .coordinateSpace(name: "taskList")
        .onPreferenceChange(TaskRowFramePreferenceKey.self) { rowFrames = $0 }
    }

    @ViewBuilder
    private var listRows: some View {
        if store.visibleCount > 12 {
            LazyVStack(alignment: .leading, spacing: 1) {
                taskListContent
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                taskListContent
            }
        }
    }

    @ViewBuilder
    private var taskListContent: some View {
        ForEach(store.todayTasks) { task in
            draggableRow(for: task)
        }
        bottomDropTarget
        if !store.minimalMode && !store.tomorrowTasks.isEmpty {
            sectionHeader("Tomorrow")
            ForEach(store.tomorrowTasks) { task in
                taskRow(for: task)
            }
        }
        if store.weekMode {
            ForEach(store.weekSections) { section in
                sectionHeader(section.title)
                ForEach(section.tasks) { task in
                    taskRow(for: task)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(secondaryTextStyle)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .transition(.opacity)
    }

    private func taskRow(for task: TaskItem) -> some View {
        TaskRow(
            task: task,
            isSelected: selectedTaskId == task.id,
            isCompleting: completingTaskId == task.id,
            lightMode: store.lightMode,
            lunarMode: store.lunarMode,
            onToggle: { complete(task) },
            onToggleImportant: { Task { await store.toggleImportant(task) } }
        )
        .onTapGesture {
            selectedTaskId = task.id
        }
    }

    private func draggableRow(for task: TaskItem) -> some View {
        VStack(spacing: 0) {
            insertionLine(above: task.id)
            taskRow(for: task)
            .opacity(draggedTaskId == task.id ? 0.72 : 1)
            .scaleEffect(draggedTaskId == task.id ? 1.015 : 1)
            .offset(y: draggedTaskId == task.id ? dragOffset.height : 0)
            .shadow(
                color: draggedTaskId == task.id ? Color.black.opacity(0.16) : .clear,
                radius: 8,
                y: 3
            )
            .zIndex(draggedTaskId == task.id ? 1 : 0)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TaskRowFramePreferenceKey.self,
                        value: [task.id: proxy.frame(in: .named("taskList"))]
                    )
                }
            )
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("taskList"))
                    .onChanged { value in
                        if draggedTaskId == nil {
                            withAnimation(.spring(duration: 0.2, bounce: 0.25)) {
                                draggedTaskId = task.id
                            }
                        }
                        dragOffset = value.translation
                        updateInsertionTarget(for: value.location.y, dragging: task.id)
                    }
                    .onEnded { _ in
                        finishDrag()
                    }
            )
        }
    }

    private var bottomDropTarget: some View {
        insertionLine(above: nil)
            .frame(height: draggedTaskId == nil ? 0 : nil)
    }

    private var reorderInsertionColor: Color {
        if store.lunarMode { return LunarTheme.reorderBlue }
        if store.lightMode { return LightModeTheme.reorderBlue }
        return DefaultTheme.reorderBlue
    }

    private func insertionLine(above taskId: String?) -> some View {
        Group {
            if draggedTaskId != nil && insertionTargetId == taskId {
                Capsule()
                    .fill(reorderInsertionColor)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .shadow(color: reorderInsertionColor.opacity(0.28), radius: 3, y: 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }

    private func updateInsertionTarget(for yPosition: CGFloat, dragging taskId: String) {
        let visibleIds = store.todayTasks
            .map(\.id)
            .filter { $0 != taskId }

        let nextTarget = visibleIds.first { id in
            guard let frame = rowFrames[id] else { return false }
            return yPosition < frame.midY
        }
        guard nextTarget != insertionTargetId else { return }
        insertionTargetId = nextTarget
    }

    private func finishDrag() {
        guard let draggedTaskId else { return }
        if let insertionTargetId {
            store.move(draggedTaskId, before: insertionTargetId)
        } else {
            store.moveToBottom(draggedTaskId)
        }
        withAnimation(.spring(duration: 0.28, bounce: 0.18)) {
            self.draggedTaskId = nil
            self.insertionTargetId = nil
            self.dragOffset = .zero
        }
    }

    private var keyboardTasks: [TaskItem] {
        store.keyboardTasks
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            NSApp.keyWindow?.close()
            return true
        case 126:
            moveSelectionUp()
            return !showingSettings
        case 125:
            moveSelectionDown()
            return !showingSettings
        case 36, 76:
            guard let task = selectedTask else { return false }
            complete(task)
            return true
        case 48:
            guard let task = selectedTask else { return false }
            Task { await store.toggleImportant(task) }
            return true
        default:
            return false
        }
    }

    private var selectedTask: TaskItem? {
        guard let selectedTaskId else { return nil }
        return keyboardTasks.first { $0.id == selectedTaskId }
    }

    private func moveSelectionUp() {
        guard !showingSettings else { return }
        if fieldFocused {
            selectTask(at: keyboardTasks.indices.last)
        } else {
            selectTask(offset: -1)
        }
    }

    private func moveSelectionDown() {
        guard !showingSettings else { return }
        guard !keyboardTasks.isEmpty else {
            selectedTaskId = nil
            fieldFocused = true
            return
        }
        if let selectedTaskId,
           let currentIndex = keyboardTasks.firstIndex(where: { $0.id == selectedTaskId }),
           currentIndex == keyboardTasks.count - 1 {
            focusAddField()
        } else if selectedTaskId == nil && fieldFocused {
            return
        } else {
            selectTask(offset: 1)
        }
    }

    private func selectTask(offset: Int) {
        guard !showingSettings else { return }
        let tasks = keyboardTasks
        guard !tasks.isEmpty else {
            selectedTaskId = nil
            return
        }

        let currentIndex = selectedTaskId.flatMap { id in
            tasks.firstIndex { $0.id == id }
        }

        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + offset, 0), tasks.count - 1)
        } else {
            nextIndex = offset < 0 ? tasks.count - 1 : 0
        }
        withAnimation(.easeOut(duration: 0.12)) {
            selectedTaskId = tasks[nextIndex].id
            fieldFocused = false
        }
    }

    private func selectTask(at index: Array<TaskItem>.Index?) {
        guard let index else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            selectedTaskId = keyboardTasks[index].id
            fieldFocused = false
        }
    }

    private func focusAddField() {
        withAnimation(.easeOut(duration: 0.12)) {
            selectedTaskId = nil
            fieldFocused = true
        }
    }

    private func keepSelectionValid() {
        guard let selectedTaskId,
              !keyboardTasks.contains(where: { $0.id == selectedTaskId }) else { return }
        self.selectedTaskId = nil
    }

    private func complete(_ task: TaskItem) {
        guard completingTaskId == nil else { return }
        completingTaskId = task.id
        selectedTaskId = nil
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await store.toggleDone(task)
            completingTaskId = nil
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if let error = store.errorMessage {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(error)
                    .lineLimit(3)
            }
            .font(.caption2)
            .foregroundStyle(.red)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(emptyStateIconStyle)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(secondaryTextStyle)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .multilineTextAlignment(.center)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var addTaskField: some View {
        HStack(spacing: 8) {
            AddStateIcon(state: store.addState, lightMode: store.lightMode)
                .frame(width: 13, height: 13)

            TextField(text: $newTaskTitle, prompt: Text("Add a task").foregroundStyle(addFieldPromptStyle)) {
                EmptyView()
            }
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(primaryTextStyle)
                .focused($fieldFocused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(addFieldBackground, in: Capsule())
        .overlay(alignment: .trailing) {
            // Floats over the (empty) field so nothing shifts.
            if case .added(let dateLabel?) = store.addState {
                Text("Added · \(dateLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(successStyle)
                    .padding(.trailing, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(addFieldAnimation, value: store.addState)
        .animation(.easeOut(duration: 0.15), value: fieldFocused)
        .disabled(!store.isConfigured)
    }

    private var addFieldBackground: Color {
        if store.lunarMode {
            return fieldFocused ? LunarTheme.fieldFill.opacity(1.35) : LunarTheme.fieldFill
        }
        if store.lightMode {
            return fieldFocused ? LightModeTheme.fieldFillFocused : LightModeTheme.fieldFill
        }
        return Color.primary.opacity(fieldFocused ? 0.09 : 0.06)
    }

    private var addFieldPromptStyle: AnyShapeStyle {
        if store.lunarMode { return AnyShapeStyle(LunarTheme.secondaryText) }
        return AnyShapeStyle(.secondary)
    }

    private var emptyStateIconStyle: AnyShapeStyle {
        if store.lunarMode { return AnyShapeStyle(LunarTheme.secondaryText.opacity(0.75)) }
        return AnyShapeStyle(.tertiary)
    }

    private var successStyle: AnyShapeStyle {
        if store.lightMode { return AnyShapeStyle(LightModeTheme.successGreen) }
        return AnyShapeStyle(.green)
    }

    private var addFieldAnimation: Animation {
        if case .idle = store.addState {
            return .spring(response: 0.42, dampingFraction: 0.78)
        }
        return .easeOut(duration: 0.2)
    }

    private func submit() {
        let title = newTaskTitle
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Enter on an empty field collapses the widget.
            NSApp.keyWindow?.close()
            return
        }
        newTaskTitle = ""
        Task { await store.addTask(title: title) }
    }
}

/// The add field's leading icon, morphing through the add lifecycle:
/// plus → spinning arc → arc closes into a ring while a checkmark draws in → plus.
private struct AddStateIcon: View {
    let state: TaskStore.AddState
    let lightMode: Bool

    private var showPlus: Bool {
        if case .idle = state { return true }
        return false
    }

    private var showAdding: Bool {
        if case .adding = state { return true }
        return false
    }

    private var showAdded: Bool {
        if case .added = state { return true }
        return false
    }

    private var stateAnimation: Animation {
        if showPlus {
            // Ease the check out while the plus springs back in.
            return .spring(response: 0.42, dampingFraction: 0.78)
        }
        if showAdded {
            return .easeOut(duration: 0.22)
        }
        return .easeOut(duration: 0.15)
    }

    var body: some View {
        ZStack {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(showPlus ? 1 : 0)
                .scaleEffect(showPlus ? 1 : 0.72)
                .rotationEffect(.degrees(showPlus ? 0 : -45))

            if showAdding {
                SpinnerArc()
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            MorphingCheck(lightMode: lightMode, isVisible: showAdded)
                .opacity(showAdded ? 1 : 0)
                .scaleEffect(showAdded ? 1 : 0.84)
        }
        .animation(stateAnimation, value: state)
    }
}

/// A thin open arc spinning while the task saves.
private struct SpinnerArc: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// The spinner's arc closes into a full ring as a checkmark draws in.
private struct MorphingCheck: View {
    let lightMode: Bool
    let isVisible: Bool
    @State private var ringProgress: CGFloat = 0.72
    @State private var checkProgress: CGFloat = 0

    private var strokeColor: Color {
        lightMode ? LightModeTheme.successGreen : .green
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(strokeColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 11, height: 11)
            CheckShape()
                .trim(from: 0, to: checkProgress)
                .stroke(strokeColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 6, height: 6)
        }
        .onAppear { syncVisibility(isVisible) }
        .onChange(of: isVisible) { _, visible in
            syncVisibility(visible)
        }
    }

    private func syncVisibility(_ visible: Bool) {
        if visible {
            ringProgress = 0.72
            checkProgress = 0
            withAnimation(.easeOut(duration: 0.2)) { ringProgress = 1 }
            withAnimation(.spring(duration: 0.35, bounce: 0.3).delay(0.12)) { checkProgress = 1 }
        } else {
            withAnimation(.easeIn(duration: 0.16)) { checkProgress = 0 }
            withAnimation(.easeIn(duration: 0.2).delay(0.05)) { ringProgress = 0.72 }
        }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.minY + rect.height * 0.9))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return path
    }
}

/// Priority star: stays visible when set, and previews by filling in
/// (no size change) when the pointer is over it.
private struct StarButton: View {
    let isImportant: Bool
    let lunarMode: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isImportant || hovering ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconStyle)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isImportant ? "Remove Priority" : "Mark as Priority")
    }

    private var iconStyle: AnyShapeStyle {
        if lunarMode { return AnyShapeStyle(LunarTheme.secondaryText) }
        return AnyShapeStyle(.secondary)
    }
}

private struct MinimalPillToggle: View {
    let isOn: Bool
    let lunarMode: Bool
    let action: () -> Void

    private let trackWidth: CGFloat = 18
    private let trackHeight: CGFloat = 9
    private let inset: CGFloat = 1.5

    private var knobDiameter: CGFloat { trackHeight - inset * 2 }
    private var knobTrailingOffset: CGFloat { trackWidth - knobDiameter - inset }
    private var knobOffset: CGFloat { isOn ? knobTrailingOffset : inset }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(width: trackWidth, height: trackHeight)
                    .opacity(isOn ? 1 : 0)

                Capsule()
                    .strokeBorder(trackColor, lineWidth: 1)
                    .frame(width: trackWidth, height: trackHeight)
                    .opacity(isOn ? 0 : 1)

                Circle()
                    .fill(knobColor)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: knobOffset)
            }
            .animation(.snappy(duration: 0.25), value: isOn)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Minimal — hide tomorrow's tasks")
        .accessibilityLabel("Minimal")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var trackColor: Color {
        if lunarMode {
            return isOn ? LunarTheme.primaryText : LunarTheme.secondaryText
        }
        return isOn ? Color.primary : Color.secondary
    }

    private var knobColor: Color {
        if lunarMode { return LunarTheme.secondaryText }
        return Color.secondary
    }
}

private struct HeaderIconToggle: View {
    let systemName: String
    let help: String
    let accessibilityLabel: String
    let isOn: Bool
    let lunarMode: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconStyle)
                .frame(width: 20, height: 20)
                .background(backgroundFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var iconStyle: AnyShapeStyle {
        if isOn {
            if lunarMode { return AnyShapeStyle(LunarTheme.primaryText) }
            return AnyShapeStyle(.primary)
        }
        if lunarMode {
            return AnyShapeStyle(isHovering ? LunarTheme.primaryText : LunarTheme.secondaryText)
        }
        return isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var backgroundFill: Color {
        isOn ? Color.primary.opacity(0.10) : .clear
    }
}

/// Small secondary icon button that brightens on hover.
private struct HoverIconButton: View {
    let systemName: String
    let help: String
    var lunarMode = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconStyle)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(help)
    }

    private var iconStyle: AnyShapeStyle {
        if lunarMode {
            return AnyShapeStyle(isHovering ? LunarTheme.primaryText : LunarTheme.secondaryText)
        }
        return isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let isSelected: Bool
    let isCompleting: Bool
    let lightMode: Bool
    let lunarMode: Bool
    let onToggle: () -> Void
    let onToggleImportant: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: complete) {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        isCompleting
                            ? successStyle
                            : completionCircleStyle
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(isCompleting ? 1.1 : 1)
            }
            .buttonStyle(.plain)
            .help("Mark done")

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.body)
                    .strikethrough(isCompleting, color: .secondary)
                    .foregroundStyle(taskTitleStyle)
                    .fixedSize(horizontal: false, vertical: true)

                if task.isOverdue && !isCompleting {
                    Text(task.daysOverdue == 1 ? "1 day overdue" : "\(task.daysOverdue) days overdue")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(overdueStyle)
                }
            }

            Spacer(minLength: 0)

            StarButton(isImportant: task.important, lunarMode: lunarMode, action: onToggleImportant)
                .opacity((task.important || isHovering) && !isCompleting ? 1 : 0)

            HoverIconButton(systemName: "arrow.up.right", help: "Open in Notion", lunarMode: lunarMode) {
                if let url = URL(string: task.url) {
                    NSWorkspace.shared.open(url)
                }
            }
            .opacity(isHovering && !isCompleting ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected && lunarMode ? LunarTheme.focusGlow : Color.clear, lineWidth: 1)
        )
        .shadow(
            color: isSelected && lunarMode ? LunarTheme.focusGlow : .clear,
            radius: 8,
            y: 0
        )
        .animation(.easeOut(duration: 0.12), value: rowAnimationState)
        .onHover { isHovering = $0 }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
        ))
    }

    private var rowAnimationState: String {
        "\(isHovering)-\(isSelected)-\(isCompleting)"
    }

    private var rowBackground: Color {
        if isSelected {
            if lunarMode { return LunarTheme.selectionFill }
            if lightMode { return LightModeTheme.selectionFill }
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            if lunarMode { return LunarTheme.hoverFill }
            if lightMode { return LightModeTheme.hoverFill }
            return Color.primary.opacity(0.07)
        }
        return .clear
    }

    private var taskTitleStyle: AnyShapeStyle {
        if lunarMode {
            return AnyShapeStyle(isCompleting ? LunarTheme.secondaryText : LunarTheme.primaryText)
        }
        return isCompleting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    private var completionCircleStyle: AnyShapeStyle {
        if lunarMode { return AnyShapeStyle(LunarTheme.secondaryText) }
        return AnyShapeStyle(.secondary)
    }

    private var successStyle: AnyShapeStyle {
        if lightMode { return AnyShapeStyle(LightModeTheme.successGreen) }
        return AnyShapeStyle(.green)
    }

    private var overdueStyle: AnyShapeStyle {
        if lightMode { return AnyShapeStyle(LightModeTheme.overdueRed) }
        return AnyShapeStyle(.red)
    }

    private func complete() {
        guard !isCompleting else { return }
        onToggle()
    }
}
