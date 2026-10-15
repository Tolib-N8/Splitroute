// Запись одного окна Splitroute через ScreenCaptureKit (видно даже то, что перекрыто).
//   record <main|panel> <seconds> <out.mov>
// Ждёт появления окна до 15 с и начинает с первого кадра — так попадает и анимация приветствия.
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// Без подключения к оконному серверу ScreenCaptureKit падает в CGS_REQUIRE_INIT.
_ = NSApplication.shared

let args = CommandLine.arguments
guard args.count == 4, let seconds = Double(args[2]) else {
    FileHandle.standardError.write("usage: record <main|panel> <seconds> <out.mov>\n".data(using: .utf8)!)
    exit(2)
}
let kind = args[1], outURL = URL(fileURLWithPath: args[3])
try? FileManager.default.removeItem(at: outURL)

func findWindow() async -> SCWindow? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
    return content.windows.first { w in
        guard w.owningApplication?.applicationName == "Splitroute", w.windowLayer == 0 else { return false }
        return kind == "panel" ? (w.title == "Splitroute Panel") : (w.frame.width > 900)
    }
}

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000, AVVideoExpectedSourceFrameRateKey: 60],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        if !started {
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb); frames += 1 }
    }
}

var window: SCWindow?
for _ in 0..<300 {
    window = await findWindow()
    if window != nil { break }
    try? await Task.sleep(for: .milliseconds(50))
}
guard let window else { print("window not found"); exit(1) }

let filter = SCContentFilter(desktopIndependentWindow: window)
// Масштаб дисплея (1× на обычном мониторе, 2× на Retina) — иначе окно займёт четверть кадра.
let scale = CGFloat(filter.pointPixelScale)
let config = SCStreamConfiguration()
config.width = Int(window.frame.width * scale)
config.height = Int(window.frame.height * scale)
config.captureResolution = .best
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.showsCursor = false
config.queueDepth = 8

let recorder = try Recorder(url: outURL, width: config.width, height: config.height)
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec"))
try await stream.startCapture()
try await Task.sleep(for: .seconds(seconds))
try await stream.stopCapture()
recorder.input.markAsFinished()
await recorder.writer.finishWriting()
print("recorded \(recorder.frames) frames \(config.width)x\(config.height) → \(outURL.path)")
