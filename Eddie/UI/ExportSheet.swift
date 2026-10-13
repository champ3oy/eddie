import SwiftUI

/// Pick where the video is going; Eddie picks the codec, size and frame rate.
struct ExportSheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSheet.saved

    private static var saved: ExportSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "export.settings"),
                  let s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return .init() }
            return s
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "export.settings") }
    }

    private var outputSize: CGSize { settings.size(for: model.projectSize) }
    private var fps: Double { Double(settings.frameRate.value ?? 30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export").font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ExportSettings.presets, id: \.name) { preset in
                    let on = preset.settings == settings
                    Button { settings = preset.settings } label: {
                        HStack {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.white : Ink.tertiary)
                            Text(preset.name).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.1) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Form {
                Picker("Format", selection: $settings.codec) {
                    ForEach(ExportSettings.Codec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Size", selection: $settings.resolution) {
                    ForEach(ExportSettings.Resolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $settings.frameRate) {
                    ForEach(ExportSettings.FrameRate.allCases) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.columns)

            let mb = settings.megabytesPerMinute(for: outputSize, fps: fps) * model.project.duration / 60
            Text("\(Int(outputSize.width)) × \(Int(outputSize.height)) · \(ClipSection.duration(model.project.duration)) · about \(mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : "\(max(1, Int(mb))) MB")")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Ink.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    Self.saved = settings
                    dismiss()
                    DispatchQueue.main.async { Panels.saveExport(model, settings: settings) }
                }
                .keyboardShortcut(.defaultAction)
                .tint(Color(white: 0.32))
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
