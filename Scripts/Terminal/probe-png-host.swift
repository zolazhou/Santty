// Standalone ImageIO/vImage behavior probe. No Ghostty, Santty, AppKit,
// file transport or user images. Run: xcrun swift <this-file>.
import Accelerate
import Foundation
import ImageIO

let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
let bad = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACElEQVRub3QgemxpYlVpEfcAAAAASUVORK5CYII=")!

func observe(_ name: String, _ data: Data) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithData(data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary) else {
        print("\(name): source rejected")
        return nil
    }
    let status = CGImageSourceGetStatus(source).rawValue
    guard let image = CGImageSourceCreateImageAtIndex(source, 0,
        [kCGImageSourceShouldCache: false] as CFDictionary) else {
        print("\(name): image rejected; source_status=\(status)")
        return nil
    }
    let provider = image.dataProvider?.data
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
        colorSpace: Unmanaged.passUnretained(space),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        version: 0, decode: nil, renderingIntent: .defaultIntent)
    var pixels = [UInt8](repeating: 0xa5, count: image.width * image.height * 4)
    let result = pixels.withUnsafeMutableBytes { bytes in
        var buffer = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(image.height),
            width: vImagePixelCount(image.width), rowBytes: image.width * 4)
        return vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoAllocate))
    }
    print("\(name): source_status=\(status) image_status=\(CGImageSourceGetStatusAtIndex(source, 0).rawValue) provider_bytes=\(provider.map { CFDataGetLength($0) } ?? -1) vimage_result=\(result) pixels=\(pixels)")
    return pixels
}

guard observe("valid_red_control", red) == [255, 0, 0, 255] else { exit(1) }
_ = observe("malformed_deflate", bad)
_ = observe("missing_IEND", Data(red.dropLast(12)))
print("Diagnostic only: complete status/vImage success can coexist with missing provider data or a missing IEND. NativePNGDecoder adds those boundary checks; this probe deliberately does not.")
