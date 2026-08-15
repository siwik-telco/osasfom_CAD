import Foundation

/// Snapshot undo over `CADModelState`.
///
/// Deliberately not `UndoManager`: a plain stack is testable without an app
/// running, has no main-actor/ObjC bridging awkwardness, and — because the whole
/// state is one `Equatable` value — is exactly correct by construction. Undo is
/// nearly impossible to retrofit later, so it is wired in while the mutation
/// surface is still small.
public struct UndoStack: Sendable {
    public struct Entry: Sendable {
        public let actionName: String
        public let state: CADModelState
        /// Consecutive edits sharing a key collapse into one step, so typing a
        /// number does not produce one undo per keystroke.
        public let coalescingKey: String?
    }

    public private(set) var undoEntries: [Entry] = []
    public private(set) var redoEntries: [Entry] = []

    /// Bounds memory; a CAD session can run for hours.
    public let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoActionName: String? { undoEntries.last?.actionName }
    public var redoActionName: String? { redoEntries.last?.actionName }

    /// Records the state *before* a mutation.
    public mutating func record(
        previousState: CADModelState,
        actionName: String,
        coalescingKey: String?
    ) {
        redoEntries.removeAll()

        // An ongoing coalesced run already holds the older pre-state, which is
        // the one we want to return to.
        if let key = coalescingKey, undoEntries.last?.coalescingKey == key {
            return
        }

        undoEntries.append(
            Entry(actionName: actionName, state: previousState, coalescingKey: coalescingKey)
        )
        if undoEntries.count > limit {
            undoEntries.removeFirst(undoEntries.count - limit)
        }
    }

    /// Ends any coalescing run, so the next edit starts a fresh undo step.
    public mutating func breakCoalescing() {
        guard let last = undoEntries.last, last.coalescingKey != nil else { return }
        undoEntries[undoEntries.count - 1] = Entry(
            actionName: last.actionName,
            state: last.state,
            coalescingKey: nil
        )
    }

    /// Returns the state to restore, given the current one.
    public mutating func undo(current: CADModelState) -> (state: CADModelState, actionName: String)? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(
            Entry(actionName: entry.actionName, state: current, coalescingKey: nil)
        )
        return (entry.state, entry.actionName)
    }

    public mutating func redo(current: CADModelState) -> (state: CADModelState, actionName: String)? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(
            Entry(actionName: entry.actionName, state: current, coalescingKey: nil)
        )
        return (entry.state, entry.actionName)
    }

    public mutating func removeAll() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }
}
