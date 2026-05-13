import Foundation
import SwiftUI

/// Whether the action tiles stack as a column or a row.
enum TileOrientation: String, CaseIterable, Codable, Identifiable {
    case vertical
    case horizontal

    static let storageKey = "map_tile_orientation_v1"
    static let defaultValue: TileOrientation = .vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        }
    }

    var iconName: String {
        switch self {
        case .vertical: return "rectangle.split.1x3"
        case .horizontal: return "rectangle.split.3x1"
        }
    }
}


/// Where the action-tile stack floats on the map. User-selectable via the
/// long-press menu; persisted in `@AppStorage`.
enum TilePosition: String, CaseIterable, Codable, Identifiable {
    case topLeading
    case topTrailing
    case centerLeading
    case centerTrailing
    case bottomLeading
    case bottomTrailing

    static let storageKey = "map_tile_position_v1"
    static let defaultValue: TilePosition = .topLeading

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeading: return "Top left"
        case .topTrailing: return "Top right"
        case .centerLeading: return "Center left"
        case .centerTrailing: return "Center right"
        case .bottomLeading: return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        }
    }

    var iconName: String {
        switch self {
        case .topLeading: return "arrow.up.left"
        case .topTrailing: return "arrow.up.right"
        case .centerLeading: return "arrow.left"
        case .centerTrailing: return "arrow.right"
        case .bottomLeading: return "arrow.down.left"
        case .bottomTrailing: return "arrow.down.right"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .centerLeading: return .leading
        case .centerTrailing: return .trailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var isTrailing: Bool {
        switch self {
        case .topTrailing, .centerTrailing, .bottomTrailing: return true
        default: return false
        }
    }

    var stackAlignment: HorizontalAlignment {
        isTrailing ? .trailing : .leading
    }

    var transitionEdge: Edge {
        isTrailing ? .trailing : .leading
    }

    /// Padding from the nearest screen edge(s). 12pt horizontal, 10pt vertical,
    /// applied only on the edge closest to the chosen corner so the stack
    /// hugs the wall while keeping clear of the opposite side.
    var edgeInsets: EdgeInsets {
        let h: CGFloat = 12
        let v: CGFloat = 10
        switch self {
        case .topLeading:     return EdgeInsets(top: v, leading: h, bottom: 0, trailing: 0)
        case .topTrailing:    return EdgeInsets(top: v, leading: 0, bottom: 0, trailing: h)
        case .centerLeading:  return EdgeInsets(top: 0, leading: h, bottom: 0, trailing: 0)
        case .centerTrailing: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: h)
        case .bottomLeading:  return EdgeInsets(top: 0, leading: h, bottom: v, trailing: 0)
        case .bottomTrailing: return EdgeInsets(top: 0, leading: 0, bottom: v, trailing: h)
        }
    }
}
