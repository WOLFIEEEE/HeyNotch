import Foundation

enum TaskKanbanColumn: String, CaseIterable, Identifiable, Sendable {
    case todo, doing, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todo: return "To do"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }
}
