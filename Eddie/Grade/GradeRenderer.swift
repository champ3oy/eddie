import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

/// What the viewer sees.
enum ViewMode: String, CaseIterable, Identifiable {
    case original = "Original LOG"
    case lutOnly = "LUT only"
    case graded = "Graded"
    var id: String { rawValue }
}

/// LUT + grade applied to a `CIImage`. Color management is off everywhere so pixel values are the
/// camera's real code values: the LUT must see D-Log M values, not values converted to some other space.
final class GradeRenderer {
    static let shared = GradeRenderer()

    let context: CIContext

    private static let kernel: CIColorKernel = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: GradeKernelSource.metal)
            guard let k = kernels.first(where: { $0.name == "eddieGrade" }) as? CIColorKernel else {
                fatalError("eddieGrade is not a color kernel")
            }
            return k
        } catch {
            fatalError("Couldn't compile the grade kernel: \(error)")
        }
    }()

    init() {
        context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "Eddie",
        ])
    }

    /// Source image from a decoded frame, without color management.
    static func sourceImage(from pixelBuffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()])
    }

    /// `applyLUT` is false for footage that isn't D-Log M (phone video, photos): it's already normal Rec.709.
    func render(_ source: CIImage, recipe: GradeRecipe, lut: CubeLUT, mode: ViewMode, applyLUT: Bool = true) -> CIImage {
        if mode == .original { return source }
        var image = source
        if applyLUT {
            let cube = CIFilter.colorCube()
            cube.cubeDimension = Float(lut.size)
            cube.cubeData = lut.data
            cube.inputImage = source
            image = cube.outputImage ?? source
        }
        if mode == .lutOnly || recipe.isNeutral { return image }

        let r = recipe.clamped()
        let p0 = CIVector(x: r.exposure, y: r.temperature / 100, z: r.tint / 100, w: r.contrast / 100)
        let p1 = CIVector(x: r.highlights / 100, y: r.shadows / 100, z: r.whites / 100, w: r.blacks / 100)
        let p2 = CIVector(x: r.vibrance / 100, y: r.saturation / 100, z: 0, w: 0)
        image = Self.kernel.apply(extent: image.extent, arguments: [image, p0, p1, p2]) ?? image
        return image
    }

    /// Before/after wipe: untouched camera image on the left, graded on the right.
    func renderWipe(_ source: CIImage, recipe: GradeRecipe, lut: CubeLUT, split: Double) -> CIImage {
        let after = render(source, recipe: recipe, lut: lut, mode: .graded)
        let e = source.extent
        let cut = CGRect(x: e.minX, y: e.minY, width: e.width * min(max(split, 0), 1), height: e.height)
        return source.cropped(to: cut).composited(over: after)
    }

    /// Renders into a self-contained half-float image (detached from any pixel buffer).
    func materialize(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        let rowBytes = w * 8
        var data = Data(count: rowBytes * h)
        data.withUnsafeMutableBytes { buf in
            context.render(image, toBitmap: buf.baseAddress!, rowBytes: rowBytes, bounds: extent,
                           format: .RGBAh, colorSpace: nil)
        }
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: w, height: h),
                       format: .RGBAh, colorSpace: nil)
    }

    /// 8-bit RGBA pixels (Rec.709 display values), for stats and JPEG encoding.
    func rgba8(_ image: CIImage, maxWidth: CGFloat) -> (pixels: [UInt8], width: Int, height: Int) {
        var img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if img.extent.width > maxWidth {
            let s = maxWidth / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        }
        let extent = img.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            context.render(img, toBitmap: buf.baseAddress!, rowBytes: w * 4, bounds: extent,
                           format: .RGBA8, colorSpace: nil)
        }
        return (pixels, w, h)
    }
}
