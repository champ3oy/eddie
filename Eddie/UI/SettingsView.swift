import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: EditorModel
    @State private var provider = AISettings.provider
    @State private var keys: [ProviderKind: String] = [:]
    @State private var models: [ProviderKind: String] = [:]
    @State private var cacheSize: Int64 = 0
    @State private var copied = false
    @State private var giphyKey = ""
    @State private var freesoundKey = ""

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

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

            Section("GIPHY") {
                SecureField("GIPHY API key", text: Binding(get: { giphyKey }, set: { v in
                    giphyKey = v
                    let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { Keychain.delete(account: Giphy.keyAccount) } else { Keychain.write(trimmed, account: Giphy.keyAccount) }
                }))
                HStack {
                    Link("Get a free GIPHY API key", destination: URL(string: "https://developers.giphy.com/dashboard/")!)
                    Spacer()
                    Text("Or set GIPHY_API_KEY").foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(Giphy.hasBuiltInKey
                     ? "GIPHY stickers and GIFs work out of the box with Eddie's key; add your own to use it instead. Only your searches go to GIPHY; the GIFs you add are saved on this Mac."
                     : "Adds GIPHY stickers and GIFs to the sticker picker. Only your searches go to GIPHY; the GIFs you add are saved on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Freesound") {
                SecureField("Freesound API key", text: Binding(get: { freesoundKey }, set: { v in
                    freesoundKey = v
                    let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { Keychain.delete(account: Freesound.keyAccount) } else { Keychain.write(trimmed, account: Freesound.keyAccount) }
                }))
                HStack {
                    Link("Get a free Freesound API key", destination: URL(string: "https://freesound.org/apiv2/apply")!)
                    Spacer()
                    Text("Or set FREESOUND_API_KEY").foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(Freesound.hasBuiltInKey
                     ? "The sound effects library works out of the box with Eddie's key; add your own to use it instead. Only your searches go to Freesound; sounds you add are saved on this Mac."
                     : "Powers the sound effects library (⌥⌘L). Only your searches go to Freesound; sounds you add are saved on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("AI Agents") {
                Toggle("Let AI agents control Eddie", isOn: $model.agentControl)
                Text("Agents like Claude Code, Claude Desktop or Cursor can open projects, add footage, edit, grade and export through Eddie's MCP server. Everything happens in this window, and each change can be undone. Only apps on this Mac can connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.agentServerError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if model.agentControl {
                    Label("Listening", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Server") {
                    Text(EditorModel.mcpHelperPath).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button("Copy Claude Code Command") {
                        copy("claude mcp add eddie -- \"\(EditorModel.mcpHelperPath)\"")
                    }
                    Button("Copy JSON Config") {
                        copy("""
                        {
                          "mcpServers": {
                            "eddie": { "command": "\(EditorModel.mcpHelperPath)" }
                          }
                        }
                        """)
                    }
                    .help("For Claude Desktop, Cursor and other MCP apps")
                    if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                }
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
            giphyKey = Keychain.read(account: Giphy.keyAccount) ?? ""
            freesoundKey = Keychain.read(account: Freesound.keyAccount) ?? ""
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
