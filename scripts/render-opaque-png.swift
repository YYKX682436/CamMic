import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render-opaque-png.swift input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(
        data: nil,
        width: sourceImage.width,
        height: sourceImage.height,
        bitsPerComponent: 8,
        bytesPerRow: sourceImage.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("Could not render an opaque RGB PNG from the icon source.\n", stderr)
    exit(1)
}

context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))
guard let rendered = context.makeImage() else {
    fputs("Could not create the opaque RGB icon image.\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not write the opaque RGB icon PNG.\n", stderr)
    exit(1)
}
