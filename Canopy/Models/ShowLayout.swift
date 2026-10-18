import Foundation

/// Which device a Show Mode tile watches. Devices are referenced by id (not
/// copied), so renaming or re-addressing one is reflected in every view it's on.
enum ShowDevice: Codable, Hashable {
    case hyperDeck(UUID)
    case cloudStore(UUID)
    /// A wireless receiver or IEM transmitter, by its inventory id.
    case wireless(String)
    /// Every in-progress workflow run.
    case activeRuns

    /// Tile size, in grid cells, a device starts at when added to a view.
    var defaultSize: (width: Int, height: Int) {
        switch self {
        case .hyperDeck:  (4, 2)
        case .cloudStore: (3, 1)
        case .wireless:   (6, 3)
        case .activeRuns: (12, 2)
        }
    }
}

/// One device placed on a view, positioned on a grid of `ShowScreen.columns`
/// columns; rows are unlimited and grow downward.
struct ShowTile: Identifiable, Codable, Hashable {
    var id = UUID()
    var device: ShowDevice
    var col: Int
    var row: Int
    var width: Int
    var height: Int

    func overlaps(_ other: ShowTile) -> Bool {
        col < other.col + other.width && other.col < col + width
            && row < other.row + other.height && other.row < row + height
    }
}

/// A named Show Mode view: the devices on it and where each sits.
struct ShowScreen: Identifiable, Codable, Hashable {
    static let columns = 12
    static let maxSpan = 12
    static let maxRows = 40

    var id = UUID()
    var name: String
    var tiles: [ShowTile] = []

    /// The first row below every tile, i.e. how tall the layout currently is.
    var rowCount: Int { tiles.map { $0.row + $0.height }.max() ?? 0 }

    func contains(_ device: ShowDevice) -> Bool { tiles.contains { $0.device == device } }

    /// Whether a tile with this frame would sit inside the grid without touching another tile.
    func canPlace(_ tileID: UUID?, col: Int, row: Int, width: Int, height: Int) -> Bool {
        guard width >= 1, height >= 1,
              col >= 0, row >= 0,
              col + width <= Self.columns, row + height <= Self.maxRows else { return false }
        let probe = ShowTile(device: .activeRuns, col: col, row: row, width: width, height: height)
        return !tiles.contains { $0.id != tileID && $0.overlaps(probe) }
    }

    /// The top-left-most free spot a `width` × `height` tile fits, scanning row by row.
    func freeSpot(width: Int, height: Int) -> (col: Int, row: Int) {
        let width = min(width, Self.columns)
        for row in 0..<Self.maxRows {
            for col in 0...(Self.columns - width) where canPlace(nil, col: col, row: row, width: width, height: height) {
                return (col, row)
            }
        }
        return (0, rowCount)
    }

    /// Adds a device at its default size in the first free spot. No-op if it's already here.
    @discardableResult
    mutating func add(_ device: ShowDevice) -> Bool {
        guard !contains(device) else { return false }
        let size = device.defaultSize
        let spot = freeSpot(width: size.width, height: size.height)
        tiles.append(ShowTile(device: device, col: spot.col, row: spot.row, width: size.width, height: size.height))
        return true
    }

    /// Moves/resizes a tile; refuses (returns false, nothing changes) if the new frame is off the grid or overlaps another tile.
    @discardableResult
    mutating func place(_ tileID: UUID, col: Int, row: Int, width: Int, height: Int) -> Bool {
        guard let i = tiles.firstIndex(where: { $0.id == tileID }),
              canPlace(tileID, col: col, row: row, width: width, height: height) else { return false }
        tiles[i].col = col
        tiles[i].row = row
        tiles[i].width = width
        tiles[i].height = height
        return true
    }

    mutating func remove(_ tileID: UUID) { tiles.removeAll { $0.id == tileID } }

    /// The view a fresh install starts with: active runs across the top, then every deck and storage device.
    static func starter(decks: [HyperDeck], cloudStores: [CloudStore]) -> ShowScreen {
        var screen = ShowScreen(name: "Main")
        screen.add(.activeRuns)
        for d in decks { screen.add(.hyperDeck(d.id)) }
        for c in cloudStores { screen.add(.cloudStore(c.id)) }
        return screen
    }

    /// A copy under a new name with new ids, so editing one never touches the other.
    func duplicated(named newName: String) -> ShowScreen {
        var copy = self
        copy.id = UUID()
        copy.name = newName
        copy.tiles = tiles.map { var t = $0; t.id = UUID(); return t }
        return copy
    }
}
