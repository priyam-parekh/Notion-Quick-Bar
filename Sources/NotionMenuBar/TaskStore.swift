import SwiftUI

struct DatedTaskSection: Identifiable, Equatable {
    let date: Date
    let title: String
    let tasks: [TaskItem]

    var id: Date { date }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = [] { didSet { regroup() } }
    /// Undated, due today, and overdue tasks. Cached so views and the menu
    /// bar label don't re-filter on every render.
    @Published private(set) var todayTasks: [TaskItem] = []
    @Published private(set) var tomorrowTasks: [TaskItem] = []
    @Published private(set) var weekSections: [DatedTaskSection] = []
    @Published private(set) var keyboardTasks: [TaskItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Lifecycle of an add, driven through the field's icon:
    /// plus → spinner → checkmark (with an optional date label) → plus.
    @Published var addState: AddState = .idle
    @Published var databaseId: String
    @Published private(set) var lightMode: Bool
    @Published private(set) var lunarMode: Bool
    @Published private(set) var weekMode: Bool
    @Published private(set) var undoableDoneTask: TaskItem?

    enum AddState: Equatable {
        case idle
        case adding
        case added(dateLabel: String?)
    }

    private var schema: NotionSchema?
    private var refreshTimer: Timer?
    private var addResetTask: Task<Void, Never>?
    private var undoResetTask: Task<Void, Never>?
    private var token: String
    /// Tasks checked off locally whose Notion update is still in flight;
    /// refresh must not resurrect them.
    private var pendingDone: Set<String> = []
    private var undoneWhilePending: Set<String> = []
    private var savedOrderIds: [String] = []
    private var lastRefreshDate: Date?
    private var pendingRefresh = false

    private static let refreshStaleInterval: TimeInterval = 60
    private static let weekSectionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE: M/d"
        return formatter
    }()
    private static let addedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let databaseIdKey = "notionDatabaseId"
    private static let tokenAccount = "notionToken"
    private static let databaseIdAccount = "notionDatabaseId"
    private static let orderKey = "taskOrder"
    private static let lightModeKey = "lightMode"
    private static let lunarModeKey = "lunarMode"
    private static let weekModeKey = "weekMode"

