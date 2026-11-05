import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The board fits the notch's available space; each lane owns its scroll area.
/// Card chrome uses quiet dark fills to remain legible on the black notch.
struct TaskKanbanBoard: View {
    @ObservedObject var controller: TaskController
    @State private var dragSession = UUID()
    private let minimumBoardWidth: CGFloat = 3 * 185 + 2 * 8

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < minimumBoardWidth {
                ScrollView(.horizontal) {
                    columns
                        .frame(width: minimumBoardWidth, height: max(0, geometry.size.height - 16))
                        .padding(.bottom, 16)
                }
                .scrollIndicators(.automatic, axes: .horizontal)
            } else {
                columns.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.selectedListID) { _, _ in dragSession = UUID() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task board")
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(TaskKanbanColumn.allCases, id: \.self) { column in
                TaskKanbanLane(controller: controller, column: column, dragSession: dragSession)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TaskKanbanDragPayload: Codable, Transferable {
    let taskID: String
    let listID: String
    let boardSession: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .heyNotchTaskMove)
    }
}

private extension UTType {
    static let heyNotchTaskMove = UTType(exportedAs: "com.wolfieeee.heynotch.task-move", conformingTo: .data)
}

private extension TaskKanbanColumn {
    var accent: Color {
        switch self {
        case .todo: return Color.white.opacity(0.65)
        case .doing: return Color.orange.opacity(0.9)
        case .done: return Color.green.opacity(0.8)
        }
    }
    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle"
        }
    }
    var emptyTitle: String {
        switch self {
        case .todo: return "Nothing waiting"
        case .doing: return "Room to focus"
        case .done: return "A fresh start"
        }
    }
    var emptyDetail: String {
        switch self {
        case .todo: return "Add a task when you're ready."
        case .doing: return "Move a task here to begin."
        case .done: return "Completed tasks appear here."
        }
    }
}

private struct TaskKanbanLane: View {
    @ObservedObject var controller: TaskController
    let column: TaskKanbanColumn
    let dragSession: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    private var items: [ReminderTask] { controller.tasks(in: column) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(column.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(column.title).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text("\(items.count)").font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.white.opacity(0.05), in: Capsule())
                Spacer(minLength: 0)
                if targeted { Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(column.accent).accessibilityHidden(true) }
            }
            .padding(.horizontal, 10).padding(.top, 11).padding(.bottom, 9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(column.title), \(items.count) tasks")
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if items.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Image(systemName: column.symbol).font(.system(size: 17, weight: .light))
                                .foregroundStyle(column.accent.opacity(0.65)).padding(.bottom, 3)
                            Text(column.emptyTitle).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                            Text(column.emptyDetail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(items) { item in
                        TaskKanbanCard(controller: controller, item: item, column: column,
                                       dragPayload: TaskKanbanDragPayload(taskID: item.id, listID: item.listID, boardSession: dragSession))
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 185, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(targeted ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(targeted ? column.accent.opacity(0.6) : Color.white.opacity(0.045), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: targeted)
        .dropDestination(for: TaskKanbanDragPayload.self) { payloads, _ in
            guard payloads.count == 1, let payload = payloads.first,
                  payload.boardSession == dragSession,
                  payload.listID == controller.selectedListID,
                  let item = controller.visibleTasks.first(where: { $0.id == payload.taskID && $0.listID == payload.listID }),
                  controller.canMoveTask(item), controller.column(for: item) != column else { return false }
            Task { await controller.moveTask(item, to: column) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct TaskKanbanCard: View {
    @ObservedObject var controller: TaskController
    let item: ReminderTask
    let column: TaskKanbanColumn
    let dragPayload: TaskKanbanDragPayload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var pending: Bool { controller.pendingTaskIDs.contains(item.id) }
    private var overdue: Bool { TaskSection.section(for: item, now: Date(), calendar: .current) == .overdue }
    private var dueLabel: String? {
        guard let due = item.due, let date = due.date(in: .current) else { return nil }
        let day: String
        if Calendar.current.isDateInToday(date) { day = "Today" }
        else if Calendar.current.isDateInTomorrow(date) { day = "Tomorrow" }
        else { day = date.formatted(.dateTime.month(.abbreviated).day()) }
        return due.hasTime ? day + " · " + date.formatted(date: .omitted, time: .shortened) : day
    }

    var body: some View {
        Button { controller.editInWindow(item) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(item.completed ? 0.6 : 0.9))
                    .strikethrough(item.completed, color: .white.opacity(0.35))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    .padding(.trailing, 21)
                HStack(spacing: 5) {
                    if let dueLabel {
                        Label(dueLabel, systemImage: overdue ? "exclamationmark.circle" : "calendar")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(overdue ? Color(red: 1, green: 0.5, blue: 0.43) : .white.opacity(0.6))
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(overdue ? Color.red.opacity(0.09) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel("\(overdue ? "Overdue, " : "")\(dueLabel)")
                    } else {
                        Text("No due date").font(.system(size: 9)).foregroundStyle(.white.opacity(0.46))
                    }
                    if item.recurring { Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Repeating task") }
                    Spacer(minLength: 0)
                    if pending { ProgressView().controlSize(.mini).accessibilityLabel("Updating task") }
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            // The label owns dragging while the surrounding Button retains click-to-edit.
            // Keep the actions Menu outside the drag source so it remains independently usable.
            .draggable(dragPayload) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .padding(12).frame(width: 210, alignment: .leading)
                    .foregroundStyle(.white).background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 11))
            }
        }
        .buttonStyle(.plain).disabled(pending)
        .accessibilityLabel("Edit \(item.title)\(dueLabel.map { ", \(overdue ? "overdue, " : "")\($0)" } ?? ""), \(column.title)")
        .background(.white.opacity(hovered ? 0.095 : 0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(hovered ? 0.13 : 0.055), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Edit task…") { controller.editInWindow(item) }
                Divider()
                ForEach(TaskKanbanColumn.allCases, id: \.self) { destination in
                    Button {
                        Task { await controller.moveTask(item, to: destination) }
                    } label: {
                        Label("Move to \(destination.title)", systemImage: destination.symbol)
                    }.disabled(column == destination || !controller.canMoveTask(item))
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.5))
                    .frame(width: 23, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(pending)
            .padding(5)
            .accessibilityLabel("Actions for \(item.title)").help("Move or edit task")
        }
        .contextMenu {
            Button("Edit task…") { controller.editInWindow(item) }.disabled(pending)
            ForEach(TaskKanbanColumn.allCases, id: \.self) { destination in
                Button("Move to \(destination.title)") { Task { await controller.moveTask(item, to: destination) } }
                    .disabled(column == destination || !controller.canMoveTask(item))
            }
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .contain)
    }
}
