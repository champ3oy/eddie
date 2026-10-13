import Foundation

/// A 3D LUT loaded from a `.cube` file, stored in the layout Core Image's color cube expects
/// (RGBA Float32, red varying fastest — the same order as `.cube` files).
struct CubeLUT {
    let title: String
    let size: Int
    let data: Data

    enum ParseError: LocalizedError {
        case missingSize, wrongEntryCount(expected: Int, got: Int), badLine(String), unsupported1D

        var errorDescription: String? {
            switch self {
            case .missingSize: return "The .cube file has no LUT_3D_SIZE line."
            case let .wrongEntryCount(e, g): return "The .cube file should have \(e) entries but has \(g)."
            case let .badLine(l): return "Couldn't read this line of the .cube file: \(l)"
            case .unsupported1D: return "1D LUTs aren't supported; use a 3D .cube LUT."
            }
        }
    }

    init(title: String, size: Int, data: Data) {
        self.title = title
        self.size = size
        self.data = data
    }

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try self.init(parsing: text, title: url.deletingPathExtension().lastPathComponent)
    }

    init(parsing text: String, title: String) throws {
        var size: Int?
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }

            if let f = Float(first) {
                guard size != nil else { throw ParseError.missingSize }
                guard parts.count >= 3, let g = Float(parts[1]), let b = Float(parts[2]) else {
                    throw ParseError.badLine(line)
                }
                values.append(contentsOf: [f, g, b])
                continue
            }
            switch first.uppercased() {
            case "LUT_3D_SIZE":
                guard parts.count >= 2, let n = Int(parts[1]), n >= 2 else { throw ParseError.badLine(line) }
                size = n
            case "LUT_1D_SIZE":
                throw ParseError.unsupported1D
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap { Float($0) }
            default:
                continue // TITLE and other keywords
            }
        }

        guard let n = size else { throw ParseError.missingSize }
        let expected = n * n * n
        guard values.count == expected * 3 else {
            throw ParseError.wrongEntryCount(expected: expected, got: values.count / 3)
        }

        // Normalize output values from the declared domain to 0...1 (almost always already 0...1).
        let lo = domainMin.count == 3 ? domainMin : [0, 0, 0]
        let hi = domainMax.count == 3 ? domainMax : [1, 1, 1]
        var rgba = [Float](repeating: 1, count: expected * 4)
        for i in 0..<expected {
            for c in 0..<3 {
                let span = hi[c] - lo[c]
                rgba[i * 4 + c] = span == 0 ? values[i * 3 + c] : (values[i * 3 + c] - lo[c]) / span
            }
        }
        self.title = title
        self.size = n
        self.data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The official DJI Osmo Action 4 D-Log M → Rec.709 LUT bundled with the app.
    static let djiAction4: CubeLUT = {
        guard let url = Bundle.main.url(forResource: "DJI_Action4_DLogM_to_Rec709", withExtension: "cube"),
              let lut = try? CubeLUT(contentsOf: url) else {
            return .identity(size: 2)
        }
        return lut
    }()

    static func identity(size n: Int) -> CubeLUT {
        var rgba: [Float] = []
        rgba.reserveCapacity(n * n * n * 4)
        let d = Float(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            rgba.append(contentsOf: [Float(r) / d, Float(g) / d, Float(b) / d, 1])
        } } }
        return CubeLUT(title: "Identity", size: n, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