    init() {
        self.token = KeychainHelper.read(account: Self.tokenAccount) ?? ""
        // Sanitize in case an older version stored a raw URL or an ID with a ?v= suffix.
        let keychainDatabaseId = KeychainHelper.read(account: Self.databaseIdAccount)
        let legacyDatabaseId = UserDefaults.standard.string(forKey: Self.databaseIdKey)
        let stored = keychainDatabaseId ?? legacyDatabaseId ?? ""
        let cleanedDatabaseId = stored.isEmpty ? "" : Self.extractDatabaseId(from: stored)
        self.databaseId = cleanedDatabaseId
        let storedLunarMode = UserDefaults.standard.bool(forKey: Self.lunarModeKey)
        self.lunarMode = storedLunarMode
        self.lightMode = !storedLunarMode && UserDefaults.standard.bool(forKey: Self.lightModeKey)
        self.weekMode = UserDefaults.standard.bool(forKey: Self.weekModeKey)
        savedOrderIds = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []

        if keychainDatabaseId == nil, !cleanedDatabaseId.isEmpty {
            try? KeychainHelper.save(cleanedDatabaseId, account: Self.databaseIdAccount)
            UserDefaults.standard.removeObject(forKey: Self.databaseIdKey)
        }

        // Keeps the list and menu bar count current as the day rolls over.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfStale() }
        }
    }

    var isConfigured: Bool {
        !token.isEmpty && !databaseId.isEmpty
    }

    var visibleCount: Int {
        todayTasks.count + tomorrowTasks.count + (weekMode ? weekSections.reduce(0) { $0 + $1.tasks.count } : 0)
    }

    private func regroup() {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let weekEndStart = calendar.date(byAdding: .day, value: 7, to: todayStart)!

        var today: [TaskItem] = []
        var tomorrow: [TaskItem] = []
        var weekBuckets: [Date: [TaskItem]] = [:]
        today.reserveCapacity(tasks.count)
        tomorrow.reserveCapacity(min(tasks.count, 8))

        for task in tasks {
            guard let due = task.dueDate else {
                today.append(task)
                continue
            }
            let dueStart = calendar.startOfDay(for: due)
            if dueStart < tomorrowStart {
                today.append(task)
            } else if dueStart == tomorrowStart {
                tomorrow.append(task)
            } else if dueStart <= weekEndStart {
                weekBuckets[dueStart, default: []].append(task)
            }
        }

        todayTasks = today
        tomorrowTasks = tomorrow
        weekSections = (2...7).compactMap { dayOffset in
            let sectionDate = calendar.date(byAdding: .day, value: dayOffset, to: todayStart)!
            guard sectionDate <= weekEndStart,
                  let sectionTasks = weekBuckets[sectionDate],
                  !sectionTasks.isEmpty else { return nil }
            return DatedTaskSection(
                date: sectionDate,
                title: Self.weekSectionFormatter.string(from: sectionDate),
                tasks: sectionTasks
            )
        }
        updateKeyboardTasks()
    }

    private func updateKeyboardTasks() {
        keyboardTasks = todayTasks + tomorrowTasks + (weekMode ? weekSections.flatMap(\.tasks) : [])
    }

    // MARK: - Credentials

    @discardableResult
    func saveCredentials(token: String, databaseId: String) -> Bool {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDatabaseId = Self.extractDatabaseId(from: databaseId)
        guard !cleanedToken.isEmpty, !cleanedDatabaseId.isEmpty else {
            errorMessage = "Enter both a Notion token and database ID."
            return false
        }

        do {
            try KeychainHelper.save(cleanedToken, account: Self.tokenAccount)
            try KeychainHelper.save(cleanedDatabaseId, account: Self.databaseIdAccount)
            UserDefaults.standard.removeObject(forKey: Self.databaseIdKey)
        } catch {
            errorMessage = userSafeMessage(for: error)
            return false
        }

        self.token = cleanedToken
        // Accept a full Notion URL or a bare ID.
        self.databaseId = cleanedDatabaseId
        self.schema = nil
        Task { await refresh(force: true) }
        return true
    }

    func setLightMode(_ enabled: Bool) {
        lightMode = enabled
        if enabled {
            lunarMode = false
        }
        UserDefaults.standard.set(enabled, forKey: Self.lightModeKey)
        UserDefaults.standard.set(lunarMode, forKey: Self.lunarModeKey)
    }

    func setLunarMode(_ enabled: Bool) {
        lunarMode = enabled
        if enabled {
            lightMode = false
        }
        UserDefaults.standard.set(enabled, forKey: Self.lunarModeKey)
        UserDefaults.standard.set(lightMode, forKey: Self.lightModeKey)
    }

    func setWeekMode(_ enabled: Bool) {
        weekMode = enabled
        UserDefaults.standard.set(enabled, forKey: Self.weekModeKey)
        updateKeyboardTasks()
    }

    static func extractDatabaseId(from input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let queryStart = value.firstIndex(of: "?") {
            value = String(value[..<queryStart])
        }
        if let lastSlash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: lastSlash)...])
        }
        // Page URLs embed the ID at the end after the slug: Some-Title-<32 hex chars>
        let hex = value.replacingOccurrences(of: "-", with: "")
        return hex.count > 32 ? String(hex.suffix(32)) : hex
    }

    private func persistOrderIfChanged() {
        let ids = tasks.map(\.id)
        guard ids != savedOrderIds else { return }
        savedOrderIds = ids
        UserDefaults.standard.set(ids, forKey: Self.orderKey)
    }

    func refreshIfStale() async {
        await refresh(force: false)
    }

    func refresh(force: Bool = false) async {
        guard client() != nil else { return }
        if isLoading {
            pendingRefresh = true
            return
        }
        if !force,
           let lastRefreshDate,
           Date().timeIntervalSince(lastRefreshDate) < Self.refreshStaleInterval,
           !tasks.isEmpty {
            return
        }

        guard let client = client() else { return }
        isLoading = true
        errorMessage = nil
        do {
            let schema = try await ensureSchema(client)
            var fetched = try await client.fetchOpenTasks(schema: schema)
            let overduePriorityIds = markOverdueTasksImportant(in: &fetched)
            tasks = applySavedOrder(fetched.filter { !pendingDone.contains($0.id) })
            lastRefreshDate = Date()

            if !overduePriorityIds.isEmpty {
                let capturedSchema = schema
                Task { [weak self] in
                    await self?.persistOverduePriorities(overduePriorityIds, client: client, schema: capturedSchema)
                }
            }
        } catch {
            errorMessage = userSafeMessage(for: error)
        }
        isLoading = false

        if pendingRefresh {
            pendingRefresh = false
            await refresh(force: false)
        }
    }

    private func client() -> NotionClient? {
        guard isConfigured else { return nil }
        return NotionClient(token: token, databaseId: databaseId)
    }

    private func userSafeMessage(for error: Error) -> String {
        if let notionError = error as? NotionError {
            return notionError.localizedDescription
        }
        if let keychainError = error as? KeychainError {
            return keychainError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "You appear to be offline."
            case .timedOut:
                return "The request timed out. Try again in a moment."
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                return "Could not connect to Notion. Check your network."
            default:
                return "A network error occurred. Try again in a moment."
            }
        }
        return "Something went wrong. Try again in a moment."
    }

    private func ensureSchema(_ client: NotionClient) async throws -> NotionSchema {
        if let schema { return schema }
        let fetched = try await client.fetchSchema()
        schema = fetched
        return fetched
    }

    private func markOverdueTasksImportant(in fetched: inout [TaskItem]) -> [String] {
        var promotedIds: [String] = []
        for index in fetched.indices where fetched[index].isOverdue && !fetched[index].important {
            fetched[index].important = true
            promotedIds.append(fetched[index].id)
        }
        return promotedIds
    }

    private func persistOverduePriorities(_ taskIds: [String], client: NotionClient, schema: NotionSchema) async {
        guard schema.selectProperty != nil else { return }
        for taskId in taskIds {
            do {
                try await client.setImportant(pageId: taskId, important: true, schema: schema)
            } catch {
                errorMessage = userSafeMessage(for: error)
            }
        }
    }

    func addTask(title: String) async {
        guard let client = client() else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addResetTask?.cancel()
        addState = .adding
        do {
            let parsed = await TaskParser.parse(trimmed)
            let schema = try await ensureSchema(client)
            try await client.addTask(title: parsed.title, dueDate: parsed.dueDate ?? Date(), schema: schema)

            let calendar = Calendar.current
            let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: Date()))!
            if let due = parsed.dueDate, due >= dayAfterTomorrow {
                addState = .added(dateLabel: Self.addedDateFormatter.string(from: due))
            } else {
                addState = .added(dateLabel: nil)
            }
            scheduleAddReset()
            await refresh(force: true)
        } catch {
            addState = .idle
            errorMessage = userSafeMessage(for: error)
        }
    }

    private func scheduleAddReset() {
        addResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.addState = .idle
        }
    }

    func toggleImportant(_ task: TaskItem) async {
        guard let client = client() else { return }
        let newValue = !task.important
        // Optimistic: flip locally first, revert via refresh on failure.
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].important = newValue
            // Starring promotes to the top; un-starring demotes to the bottom.
            withAnimation(.snappy(duration: 0.3)) {
                let item = tasks.remove(at: index)
                tasks.insert(item, at: newValue ? 0 : tasks.endIndex)
            }
            persistOrderIfChanged()
        }
        do {
            let schema = try await ensureSchema(client)
            try await client.setImportant(pageId: task.id, important: newValue, schema: schema)
        } catch {
            errorMessage = userSafeMessage(for: error)
            await refresh(force: true)
        }
    }

    // MARK: - Manual ordering (local only — Notion's API has no row order)

    /// Moves the dragged task to just before the drop target.
    func move(_ draggedId: String, before targetId: String) {
        guard draggedId != targetId,
              let from = tasks.firstIndex(where: { $0.id == draggedId }) else { return }
        withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
            let item = tasks.remove(at: from)
            if let to = tasks.firstIndex(where: { $0.id == targetId }) {
                tasks.insert(item, at: to)
            } else {
                tasks.insert(item, at: from)
            }
        }
        persistOrderIfChanged()
    }

    /// Moves the dragged task to the end of the local order.
    func moveToBottom(_ draggedId: String) {
        guard let from = tasks.firstIndex(where: { $0.id == draggedId }),
              from != tasks.index(before: tasks.endIndex) else { return }
        withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
            let item = tasks.remove(at: from)
            tasks.append(item)
        }
        persistOrderIfChanged()
    }

    private func applySavedOrder(_ fetched: [TaskItem]) -> [TaskItem] {
        let order = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        guard !order.isEmpty else { return fetched }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return fetched.enumerated()
            .sorted { a, b in
                let posA = position[a.element.id] ?? order.count + a.offset
                let posB = position[b.element.id] ?? order.count + b.offset
                return posA < posB
            }
            .map(\.element)
    }

    func toggleDone(_ task: TaskItem) async {
        guard let client = client() else { return }
        pendingDone.insert(task.id)
        undoableDoneTask = task
        scheduleUndoReset(for: task.id)
        withAnimation(.snappy(duration: 0.3)) {
            tasks.removeAll { $0.id == task.id }
        }
        do {
            let schema = try await ensureSchema(client)
            try await client.setDone(pageId: task.id, done: true, schema: schema)
            if undoneWhilePending.remove(task.id) != nil {
                try await client.setDone(pageId: task.id, done: false, schema: schema)
            }
            pendingDone.remove(task.id)
        } catch {
            pendingDone.remove(task.id)
            undoneWhilePending.remove(task.id)
            if undoableDoneTask?.id == task.id {
                undoResetTask?.cancel()
                undoableDoneTask = nil
            }
            errorMessage = userSafeMessage(for: error)
            await refresh(force: true)
        }
    }

    private func scheduleUndoReset(for taskId: String) {
        undoResetTask?.cancel()
        undoResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, self?.undoableDoneTask?.id == taskId else { return }
            withAnimation(.snappy(duration: 0.25)) {
                self?.undoableDoneTask = nil
            }
        }
    }

    func undoLastDone() async {
        guard let task = undoableDoneTask,
              let client = client() else { return }
        undoResetTask?.cancel()
        undoableDoneTask = nil
        if pendingDone.contains(task.id) {
            undoneWhilePending.insert(task.id)
        }
        restore(task)
        do {
            let schema = try await ensureSchema(client)
            try await client.setDone(pageId: task.id, done: false, schema: schema)
        } catch {
            errorMessage = userSafeMessage(for: error)
            await refresh(force: true)
        }
    }

    private func restore(_ task: TaskItem) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
            tasks.append(task)
            tasks = applySavedOrder(tasks)
        }
    }
}
