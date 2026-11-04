import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

/// An opaque test image with a gradient and a block, so encoders have something to chew on.
func makeTestImage(width: Int, height: Int, shade: CGFloat = 0.5, block: CGRect? = nil) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for x in stride(from: 0, to: width, by: 4) {
        context.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(width), green: shade, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 4, height: height))
    }
    if let block {
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(block)
    }
    return context.makeImage()!
}

@Suite("Capture sizing")
struct CaptureSizingTests {
    @Test func retinaLaptopGetsAModelSizedImage() {
        let size = CaptureSizing.pixelSize(pointSize: CGSize(width: 1512, height: 982), scale: 2)
        #expect(size.width == 1280 && size.height == 831)
    }

    @Test func standardMonitorAndPortrait() {
        let wide = CaptureSizing.pixelSize(pointSize: CGSize(width: 1920, height: 1080), scale: 1)
        #expect(wide.width == 1280 && wide.height == 720)
        let tall = CaptureSizing.pixelSize(pointSize: CGSize(width: 1080, height: 1920), scale: 1)
        #expect(tall.width == 720 && tall.height == 1280)
        let ultrawide = CaptureSizing.pixelSize(pointSize: CGSize(width: 3440, height: 1440), scale: 1)
        #expect(ultrawide.width == 1280 && ultrawide.height == 536)
    }

    @Test func neverUpscalesPastNativePixels() {
        let small = CaptureSizing.pixelSize(pointSize: CGSize(width: 1024, height: 768), scale: 1)
        #expect(small.width == 1024 && small.height == 768)
        // The same panel at 2x has 2048 native pixels across, enough for 1280.
        let retina = CaptureSizing.pixelSize(pointSize: CGSize(width: 1024, height: 768), scale: 2)
        #expect(retina.width == 1280 && retina.height == 960)
        let forced = CaptureSizing.pixelSize(pointSize: CGSize(width: 1024, height: 768), scale: 1, allowUpscale: true)
        #expect(forced.width == 1280 && forced.height == 960)
    }

    @Test func degenerateSizesStayPositive() {
        let zero = CaptureSizing.pixelSize(pointSize: .zero, scale: 1, allowUpscale: true)
        #expect(zero.width >= 1 && zero.height >= 1)
        let sliver = CaptureSizing.pixelSize(pointSize: CGSize(width: 5000, height: 1), scale: 1)
        #expect(sliver.height == 1)
    }

    @Test func downscalingForTheVoiceModel() {
        let size = CaptureSizing.downscaledSize(width: 1280, height: 831, longEdge: CaptureSizing.voiceLongEdge(displayCount: 1))
        #expect(size.width == 768 && size.height == 499)
        let several = CaptureSizing.downscaledSize(width: 720, height: 1280, longEdge: CaptureSizing.voiceLongEdge(displayCount: 3))
        #expect(several.width == 360 && several.height == 640)
        let untouched = CaptureSizing.downscaledSize(width: 500, height: 300, longEdge: 768)
        #expect(untouched.width == 500 && untouched.height == 300)
    }
}

@Suite("Image coding")
struct ImageCodingTests {
    @Test func jpegRoundTripKeepsDimensions() throws {
        let image = makeTestImage(width: 400, height: 260)
        let jpeg = try ImageCoding.jpegData(image, quality: 0.8)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        let size = ImageCoding.pixelSize(of: jpeg)
        #expect(size?.width == 400 && size?.height == 260)
        #expect(try ImageCoding.decode(jpeg).width == 400)
    }

    @Test func lowerQualityIsSmaller() throws {
        let image = makeTestImage(width: 640, height: 400, block: CGRect(x: 100, y: 100, width: 50, height: 80))
        let high = try ImageCoding.jpegData(image, quality: 0.95)
        let low = try ImageCoding.jpegData(image, quality: 0.3)
        #expect(low.count < high.count)
    }

    @Test func rescaledJPEGForRealtimeVoice() throws {
        let jpeg = try ImageCoding.jpegData(makeTestImage(width: 1280, height: 831))
        let small = try ImageCoding.rescaledJPEG(jpeg, longEdge: 768)
        #expect(small.width == 768 && small.height == 499)
        #expect(ImageCoding.pixelSize(of: small.data)?.width == 768)
    }

    @Test func pngEncodes() throws {
        let png = try ImageCoding.pngData(makeTestImage(width: 10, height: 10))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func garbageDoesNotDecode() {
        #expect(throws: ImageCoding.Failure.decodeFailed) { try ImageCoding.decode(Data("not an image".utf8)) }
        #expect(ImageCoding.pixelSize(of: Data([1, 2, 3])) == nil)
    }
}

@Suite("Screen captures")
struct ScreenCaptureValueTests {
    private func capture(_ number: Int, of count: Int, cursor: Bool) -> ScreenCapture {
        ScreenCapture(imageData: Data([0xFF, 0xD8]), screenNumber: number, screenCount: count, isCursorScreen: cursor,
                      display: DisplayGeometry(id: UInt32(number), frame: CGRect(x: CGFloat(number - 1) * 1000, y: 0, width: 1000, height: 600),
                                               scale: 1, isPrimary: number == 1),
                      pixelWidth: 1000, pixelHeight: 600)
    }

    @Test func labelsTellTheModelWhereThePointerIs() {
        #expect(capture(1, of: 1, cursor: true).label.contains("pointer is on this screen"))
        let captures = [capture(1, of: 2, cursor: false), capture(2, of: 2, cursor: true)]
        #expect(captures[0].label.hasPrefix("Screen 1 of 2"))
        #expect(captures[0].label.contains("another display"))
        #expect(captures[1].label.contains("most likely what the user means"))
        #expect(captures[1].label.contains("1000×600 px"))
    }

    @Test func screenSelectionFallsBackToThePointer() {
        let captures = [capture(1, of: 3, cursor: false), capture(2, of: 3, cursor: true), capture(3, of: 3, cursor: false)]
        #expect(captures.cursorCapture?.screenNumber == 2)
        #expect(captures.capture(screen: 3)?.screenNumber == 3)
        #expect(captures.capture(screen: 9)?.screenNumber == 2)
        #expect(captures.capture(screen: nil)?.screenNumber == 2)
        #expect(captures.contentParts.count == 6)
    }

    @Test func metadataJSONOmitsTheImage() {
        let json = capture(2, of: 2, cursor: true).jsonValue
        #expect(json["pixelWidth"]?.intValue == 1000)
        #expect(json["displayFrame"]?["x"]?.doubleValue == 1000)
        #expect(json["bytes"]?.intValue == 2)
        #expect(json["imageData"] == nil)
    }

    @Test func exclusionMatchesWindowsOrApps() {
        let exclusion = CaptureExclusion(windowNumbers: [42], bundleIdentifiers: ["com.openclicky.app"])
        #expect(exclusion.excludes(windowNumber: 42, bundleIdentifier: "com.apple.Safari"))
        #expect(exclusion.excludes(windowNumber: 7, bundleIdentifier: "com.openclicky.app"))
        #expect(!exclusion.excludes(windowNumber: 7, bundleIdentifier: "com.apple.Safari"))
        #expect(!CaptureExclusion.none.excludes(windowNumber: 42, bundleIdentifier: nil))
    }
}
