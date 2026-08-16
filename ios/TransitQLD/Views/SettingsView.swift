import SwiftUI

struct SettingsView: View {
    @Binding var rawOrder: String
    @Environment(\.dismiss) private var dismiss
    @State private var order: [MapTileKind]
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue
    @AppStorage(AppConfig.walkToMKey)   private var walkToM:   Int = AppConfig.defaultWalkM
    @AppStorage(AppConfig.walkFromMKey) private var walkFromM: Int = AppConfig.defaultWalkM

    /// Valid walk-distance range and step size in metres.
    private static let walkRange  = 100...2000
    private static let walkStep   = 50

    init(rawOrder: Binding<String>) {
        self._rawOrder = rawOrder
        self._order = State(initialValue: MapTileOrder.decode(rawOrder.wrappedValue))
    }

    // MARK: Helpers

    /// A stepper row that increments/decrements a walk-distance value in
    // steps of `walkStep` metres, clamped to `walkRange`.
    private func walkStepper(label: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: Self.walkRange, step: Self.walkStep) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue) m")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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
                    Button {
                        order = MapTileOrder.defaultOrder
                    } label: {
                        Label("Reset to defaults", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(.red)
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
                    Text("System follows your iPhone setting. Choose Light or Dark to override it for Transit QLD only.")
                }

                Section {
                    walkStepper(
                        label: "Walk to stop",
                        value: $walkToM,
                    )
                    walkStepper(
                        label: "Walk from stop",
                        value: $walkFromM,
                    )
                } header: {
                    Text("Journey Planner")
                        .textCase(nil)
                } footer: {
                    Text("Maximum walking distance on each leg of a directions search. Increase if your nearest stops are further away; decrease to see only options within a short walk.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(appVersion) (\(appBuild))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Link(destination: URL(string: "https://translink-qld.transitqld.workers.dev/privacy")!) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ShareLink(
                        item: AppConfig.appStoreURL,
                        subject: Text("Transit QLD"),
                        message: Text("Live SEQ bus, train and ferry times — get Transit QLD on the App Store:"),
                    ) {
                        HStack {
                            Text("Share Transit QLD")
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("About Transit QLD")
                        .textCase(nil)
                } footer: {
                    Text("Schedule and realtime transit data published by the Queensland Department of Transport and Main Roads under CC-BY 4.0 via TransLink Open Data. Coverage is limited to South-East Queensland — Rockhampton, Toowoomba and other regions are not in this feed.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Settings")
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
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
            }
        }
    }
}
