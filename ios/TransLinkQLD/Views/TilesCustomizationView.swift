import SwiftUI

struct TilesCustomizationView: View {
    @Binding var rawOrder: String
    @Environment(\.dismiss) private var dismiss
    @State private var order: [MapTileKind]

    init(rawOrder: Binding<String>) {
        self._rawOrder = rawOrder
        self._order = State(initialValue: MapTileOrder.decode(rawOrder.wrappedValue))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { tile in
                        HStack(spacing: 12) {
                            Image(systemName: tile.iconName)
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            Text(tile.label)
                        }
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                    }
                } header: {
                    Text("Drag the rows to reorder the tiles on the map")
                        .textCase(nil)
                } footer: {
                    Text("Long-press any tile on the map to reopen this customizer.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize tiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        rawOrder = MapTileOrder.encode(order)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset to defaults") {
                        order = MapTileOrder.defaultOrder
                    }
                }
            }
        }
    }
}
