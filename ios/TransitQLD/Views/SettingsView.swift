import SwiftUI

struct SettingsView: View {
    @Binding var rawOrder: String
    @Environment(\.dismiss) private var dismiss
    @State private var order: [MapTileKind]
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue

    init(rawOrder: Binding<String>) {
        self._rawOrder = rawOrder
        self._order = State(initialValue: MapTileOrder.decode(rawOrder.wrappedValue))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
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
                    Text("Drag to reorder the tiles on the map")
                        .textCase(nil)
                }

                Section {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.iconName)
                                .tag(mode.rawValue)
                        }
                    }
                } header: {
                    Text("Appearance")
                        .textCase(nil)
                } footer: {
                    Text("System follows your iPhone setting. Choose Light or Dark to override it for TransitQLD only.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(appVersion) (\(appBuild))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Link(destination: URL(string: "https://translink-qld.kedarkokate.workers.dev/privacy")!) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("About TransitQLD")
                        .textCase(nil)
                } footer: {
                    Text("Schedule and realtime transit data published by the Queensland Department of Transport and Main Roads under CC-BY 4.0 via TransLink Open Data. Coverage is limited to South-East Queensland — Rockhampton, Toowoomba and other regions are not in this feed.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        rawOrder = MapTileOrder.encode(order)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .buttonStyle(.borderedProminent)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset tile order") {
                        order = MapTileOrder.defaultOrder
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
