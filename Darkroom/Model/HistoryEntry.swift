import Foundation

/// One frozen snapshot in the edit timeline.
///
/// Equatable so tests can assert history equality; Identifiable so SwiftUI Lists
/// can track rows across mutations.
struct HistoryEntry: Codable, Equatable, Identifiable {
    let schema: Int
    let id: UUID
    let timestamp: Date
    let name: String
    let state: EditorState

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         name: String,
         state: EditorState) {
        self.schema = 1
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.state = state
    }
}
