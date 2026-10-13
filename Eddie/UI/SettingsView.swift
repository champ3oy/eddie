import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: EditorModel
    @State private var provider = AISettings.provider
    @State private var keys: [ProviderKind: String] = [:]
    @State private var models: [ProviderKind: String] = [:]
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("AI") {
                Picker("Provider", selection: $provider) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: provider) { AISettings.provider = provider; model.objectWillChange.send() }

                SecureField("\(provider.label) API key", text: binding(for: provider, in: $keys) { AISettings.setAPIKey($0, for: provider) })
                TextField("Model", text: binding(for: provider, in: $models) { AISettings.setModel($0, for: provider); model.objectWillChange.send() },
                          prompt: Text(provider.defaultModel))
                HStack {
                    Link("Get a \(provider.label) API key", destination: provider.keyURL)
                    Spacer()
                    Text("Or set \(provider.environmentKey)").foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Section("Color conversion") {
                LabeledContent("LUT", value: model.lut.title)
                HStack {
                    Button("Choose .cube LUT…") { Panels.chooseLUT(model) }
                    Button("Use DJI Action 4 default") { model.useLUT(at: nil) }
                }
                Text("The LUT turns D-Log M into normal-looking Rec.709 before the AI's knobs apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Performance") {
                Toggle("Smooth playback for 4K (1080p proxies)", isOn: $model.useProxies)
                Text("Eddie makes light copies of 4K clips for the viewer. Export always uses your original files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    LabeledContent("Cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Spacer()
                    Button("Clear Cache") { model.clearCaches(); cacheSize = MediaCache.size() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            cacheSize = MediaCache.size()
            for kind in ProviderKind.allCases {
                keys[kind] = Keychain.read(account: kind.rawValue) ?? ""
                let m = AISettings.model(for: kind)
                models[kind] = m == kind.defaultModel ? "" : m
            }
        }
    }

    private func binding(for kind: ProviderKind, in dict: Binding<[ProviderKind: String]>,
                         save: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { dict.wrappedValue[kind] ?? "" }, set: { dict.wrappedValue[kind] = $0; save($0) })
    }
}
