import SwiftUI

extension NearbyStop {
    /// SF Symbol used for the map pin / picker row icon, based on what modes
    /// of transport serve this stop. Priority: ferry > rail > bus.
    var modeSymbolName: String {
        if isFerry { return "ferry.fill" }
        if isRail  { return "train.side.front.car" }
        return "bus.fill"
    }

    /// Tint color matching `modeSymbolName`.
    var modeTint: Color {
        if isFerry { return .blue }
        if isRail  { return .orange }
        return .red
    }
}
