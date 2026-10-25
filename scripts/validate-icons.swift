import CoreGraphics
import Foundation
import ImageIO

struct RGBAImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "CamMicIconValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode \(url.path)"])
        }
        try self.init(image)
    }

    init(_ image: CGImage) throws {
        guard let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ),
              let data = context.data else {
            throw NSError(domain: "CamMicIconValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot normalize icon pixels"])
        }
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        width = image.width
        height = image.height
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
}

func fail(_ message: String) -> Never {
    fputs("Icon validation failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 5 else {
    fputs("Usage: validate-icons.swift ios-master.png mac-master.png mac-iconset-dir CamMic.icns\n", stderr)
    exit(2)
}

let ios = URL(fileURLWithPath: CommandLine.arguments[1])
let mac = URL(fileURLWithPath: CommandLine.arguments[2])
let macIconset = URL(fileURLWithPath: CommandLine.arguments[3])
let icns = URL(fileURLWithPath: CommandLine.arguments[4])
do {
    let iosImage = try RGBAImage(ios)
    guard iosImage.width == 1024, iosImage.height == 1024 else { fail("iOS master is not 1024x1024") }
    for pixel in stride(from: 3, to: iosImage.bytes.count, by: 4) where iosImage.bytes[pixel] != 255 {
        fail("iOS AppIcon must remain fully opaque")
    }

    let macImage = try RGBAImage(mac)
    guard macImage.width == 1024, macImage.height == 1024 else { fail("macOS master is not 1024x1024") }
    guard [(0, 0), (1023, 0), (0, 1023), (1023, 1023)].allSatisfy({ macImage.alpha($0.0, $0.1) == 0 }) else {
        fail("macOS master corner alpha must be zero")
    }
    let macPNGFiles = try FileManager.default.contentsOfDirectory(at: macIconset, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard macPNGFiles.count == 10 else { fail("expected all 10 macOS iconset PNGs, found \(macPNGFiles.count)") }
    for file in macPNGFiles {
        let image = try RGBAImage(file)
        guard image.width == image.height, image.width >= 16 else { fail("invalid macOS icon dimensions in \(file.lastPathComponent)") }
        guard [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)]
            .allSatisfy({ image.alpha($0.0, $0.1) == 0 }) else {
            fail("transparent rounded corners were lost in \(file.lastPathComponent)")
        }
        let inset = max(1, Int((Double(image.width) * 0.10).rounded()))
        guard [(inset, inset), (image.width - 1 - inset, inset),
               (inset, image.height - 1 - inset), (image.width - 1 - inset, image.height - 1 - inset)]
            .allSatisfy({ image.alpha($0.0, $0.1) < 200 }) else {
            fail("rounded corner is too opaque in \(file.lastPathComponent)")
        }
        guard image.alpha(image.width / 2, max(0, Int((Double(image.height) * 0.08).rounded()))) > 0 else {
            fail("rounded icon card is missing at the standard Dock/Finder view size in \(file.lastPathComponent)")
        }
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where image.alpha(x, y) > 8 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        let left = Double(minX) / Double(image.width)
        let top = Double(minY) / Double(image.height)
        let right = Double(image.width - 1 - maxX) / Double(image.width)
        let bottom = Double(image.height - 1 - maxY) / Double(image.height)
        guard min(left, top, right, bottom) >= 0.005 else { fail("macOS icon shadow is clipped at \(file.lastPathComponent)") }
        guard max(left, top, right, bottom) <= 0.16 else { fail("macOS icon has excessive empty margin at \(file.lastPathComponent)") }
        print("macOS \(file.lastPathComponent): \(image.width)x\(image.height), transparent corners, 10% corner alpha \(image.alpha(inset, inset)), artwork bounds \(minX),\(minY)-\(maxX),\(maxY)")
    }
    guard let icnsSource = CGImageSourceCreateWithURL(icns as CFURL, nil) else { fail("cannot decode Assets/CamMic.icns") }
    let icnsCount = CGImageSourceGetCount(icnsSource)
    guard icnsCount >= 5 else { fail("CamMic.icns contains only \(icnsCount) representations") }
    var icnsSizes = Set<Int>()
    for index in 0..<icnsCount {
        guard let image = CGImageSourceCreateImageAtIndex(icnsSource, index, nil) else { fail("cannot decode ICNS representation \(index)") }
        let representation = try RGBAImage(image)
        guard representation.width == representation.height else { fail("ICNS representation \(index) is not square") }
        guard [(0, 0), (representation.width - 1, 0), (0, representation.height - 1), (representation.width - 1, representation.height - 1)]
            .allSatisfy({ representation.alpha($0.0, $0.1) == 0 }) else {
            fail("transparent corners were lost in ICNS representation \(index) at \(representation.width) px")
        }
        icnsSizes.insert(representation.width)
    }
    for size in [16, 32, 64, 128, 256, 512, 1024] where !icnsSizes.contains(size) {
        fail("CamMic.icns is missing the \(size) px representation")
    }
    print("iOS AppIcon: \(iosImage.width)x\(iosImage.height), alpha=opaque")
    print("macOS master: \(macImage.width)x\(macImage.height), alpha corners=0")
    print("macOS iconset: \(macPNGFiles.count) checked across 16–1024 px (Dock and Finder sizes)")
    print("macOS ICNS: \(icns.path), \(icnsCount) representations with sizes \(icnsSizes.sorted()) and transparent corners")
} catch {
    fail(error.localizedDescription)
}
