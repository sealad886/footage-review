import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

actor FaceScanner {
    static let minimumConfidence = 0.5

    func scan(clip: ReviewClip, cropDirectory: URL, interval: Double = 1.0) async throws -> ScanResult {
        let timeScale: CMTimeScale = 600
        guard interval.isFinite, interval >= 1 / Double(timeScale) else {
            throw FaceScanError.invalidInterval
        }
        try Task.checkCancellation()
        let source = URL(fileURLWithPath: clip.path)
        let resource = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.lastPathComponent.lowercased() != ".ds_store",
              resource.isRegularFile == true, resource.isSymbolicLink == false else {
            throw FaceScanError.invalidSource
        }
        let destination = try cropDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destination.isDirectory == true, destination.isSymbolicLink == false else {
            throw FaceScanError.invalidCropDirectory
        }
        let stamp = try FileStamp.read(source)
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw FaceScanError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration / interval < Double(Int.max) else {
            throw FaceScanError.invalidDuration
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }

        let cadence = String(interval.bitPattern, radix: 16)
        let appearancePrefix = "\(clip.id):\(stamp.generation):\(cadence)"
        var appearances: [Appearance] = []
        var sampledFrames = 0
        var failedFrames = 0
        var repeatedFrameTimes = 0
        var invalidCrops = 0
        var firstFailure: String?
        var previousTime: CMTime?
        let sampleCount = Int((duration / interval).rounded(.up))

        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let requested = CMTime(seconds: Double(index) * interval, preferredTimescale: timeScale)
            let frame: (image: CGImage, actualTime: CMTime)
            do {
                frame = try await generator.image(at: requested)
                try Task.checkCancellation()
                guard frame.actualTime.isNumeric, frame.actualTime.seconds >= 0 else {
                    throw FaceScanError.invalidFrameTime
                }
            } catch {
                try Task.checkCancellation()
                failedFrames += 1
                firstFailure = firstFailure ?? error.localizedDescription
                continue
            }
            if frame.actualTime == previousTime {
                repeatedFrameTimes += 1
                continue
            }

            let faces: [VNFaceObservation]
            do {
                faces = try autoreleasepool {
                    let request = VNDetectFaceRectanglesRequest()
                    let handler = VNImageRequestHandler(cgImage: frame.image, orientation: .up)
                    try handler.perform([request])
                    return (request.results ?? []).filter { Double($0.confidence) >= Self.minimumConfidence }
                        .sorted { lhs, rhs in
                            if lhs.boundingBox.maxY != rhs.boundingBox.maxY {
                                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
                            }
                            if lhs.boundingBox.minX != rhs.boundingBox.minX {
                                return lhs.boundingBox.minX < rhs.boundingBox.minX
                            }
                            if lhs.boundingBox.width != rhs.boundingBox.width {
                                return lhs.boundingBox.width > rhs.boundingBox.width
                            }
                            return lhs.boundingBox.height > rhs.boundingBox.height
                        }
                }
            } catch {
                try Task.checkCancellation()
                failedFrames += 1
                firstFailure = firstFailure ?? error.localizedDescription
                continue
            }
            try Task.checkCancellation()
            previousTime = frame.actualTime
            sampledFrames += 1
            for (ordinal, face) in faces.enumerated() {
                try Task.checkCancellation()
                let cropFile = "frame-\(index)-face-\(ordinal).jpg"
                let crop = try autoreleasepool {
                    try Self.writeCrop(
                        image: frame.image,
                        box: face.boundingBox,
                        url: cropDirectory.appendingPathComponent(cropFile, isDirectory: false)
                    )
                }
                guard crop else {
                    invalidCrops += 1
                    continue
                }
                appearances.append(Appearance(
                    id: "\(appearancePrefix):\(index):\(ordinal)",
                    clipID: clip.id,
                    seconds: frame.actualTime.seconds,
                    confidence: Double(face.confidence),
                    cropFile: cropFile
                ))
            }
        }

        try Task.checkCancellation()
        guard try FileStamp.read(source) == stamp else { throw FaceScanError.sourceChanged }
        guard sampledFrames > 0 else { throw FaceScanError.noFrames(firstFailure) }
        var warnings: [String] = []
        if failedFrames > 0 {
            warnings.append("Could not decode or inspect \(failedFrames) of \(sampleCount) requested frames. \(firstFailure ?? "")")
        }
        if repeatedFrameTimes > 0 {
            warnings.append("\(repeatedFrameTimes) requests returned the same decoded frame as the preceding sample.")
        }
        if invalidCrops > 0 {
            warnings.append("\(invalidCrops) face rectangles had no usable area for a thumbnail.")
        }
        return ScanResult(
            clipID: clip.id, stamp: stamp, duration: duration,
            sampledFrames: sampledFrames, appearances: appearances, warnings: warnings
        )
    }

    private static func writeCrop(image: CGImage, box: CGRect, url: URL) throws -> Bool {
        guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else { return false }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Vision uses a bottom-left normalized origin. CGImage uses top-left crop coordinates.
        let face = CGRect(
            x: box.minX * width, y: (1 - box.maxY) * height,
            width: box.width * width, height: box.height * height
        )
        let rectangle = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rectangle.isEmpty, let cropped = image.cropping(to: rectangle) else { return false }
        let maxSide = max(cropped.width, cropped.height)
        var thumbnail = cropped
        if maxSide > 320 {
            let scale = 320 / Double(maxSide)
            let targetWidth = max(1, Int((Double(cropped.width) * scale).rounded()))
            let targetHeight = max(1, Int((Double(cropped.height) * scale).rounded()))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                    bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { throw FaceScanError.cropEncodingFailed }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let scaled = context.makeImage() else { throw FaceScanError.cropEncodingFailed }
            thumbnail = scaled
        }
        let bytes = NSMutableData()
        guard let jpeg = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FaceScanError.cropEncodingFailed
        }
        CGImageDestinationAddImage(jpeg, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(jpeg), bytes.length <= 512 * 1024 else {
            throw FaceScanError.cropEncodingFailed
        }
        try (bytes as Data).write(to: url, options: .withoutOverwriting)
        return true
    }
}

private enum FaceScanError: LocalizedError {
    case invalidInterval
    case invalidSource
    case invalidCropDirectory
    case noVideoTrack
    case invalidDuration
    case invalidFrameTime
    case noFrames(String?)
    case sourceChanged
    case cropEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidInterval: return "Choose a finite sampling interval of at least 1/600 second."
        case .invalidSource: return "Choose a regular video file that is not a symbolic link."
        case .invalidCropDirectory: return "The scan's thumbnail directory is missing or is a symbolic link."
        case .noVideoTrack: return "The selected file has no video track."
        case .invalidDuration: return "The video does not have a usable finite duration."
        case .invalidFrameTime: return "The decoder returned an invalid frame timestamp."
        case .noFrames(let detail):
            return "No video frames could be inspected. Check that the clip plays, then retry. \(detail ?? "")"
        case .sourceChanged: return "The video changed during scanning. Retry after the file is stable."
        case .cropEncodingFailed: return "A face thumbnail could not be encoded. Check available storage, then retry."
        }
    }
}
