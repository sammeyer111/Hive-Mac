import Foundation

/// Axial hex coordinate (pointy-top orientation).
public struct Hex: Hashable, Codable, Sendable {
    public var q: Int
    public var r: Int

    public init(_ q: Int, _ r: Int) {
        self.q = q
        self.r = r
    }

    /// The six neighbor directions, in counterclockwise order.
    public static let directions: [Hex] = [
        Hex(1, 0), Hex(1, -1), Hex(0, -1), Hex(-1, 0), Hex(-1, 1), Hex(0, 1),
    ]

    public static func + (a: Hex, b: Hex) -> Hex { Hex(a.q + b.q, a.r + b.r) }

    public var neighbors: [Hex] { Hex.directions.map { self + $0 } }

    /// Hex (axial) distance between two cells.
    public func distance(to other: Hex) -> Int {
        let dq = other.q - q
        let dr = other.r - r
        return (abs(dq) + abs(dr) + abs(dq + dr)) / 2
    }

    /// For two *adjacent* hexes, the two hexes adjacent to both (the "gate" cells).
    public func commonNeighbors(with other: Hex) -> [Hex] {
        let delta = Hex(other.q - q, other.r - r)
        guard let i = Hex.directions.firstIndex(of: delta) else { return [] }
        return [self + Hex.directions[(i + 1) % 6], self + Hex.directions[(i + 5) % 6]]
    }
}
