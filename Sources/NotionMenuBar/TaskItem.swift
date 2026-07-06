import Foundation

struct TaskItem: Identifiable, Equatable {
    let id: String
    var title: String
    var url: String
    var dueDate: Date?
    var important: Bool = false
    var isOverdue: Bool = false
    var daysOverdue: Int = 0

    static func overdueFields(for dueDate: Date?, calendar: Calendar = .current, today: Date = Date()) -> (isOverdue: Bool, daysOverdue: Int) {
        guard let dueDate else { return (false, 0) }
        let dueStart = calendar.startOfDay(for: dueDate)
        let todayStart = calendar.startOfDay(for: today)
        guard dueStart < todayStart else { return (false, 0) }
        let days = calendar.dateComponents([.day], from: dueStart, to: todayStart).day ?? 0
        return (true, days)
    }
}
