import Foundation

/// Stacks of pieces on the hex grid. `cells` never contains empty stacks.
public struct Board: Hashable, Codable, Sendable {
    public private(set) var cells: [Hex: [Piece]] = [:]

    public init() {}

    public var isEmpty: Bool { cells.isEmpty }
    public var occupiedHexes: [Hex] { Array(cells.keys) }
    public var pieceCount: Int { cells.values.reduce(0) { $0 + $1.count } }

    public func stack(at hex: Hex) -> [Piece] { cells[hex] ?? [] }
    public func height(at hex: Hex) -> Int { cells[hex]?.count ?? 0 }
    public func top(at hex: Hex) -> Piece? { cells[hex]?.last }
    public func isOccupied(_ hex: Hex) -> Bool { height(at: hex) > 0 }

    public func pieces(of color: PlayerColor) -> [Piece] {
        cells.values.flatMap { $0 }.filter { $0.color == color }
    }

    public func position(ofPieceID id: String) -> Hex? {
        for (hex, stack) in cells where stack.contains(where: { $0.id == id }) {
            return hex
        }
        return nil
    }

    public mutating func push(_ piece: Piece, at hex: Hex) {
        cells[hex, default: []].append(piece)
    }

    @discardableResult
    public mutating func pop(at hex: Hex) -> Piece? {
        guard var stack = cells[hex], !stack.isEmpty else { return nil }
        let piece = stack.removeLast()
        if stack.isEmpty {
            cells[hex] = nil
        } else {
            cells[hex] = stack
        }
        return piece
    }

    /// Board with the top piece at `hex` removed. No-op if empty.
    public func removingTop(at hex: Hex) -> Board {
        var copy = self
        copy.pop(at: hex)
        return copy
    }

    /// One Hive rule: would the hive stay connected if the top piece at `hex` were lifted?
    public func remainsConnectedRemovingTop(at hex: Hex) -> Bool {
        // Lifting from a stack of 2+ leaves the cell occupied; always connected.
        if height(at: hex) > 1 { return true }
        let remaining = Set(cells.keys).subtracting([hex])
        guard let start = remaining.first else { return true }
        var visited: Set<Hex> = [start]
        var frontier = [start]
        while let current = frontier.popLast() {
            for n in current.neighbors where remaining.contains(n) && !visited.contains(n) {
                visited.insert(n)
                frontier.append(n)
            }
        }
        return visited.count == remaining.count
    }

    /// Is the hex empty and adjacent to at least one occupied hex?
    public func isEmptyAdjacentToHive(_ hex: Hex) -> Bool {
        !isOccupied(hex) && hex.neighbors.contains(where: isOccupied)
    }
}
