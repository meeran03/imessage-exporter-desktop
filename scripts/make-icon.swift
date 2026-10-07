import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.45, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p*0.06,y: p*0.06,width:p*0.88,height:p*0.88),xRadius:p*0.20,yRadius:p*0.20).fill()
        NSColor(calibratedRed: 0.80, green: 0.94, blue: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.20,y:p*0.43,width:p*0.60,height:p*0.35),xRadius:p*0.09,yRadius:p*0.09).fill()
        let tail = NSBezierPath(); tail.move(to:NSPoint(x:p*0.29,y:p*0.48));tail.line(to:NSPoint(x:p*0.29,y:p*0.34));tail.line(to:NSPoint(x:p*0.45,y:p*0.48));tail.close();tail.fill()
        NSColor.white.withAlphaComponent(0.90).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.28,y:p*0.22,width:p*0.45,height:p*0.16),xRadius:p*0.025,yRadius:p*0.025).fill()
        NSColor(calibratedRed:0.08,green:0.42,blue:0.45,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.42,y:p*0.28,width:p*0.16,height:p*0.025),xRadius:p*0.01,yRadius:p*0.01).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(name))
    }
}
