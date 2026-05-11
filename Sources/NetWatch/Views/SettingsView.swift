import SwiftUI

struct SettingsView: View {
    @State private var targets: [TravelTarget] = TravelModeStore.load()
    @AppStorage("costPerGB") private var costPerGB: Double = 4.0
    @State private var costInput: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    Text("Cost estimate")
                        .font(.headline)

                    HStack {
                        Text("$")
                        TextField("4.00", text: $costInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onSubmit { commitCost() }
                        Text("per GB")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Button("Set") { commitCost() }
                            .controlSize(.small)
                    }
                }

                Divider()

                Text("Travel Mode targets")
                    .font(.headline)

                Text("These apps and services will be quit when you toggle Travel Mode on. Uncheck the ones you want to keep running.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach($targets) { $target in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $target.enabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.displayName)
                                .font(.callout)
                            if let bid = target.bundleId {
                                Text(bid).font(.caption2).foregroundColor(.secondary)
                            } else if let ld = target.launchdLabel {
                                Text("launchd: \(ld)").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    Button("Save") {
                        TravelModeStore.save(targets)
                    }
                    .controlSize(.small)

                    Button("Reset to defaults") {
                        targets = TravelModeStore.defaultTargets
                        TravelModeStore.save(targets)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(12)
        }
        .onAppear {
            costInput = String(format: "%.2f", costPerGB)
        }
    }

    private func commitCost() {
        if let v = Double(costInput.replacingOccurrences(of: ",", with: ".")), v >= 0 {
            costPerGB = v
        }
        costInput = String(format: "%.2f", costPerGB)
    }
}
