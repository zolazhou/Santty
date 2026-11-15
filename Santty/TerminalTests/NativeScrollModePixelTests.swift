import AppKit
import Metal
@testable import SwiftTerm
import XCTest
@testable import Santty

@MainActor
final class NativeScrollModePixelTests: XCTestCase {
    func testCoreGraphicsModeStrokeAndSelectionHaveActualPixels() throws { try pixels(metal:false) }
    func testMetalTextureComposesWithTheActualAppKitModeOverlay() throws { try pixels(metal:true) }

    private func pixels(metal: Bool) throws {
        let view = NativeTerminalScrollView(driver:try GhosttyVTDriver(),frame:.init(x:0,y:0,width:320,height:144))
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = view; defer { window.contentView = nil }
        if metal { try view.setMetal(true) }
        let theme = NativeTerminalTheme(name:"owned mode pixel vector",foreground:.init(red:255,green:255,blue:255),
            background:.init(red:0,green:0,blue:0),cursor:nil,cursorText:nil,selectionForeground:.init(red:255,green:255,blue:255),
            selectionBackground:.init(red:0,green:0,blue:255),palette:[:])
        try view.applySettings(.init(theme:theme,padding:0,backgroundOpacity:1))
        view.feed("a界 word\r\nsecond\r\nthird\u{1b}[H")
        view.renderer.hasFocus = true
        XCTAssertTrue(view.scrollModeController.enter())
        _ = try view.driver.performScrollMode(.move(.top))
        _ = try view.driver.performScrollMode(.move(.right))
        view.refresh()
        let overlay = view.scrollModeController.overlay
        XCTAssertTrue(view.renderer.subviews.last === overlay)
        XCTAssertEqual(overlay.cursorRect.width,view.renderer.cellSize.width*2,accuracy:0.01)
        // Hidden/offscreen AppKit windows do not publish a committed CA
        // sublayer tree (observed []). Assert the actual NSView ordering and
        // backing policy; the composition below separately checks real pixels.
        XCTAssertTrue(overlay.wantsLayer)
        XCTAssertNotNil(overlay.layer)
        if metal { XCTAssertTrue(view.renderer.subviews.first is TerminalMetalLayerView) }
        var cursorVisible = true
        view.source.withFrame { frame,_,_ in cursorVisible = frame.cursorVisible }
        XCTAssertFalse(cursorVisible,"the real program caret is hidden, not unfocused")
        let image = try composite(view,metal:metal)
        let scale = CGFloat(image.width)/view.renderer.bounds.width
        let rect = overlay.cursorRect
        let crop = try XCTUnwrap(image.cropping(to:CGRect(x:rect.minX*scale,y:(view.renderer.bounds.height-rect.maxY)*scale,
                                                        width:rect.width*scale,height:rect.height*scale)))
        XCTAssertGreaterThan(try count(crop,yellow:true),15,"hollow mode cursor, not merely badge pixels")
        _ = try view.driver.performScrollMode(.toggleSelection(linewise:true)); view.refresh()
        XCTAssertGreaterThan(try count(composite(view,metal:metal),yellow:false),30,"VT selection reaches the actual CG/Metal body")
        let document = try XCTUnwrap(view.documentView), cell = view.renderer.cellSize
        func pointer(_ type: NSEvent.EventType, column: CGFloat, row: CGFloat, time: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:document.convert(.init(x:column*cell.width,
                y:view.contentView.bounds.minY+row*cell.height),to:nil),modifierFlags:[],timestamp:time,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        view.renderer.mouseDown(with:try pointer(.leftMouseDown,column:0.1,row:0.3,time:1))
        view.renderer.mouseDragged(with:try pointer(.leftMouseDragged,column:5.9,row:1.3,time:1.1))
        view.renderer.mouseUp(with:try pointer(.leftMouseUp,column:5.9,row:1.3,time:1.2))
        XCTAssertEqual(try view.driver.readScrollModeSelection(),"a界 word\nsecond")
        XCTAssertGreaterThan(try count(composite(view,metal:metal),yellow:false),30,"actual pointer gesture selection must also reach CG/Metal")
        view.scrollModeController.exit()
        view.source.withFrame { frame,_,_ in cursorVisible = frame.cursorVisible }
        XCTAssertTrue(cursorVisible); XCTAssertTrue(overlay.isHidden)
    }

    func testOverlayRasterGeometryAtOneAndTwoTimesWithoutASecondCursorModel() throws {
        let view = NativeTerminalScrollView(driver:try GhosttyVTDriver(),frame:.init(x:0,y:0,width:320,height:144))
        view.feed("geometry\r\n")
        XCTAssertTrue(view.scrollModeController.enter())
        _ = try view.driver.performScrollMode(.move(.top)); view.refresh()
        let overlay = view.scrollModeController.overlay
        for scale in [1,2] {
            let image = try bitmap(overlay,scale:scale)
            XCTAssertEqual(image.width,Int(overlay.bounds.width)*scale)
            let rect = overlay.cursorRect
            let crop = try XCTUnwrap(image.cropping(to:CGRect(x:rect.minX*CGFloat(scale),y:(overlay.bounds.height-rect.maxY)*CGFloat(scale),
                width:rect.width*CGFloat(scale),height:rect.height*CGFloat(scale))))
            XCTAssertGreaterThan(try count(crop,yellow:true),15*scale)
        }
    }

    private func bitmap(_ view: NSView,scale: Int) throws -> CGImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width)*scale,
            pixelsHigh:Int(view.bounds.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
            colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in:view.bounds,to:bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }
    /// Real CG/Metal body plus actual NSView-drawn overlay. This is offscreen
    /// composition, not WindowServer/TCC/device certification.
    private func composite(_ view: NativeTerminalScrollView,metal: Bool) throws -> CGImage {
        let renderer = view.renderer, overlay = view.scrollModeController.overlay
        let scale = renderer.window?.backingScaleFactor ?? 1
        let width = Int(renderer.bounds.width*scale), height = Int(renderer.bounds.height*scale)
        let body: CGImage
        if metal {
            let target = TerminalMetalLayerView(frame:renderer.bounds)
            target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            target.metalLayer.framebufferOnly = false; target.renderContentsScale = scale
            target.renderDrawableSize = .init(width:width,height:height)
            let backend = try MetalTerminalRenderer(target:target)
            backend.waitForCompletionAfterCommit = true; backend.capturesRenderedTexture = true
            XCTAssertTrue(renderer.renderSnapshotForMetal(renderer:backend,target:target))
            let texture = try XCTUnwrap(backend.lastRenderedTexture)
            var data = [UInt8](repeating:0,count:width*height*4)
            data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
            let provider = try XCTUnwrap(CGDataProvider(data:Data(data) as CFData))
            body = try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        } else {
            overlay.isHidden = true
            body = try bitmap(renderer,scale:Int(scale))
            overlay.isHidden = false
        }
        let foreground = try bitmap(overlay,scale:Int(scale))
        let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let bounds = CGRect(x:0,y:0,width:width,height:height)
        context.draw(body,in:bounds); context.draw(foreground,in:bounds)
        return try XCTUnwrap(context.makeImage())
    }
    private func count(_ image: CGImage,yellow: Bool) throws -> Int {
        let context = try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        return (0..<(image.width*image.height)).filter {
            let i = $0*4, r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
            return yellow ? r>150 && g>100 && b<100 : b>150 && r<100 && g<100
        }.count
    }
}
