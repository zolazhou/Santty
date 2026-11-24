// Independent AppKit-only readback control. No terminal code or screen capture.
// Keeps the original calibrated and un-managed colorAt vectors visible.
import AppKit

final class Probe: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for (i,c) in [NSColor(srgbRed:0,green:1,blue:0,alpha:1),NSColor(calibratedRed:0,green:1,blue:0,alpha:1),NSColor(srgbRed:1,green:0,blue:0,alpha:1),NSColor(calibratedRed:1,green:0,blue:0,alpha:1)].enumerated() {
            c.setFill(); NSRect(x:i*20,y:0,width:20,height:20).fill()
        }
        let rgba: [UInt8] = [0,255,0,255]
        let provider = CGDataProvider(data:Data(rgba) as CFData)!
        let image = CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        NSGraphicsContext.current!.cgContext.draw(image,in:CGRect(x:80,y:0,width:20,height:20))
    }
}
_ = NSApplication.shared
let view = Probe(frame:NSRect(x:0,y:0,width:100,height:20))
let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
window.contentView = view
let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
view.cacheDisplay(in:view.bounds,to:bitmap)
print("window=\(window.colorSpace?.localizedName ?? "nil") bitmap=\(bitmap.colorSpace.localizedName ?? "nil") name=\(bitmap.colorSpaceName)")
for i in 0..<5 {
    let c = bitmap.colorAt(x:Int((Double(i)+0.5)*Double(bitmap.pixelsWide)/5),y:bitmap.pixelsHigh/2)!.usingColorSpace(.sRGB)!
    print("color\(i)=\([c.redComponent,c.greenComponent,c.blueComponent].map { Int(($0*255).rounded()) })")
}
print("cgspace-name=\(String(describing:bitmap.cgImage?.colorSpace?.name))")
var rgba = [UInt8](repeating:0,count:bitmap.pixelsWide*bitmap.pixelsHigh*4)
rgba.withUnsafeMutableBytes { data in
    let ctx = CGContext(data:data.baseAddress,width:bitmap.pixelsWide,height:bitmap.pixelsHigh,bitsPerComponent:8,bytesPerRow:bitmap.pixelsWide*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(bitmap.cgImage!,in:CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh))
}
for i in 0..<5 {
    let x=Int((Double(i)+0.5)*Double(bitmap.pixelsWide)/5),y=bitmap.pixelsHigh/2
    print("managed\(i)=\(Array(rgba[((y*bitmap.pixelsWide+x)*4)..<((y*bitmap.pixelsWide+x)*4+4)]))")
}
window.contentView = nil
