import Foundation
import FoundationModels

struct ParsedTask {
    var title: String
    var dueDate: Date?
}

@Generable
private struct TaskExtraction {
    @Guide(description: "The task title copied word-for-word from the user's text, with only the date/time phrase removed. Never invent, abbreviate, or rephrase words.")
    var title: String

    @Guide(description: "The due date in exactly YYYY-MM-DD format if one is mentioned or implied, otherwise an empty string")
    var dueDate: String
}

@MainActor
enum TaskParser {
    private static var cachedSession: LanguageModelSession?
    private static var sessionUses = 0

    /// Apple's deterministic date detector runs first; the on-device LLM is
    /// only consulted when the detector finds nothing, and its output is
    /// validated against the input so it can never mangle the task text.
    static func parse(_ input: String) async -> ParsedTask {
        let normalized = expandDayAbbreviations(input)
        let detected = parseWithDetector(normalized)
        if detected.dueDate != nil { return detected }

        if case .available = SystemLanguageModel.default.availability,
           var modelParsed = try? await parseWithModel(normalized),
           isValid(modelParsed, input: normalized) {
            // A due date is only plausible if the model actually removed a
            // date phrase from the input; otherwise it hallucinated one.
            if wordCount(modelParsed.title) >= wordCount(normalized) {
                modelParsed.dueDate = nil
            }
            return modelParsed
        }
        return detected
    }

    private static let dayAbbreviations: [String: String] = [
        "mon": "Monday",
        "tue": "Tuesday", "tues": "Tuesday",
        "wed": "Wednesday",
        "thu": "Thursday", "thur": "Thursday", "thurs": "Thursday",
        "fri": "Friday",
        "sat": "Saturday",
        "sun": "Sunday"
    ]

    /// Expands day abbreviations ("email Sam fri" → "email Sam Friday") so the
    /// date detector can resolve them. Only expands in date positions — the
    /// last word or right after a date cue — so words like "sun" in
    /// "buy sun screen" are left alone.
    private static func expandDayAbbreviations(_ input: String) -> String {
        let dateCues: Set<String> = ["on", "by", "next", "this", "due", "for", "until", "til", "before", "every"]
        var words = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices {
            let raw = words[index]
            let token = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard let fullName = dayAbbreviations[token.lowercased()] else { continue }
            let isLastWord = index == words.count - 1
            let followsDateCue = index > 0 && dateCues.contains(words[index - 1].lowercased())
            if isLastWord || followsDateCue {
                words[index] = raw.replacingOccurrences(of: token, with: fullName)
            }
        }
        return words.joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    private static func isValid(_ parsed: ParsedTask, input: String) -> Bool {
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }

        let split: (String) -> [String] = { text in
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let inputWords = Set(split(input))
        let titleWords = split(title)
        guard !titleWords.isEmpty else { return false }
        // Every word in the title must come from the input, otherwise the
        // model hallucinated or rewrote the task.
        return titleWords.allSatisfy { inputWords.contains($0) }
    }

    /// Reuses one session across parses (creating a session is the slow part),
    /// recycling it every few uses so its transcript doesn't grow unbounded.
    private static func session() -> LanguageModelSession {
        if let existing = cachedSession, !existing.isResponding, sessionUses < 6 {
            sessionUses += 1
            return existing
        }
        let fresh = LanguageModelSession(instructions: """
            You extract a to-do task from the user's text. \
            Copy the task title word-for-word from the input, removing only the date or time phrase. \
            Resolve relative dates like "tomorrow" or "next Friday" against the current date given \
            with each request, and output them as YYYY-MM-DD. \
            If no date is mentioned, leave dueDate as an empty string.
            """)
        cachedSession = fresh
        sessionUses = 1
        return fresh
    }

    private static func parseWithModel(_ input: String) async throws -> ParsedTask {
        let today = dateFormatter.string(from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date())
        let weekdayName = DateFormatter().weekdaySymbols[weekday - 1]

        let prompt = "Current date: \(weekdayName), \(today)\nTask: \(input)"
        let response = try await session().respond(to: prompt, generating: TaskExtraction.self)
        let extraction = response.content

        var dueDate: Date?
        let dateString = extraction.dueDate.trimmingCharacters(in: .whitespaces)
        if dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            dueDate = dateFormatter.date(from: dateString)
        }
        let title = extraction.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTask(title: title.isEmpty ? input : title, dueDate: dueDate)
    }

    private static func parseWithDetector(_ input: String) -> ParsedTask {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return ParsedTask(title: input, dueDate: nil)
        }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = detector.firstMatch(in: input, options: [], range: range),
              let date = match.date,
              let matchRange = Range(match.range, in: input) else {
            return ParsedTask(title: input, dueDate: nil)
        }

        var title = input
        title.removeSubrange(matchRange)
        // Strip dangling connectors left behind, e.g. "Email Sam on" -> "Email Sam"
        let connectors = ["on", "by", "due", "at", "for", "before"]
        var words = title.split(separator: " ").map(String.init)
        while let last = words.last, connectors.contains(last.lowercased()) {
            words.removeLast()
        }
        title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTask(title: title.isEmpty ? input : title, dueDate: date)
    }
}
