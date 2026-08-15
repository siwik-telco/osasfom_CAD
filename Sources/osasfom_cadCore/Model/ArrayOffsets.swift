import Foundation

// `move(fromOffsets:toOffset:)` and `remove(atOffsets:)` ship with SwiftUI, not
// the standard library. Core is deliberately Foundation-only so it can be used
// headlessly, so the two operations the document needs are implemented here.
extension Array {
    public mutating func removeAt(offsets: IndexSet) {
        for index in offsets.sorted(by: >) where indices.contains(index) {
            remove(at: index)
        }
    }

    /// Matches SwiftUI's semantics: `destination` is the index in the *original*
    /// array that the moved run should end up before.
    public mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moved = source.sorted().compactMap { indices.contains($0) ? self[$0] : nil }
        guard !moved.isEmpty else { return }

        let insertionOffset = source.filter { $0 < destination }.count
        removeAt(offsets: source)
        let clampedIndex = Swift.max(0, Swift.min(count, destination - insertionOffset))
        insert(contentsOf: moved, at: clampedIndex)
    }
}
