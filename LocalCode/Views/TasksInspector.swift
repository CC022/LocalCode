import AgentCore
import SwiftUI

struct TasksInspector: View {
    @Environment(AppState.self) private var app

    private var todos: [TodoItem] { app.loop?.todos ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tasks").font(.headline)
                Spacer()
                if !todos.isEmpty {
                    Text("\(completedCount)/\(todos.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if todos.isEmpty {
                Image(systemName: "checklist")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(todos) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: item.status))
                            .foregroundStyle(color(for: item.status))
                            .padding(.top, 2)
                        Text(item.content)
                            .strikethrough(item.status == .completed, color: .secondary)
                            .foregroundStyle(item.status == .completed ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 240, idealWidth: 280)
    }

    private var completedCount: Int {
        todos.filter { $0.status == .completed }.count
    }

    private func icon(for status: TodoItem.Status) -> String {
        switch status {
        case .pending:     "circle"
        case .in_progress: "arrow.right.circle.fill"
        case .completed:   "checkmark.circle.fill"
        }
    }

    private func color(for status: TodoItem.Status) -> Color {
        switch status {
        case .pending:     .secondary
        case .in_progress: .accentColor
        case .completed:   .green
        }
    }
}
