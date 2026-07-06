import Foundation

struct NotionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Property names discovered from the user's database, so the app works
/// regardless of what the columns are actually called.
struct NotionSchema {
    var titleProperty: String
    var doneProperty: String?
    var dateProperty: String?
    /// Select property whose "Priority" option flags high-priority tasks.
    var selectProperty: String?
}

struct NotionClient {
    var token: String
    var databaseId: String

    private let baseURL = URL(string: "https://api.notion.com/v1")!

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func fetchSchema() async throws -> NotionSchema {
        let request = makeRequest(path: "databases/\(databaseId)", method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let properties = json["properties"] as? [String: Any]
        else {
            throw NotionError(message: "Could not read the database schema.")
        }

        var titleProperty = "Name"
        var doneProperty: String?
        var dateProperty: String?
        var selectProperty: String?

        for (name, value) in properties {
            guard let prop = value as? [String: Any], let type = prop["type"] as? String else { continue }
            switch type {
            case "title":
                titleProperty = name
            case "checkbox":
                if doneProperty == nil || name == "Done" { doneProperty = name }
            case "date":
                if dateProperty == nil || name == "Date" || name == "Due" { dateProperty = name }
            case "select":
                if selectProperty == nil || name == "Priority" || name == "Important" { selectProperty = name }
            default:
                break
            }
        }

        return NotionSchema(
            titleProperty: titleProperty,
            doneProperty: doneProperty,
            dateProperty: dateProperty,
            selectProperty: selectProperty
        )
    }

    func fetchOpenTasks(schema: NotionSchema) async throws -> [TaskItem] {
        var request = makeRequest(path: "databases/\(databaseId)/query", method: "POST")
        var body: [String: Any] = [
            "sorts": [["timestamp": "created_time", "direction": "ascending"]]
        ]
        if let done = schema.doneProperty {
            body["filter"] = ["property": done, "checkbox": ["equals": false]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else {
            throw NotionError(message: "Unexpected response while fetching tasks.")
        }

        return results.compactMap { result in
            guard
                let id = result["id"] as? String,
                let properties = result["properties"] as? [String: Any],
                let nameProp = properties[schema.titleProperty] as? [String: Any],
                let titleArray = nameProp["title"] as? [[String: Any]]
            else { return nil }

            let title = titleArray.compactMap { $0["plain_text"] as? String }.joined()
            let url = result["url"] as? String ?? "https://notion.so/\(id.replacingOccurrences(of: "-", with: ""))"

            var dueDate: Date?
            if let dateName = schema.dateProperty,
               let dateProp = properties[dateName] as? [String: Any],
               let dateValue = dateProp["date"] as? [String: Any],
               let start = dateValue["start"] as? String {
                dueDate = Self.dateOnlyFormatter.date(from: String(start.prefix(10)))
            }

            var important = false
            if let selectName = schema.selectProperty,
               let selectProp = properties[selectName] as? [String: Any],
               let select = selectProp["select"] as? [String: Any],
               let optionName = select["name"] as? String {
                important = optionName.caseInsensitiveCompare("Priority") == .orderedSame
            }

            let overdue = TaskItem.overdueFields(for: dueDate)
            return TaskItem(
                id: id,
                title: title,
                url: url,
                dueDate: dueDate,
                important: important,
                isOverdue: overdue.isOverdue,
                daysOverdue: overdue.daysOverdue
            )
        }
    }

    static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    func addTask(title: String, dueDate: Date, schema: NotionSchema) async throws {
        var request = makeRequest(path: "pages", method: "POST")
        var properties: [String: Any] = [
            schema.titleProperty: ["title": [["text": ["content": title]]]]
        ]
        if let dateName = schema.dateProperty {
            properties[dateName] = ["date": ["start": Self.dateOnlyFormatter.string(from: dueDate)]]
        }
        let body: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": properties
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data)
    }

    func setImportant(pageId: String, important: Bool, schema: NotionSchema) async throws {
        guard let selectName = schema.selectProperty else {
            throw NotionError(message: "Your database has no select property for marking tasks as Priority.")
        }
        var request = makeRequest(path: "pages/\(pageId)", method: "PATCH")
        let value: Any = important ? ["name": "Priority"] : NSNull()
        let body: [String: Any] = ["properties": [selectName: ["select": value]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data)
    }

    func setDone(pageId: String, done: Bool, schema: NotionSchema) async throws {
        guard let doneName = schema.doneProperty else {
            throw NotionError(message: "Your database has no checkbox property to mark tasks done.")
        }
        var request = makeRequest(path: "pages/\(pageId)", method: "PATCH")
        let body: [String: Any] = ["properties": [doneName: ["checkbox": done]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data)
    }

    private static func checkResponse(_ response: URLResponse, data _: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401:
                throw NotionError(message: "Notion authentication failed. Check your integration token.")
            case 403:
                throw NotionError(message: "Notion permission denied. Share the database with your integration.")
            case 404:
                throw NotionError(message: "Notion database or page was not found.")
            case 429:
                throw NotionError(message: "Notion is rate limiting requests. Try again in a moment.")
            case 500...599:
                throw NotionError(message: "Notion is temporarily unavailable. Try again shortly.")
            default:
                throw NotionError(message: "Notion request failed with status \(http.statusCode).")
            }
        }
    }
}
