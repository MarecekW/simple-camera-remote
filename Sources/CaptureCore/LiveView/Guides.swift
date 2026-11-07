import Foundation

/// Positioning guides over the live view, as in Photoshop: dragged out of
/// the rulers, moved, and dragged back off the image to remove.  Positions
/// are fractions of the image, so guides stay put however it's displayed.
public struct Guides: Codable, Equatable, Sendable {
    public struct Guide: Codable, Equatable, Identifiable, Sendable {
        public enum Axis: String, Codable, Sendable {
            /// A line across the image, at a height.
            case horizontal
            /// A line down the image, at a distance from the left.
            case vertical
        }

        public let id: UUID
        public let axis: Axis
        /// 0…1 down (horizontal) or across (vertical) the image.
        public var position: Double
    }

    public private(set) var all: [Guide] = []

    public init() {}

    /// A new guide; returns its id, for moving it while it's dragged out.
    @discardableResult
    public mutating func add(_ axis: Guide.Axis, at position: Double) -> UUID {
        let guide = Guide(id: UUID(), axis: axis, position: position)
        all.append(guide)
        return guide.id
    }

    public mutating func move(_ id: UUID, to position: Double) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].position = position
    }

    /// Ends a drag: a guide let go off the image is removed, one on it is
    /// kept.
    public mutating func finishDragging(_ id: UUID) {
        guard let guide = all.first(where: { $0.id == id }) else { return }
        if !(0...1).contains(guide.position) { remove(id) }
    }

    public mutating func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        all = []
    }

    /// Drops guides left off the image — e.g. by a drag that was cut short.
    public mutating func removeOffImage() {
        all.removeAll { !(0...1).contains($0.position) }
    }
}
