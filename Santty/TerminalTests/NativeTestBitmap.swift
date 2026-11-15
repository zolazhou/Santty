import AppKit
import XCTest

/// Test readback only. colorAt(...).usingColorSpace(.sRGB) can reinterpret an
/// ICC-tagged window cache as generic calibrated RGB. Retain the CGImage's
/// actual source profile and color-manage once into an explicit sRGB target.
@MainActor
enum NativeTestBitmap {
    static func sRGB(_ bitmap: NSBitmapImageRep) throws -> [UInt8] {
        let image = try XCTUnwrap(bitmap.cgImage)
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        var bytes = [UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        }
        // Existing pixel assertions describe straight RGBA, not premultiplied.
        for i in stride(from:0,to:bytes.count,by:4) {
            let alpha = Int(bytes[i+3])
            if alpha > 0 && alpha < 255 {
                for component in 0..<3 { bytes[i+component] = UInt8(min(255,(Int(bytes[i+component])*255+alpha/2)/alpha)) }
            }
        }
        return bytes
    }
}

@MainActor
final class NativeBitmapColorTests: XCTestCase {
    private final class Sample: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed:0,green:1,blue:0,alpha:1).setFill(); NSRect(x:0,y:0,width:20,height:20).fill()
            NSColor(srgbRed:1,green:0,blue:0,alpha:1).setFill(); NSRect(x:20,y:0,width:20,height:20).fill()
            NSColor(srgbRed:0,green:0,blue:1,alpha:1).setFill(); NSRect(x:0,y:20,width:20,height:20).fill()
        }
    }
    func testTaggedOffscreenBitmapKeepsSourceProfileAndTopFirstGeometry() throws {
        let view = Sample(frame:.init(x:0,y:0,width:40,height:40))
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        // An additional controlled wide-gamut target, not a changed terminal
        // fixture or system profile. No window is ordered/activated/captured.
        window.colorSpace = .displayP3
        window.contentView = view; defer { window.contentView = nil }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let rgba = try NativeTestBitmap.sRGB(bitmap), w = bitmap.pixelsWide, h = bitmap.pixelsHigh
        func pixel(_ x: Int,_ y: Int) -> [UInt8] { Array(rgba[(y*w+x)*4..<(y*w+x)*4+4]) }
        let green = pixel(w/4,h/4), red = pixel(w*3/4,h/4), blue = pixel(w/4,h*3/4)
        XCTAssertLessThan(green[0],20); XCTAssertGreaterThan(green[1],240); XCTAssertLessThan(green[2],20)
        XCTAssertGreaterThan(red[0],240); XCTAssertLessThan(red[1],20); XCTAssertLessThan(red[2],20)
        XCTAssertLessThan(blue[0],20); XCTAssertLessThan(blue[1],20); XCTAssertGreaterThan(blue[2],240)
    }
}
