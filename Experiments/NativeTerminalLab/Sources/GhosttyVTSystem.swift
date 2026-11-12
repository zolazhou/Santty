// PNG callback boundary adapted from herdr-app a547b16c (Apache-2.0).
// ImageIO/vImage are host decoders, not another terminal/image-protocol parser.
// See Licenses/Image-Adaptation-NOTICE.txt.
import Accelerate
import Foundation
import GhosttyVt
import ImageIO

/// Process-global VT implementations are frozen before creating any terminal.
/// Swift's once-initialized static also serializes concurrent factory callers;
/// it never replaces the callback while existing drivers parse on other queues.
enum GhosttyVTSystem {
    private static let installation: GhosttyResult = {
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG,
            unsafeBitCast(vtDecodePNG as GhosttySysDecodePngFn, to: UnsafeRawPointer.self))
    }()

    static func prepare() throws {
        guard installation == GHOSTTY_SUCCESS else {
            throw NativeTerminalError.api("install_png_decoder", installation.rawValue)
        }
    }
}

private let vtDecodePNG: GhosttySysDecodePngFn = { _, allocator, data, count, output in
    NativePNGDecoder.decode(allocator: allocator, data: data, count: count, output: output)
}

/// Static PNG only. No AppKit objects, main-thread dispatch, URL sources, file
/// transport, retained borrowed pointers or callback-time global configuration.
enum NativePNGDecoder {
    static let maximumEncodedBytes = 16 * 1024 * 1024
    static let maximumDecodedBytes = 16 * 1024 * 1024
    static let maximumDimension = 8192

    static func decode(allocator: UnsafePointer<GhosttyAllocator>?, data: UnsafePointer<UInt8>?,
                       count: Int, output: UnsafeMutablePointer<GhosttySysImage>?) -> Bool {
        autoreleasepool {
            guard let data, let output, count >= 20, count <= maximumEncodedBytes,
                  Array(UnsafeBufferPointer(start: data, count: 8)) == [137, 80, 78, 71, 13, 10, 26, 10],
                  // ImageIO tolerates a missing IEND. Require the canonical
                  // final PNG terminator, not a partially received datastream.
                  Array(UnsafeBufferPointer(start: data + count - 12, count: 12)) == [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130],
                  let bytes = CFDataCreateWithBytesNoCopy(nil, data, count, kCFAllocatorNull),
                  let source = CGImageSourceCreateWithData(bytes,
                      [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == "public.png",
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { return false }
            // Check the expanded size before asking ImageIO to decode pixels.
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixels <= maximumDecodedBytes / 4 else { return false }
            let byteCount = pixels * 4
            guard let buffer = ghostty_alloc(allocator, byteCount) else { return false }
            var transferred = false
            defer { if !transferred { ghostty_free(allocator, buffer, byteCount) } }
            // Honor the VT allocator's budget before requesting pixel decode.
            guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                      [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: false] as CFDictionary),
                  image.width == width, image.height == height,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  // A lazy CGImage and vImage can both report success while
                  // the PNG provider failed and supplied transparent black.
                  let decoded = image.dataProvider?.data,
                  let rgb = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
            let (requiredBytes, strideOverflow) = image.bytesPerRow.multipliedReportingOverflow(by: height)
            guard !strideOverflow, image.bytesPerRow > 0, CFDataGetLength(decoded) >= requiredBytes else { return false }
            // Unlike CGContext's premultiplied bitmap rendering, vImage can
            // request straight RGBA directly. This preserves low-alpha RGB
            // precision and hidden RGB at alpha=0 for ordinary 8-bit PNGs.
            var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                colorSpace: Unmanaged.passUnretained(rgb),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                version: 0, decode: nil, renderingIntent: .defaultIntent)
            var destination = vImage_Buffer(data: buffer, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width * 4)
            let result = withExtendedLifetime(decoded) {
                vImageBuffer_InitWithCGImage(&destination, &format, nil, image, vImage_Flags(kvImageNoAllocate))
            }
            guard result == kvImageNoError,
                CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
            output.pointee = GhosttySysImage(width: UInt32(width), height: UInt32(height),
                data: buffer, data_len: byteCount)
            transferred = true // VT owns exactly this allocator's exact-size buffer.
            return true
        }
    }
}
