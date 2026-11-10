import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import ImageIO
import ScreenCaptureKit

// MARK: - PNG 写出
@discardableResult
func writePNG(_ img: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

@discardableResult
func writeJPEG(_ img: CGImage, to url: URL, quality: Double = 0.8) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

// MARK: - 窗口单帧截图
func captureWindowOnce(windowId: CGWindowID, maxWidth: Int?, to url: URL) -> Bool {
    let res = awaitSync { () -> CGImage? in
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == windowId }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var w = Int(win.frame.width * scale)
        var h = Int(win.frame.height * scale)
        if let mw = maxWidth, w > mw {
            let r = Double(mw) / Double(w)
            w = mw
            h = Int(Double(h) * r)
        }
        cfg.width = max(w, 2)
        cfg.height = max(h, 2)
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.ignoreGlobalClipSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
    switch res {
    case .success(let img?):
        return writePNG(img, to: url)
    case .success(nil):
        FileHandle.standardError.write("窗口 \(windowId) 不存在或不可捕获\n".data(using: .utf8)!)
        return false
    case .failure(let e):
        FileHandle.standardError.write("截图失败: \(e)\n".data(using: .utf8)!)
        return false
    }
}

// MARK: - 屏幕区域截图（走 display filter + 裁剪）
func captureRegion(_ rect: CGRect, to url: URL) -> Bool {
    let res = awaitSync { () -> CGImage? in
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: {
            $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) ?? content.displays.first else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(display.frame.width * scale)
        cfg.height = Int(display.frame.height * scale)
        cfg.showsCursor = false
        cfg.capturesAudio = false
        guard let full = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return nil }
        // 换算到像素坐标后裁剪
        let local = CGRect(x: (rect.minX - display.frame.minX) * scale,
                           y: (rect.minY - display.frame.minY) * scale,
                           width: rect.width * scale, height: rect.height * scale)
        return full.cropping(to: local) ?? full
    }
    switch res {
    case .success(let img?): return writePNG(img, to: url)
    case .success(nil):
        FileHandle.standardError.write("区域截图没有得到图像\n".data(using: .utf8)!)
        return false
    case .failure(let e):
        FileHandle.standardError.write("区域截图失败: \(e)\n".data(using: .utf8)!)
        return false
    }
}

// MARK: - 像素分析：紫胶囊检测
struct PixelStats {
    var purpleCount: Int
    var dominant: (r: Int, g: Int, b: Int)
    var bbox: CGRect?
    var width: Int
    var height: Int
}

func rgbaBuffer(_ img: CGImage) -> ([UInt8], Int, Int)? {
    let w = img.width, h = img.height
    guard w > 0, h > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}

/// 系统窗口共享指示器是紫/靛蓝胶囊（约 #6355E8）。判据：蓝通道显著高于红绿、且红绿接近。
func analyzePurple(_ img: CGImage) -> PixelStats? {
    guard let (buf, w, h) = rgbaBuffer(img) else { return nil }
    var count = 0
    var minX = w, minY = h, maxX = 0, maxY = 0
    var sr = 0, sg = 0, sb = 0, n = 0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            // 紫/靛蓝：b 高、b-r 与 b-g 都很大、r 与 g 相近（排除纯蓝链接色）
            if b > 150, b - r > 90, b - g > 90, abs(r - g) < 70, r > 30, g > 25 {
                count += 1
                sr += r; sg += g; sb += b; n += 1
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
    }
    let dom = n > 0 ? (r: sr / n, g: sg / n, b: sb / n) : (0, 0, 0)
    let bbox: CGRect? = n > 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
    return PixelStats(purpleCount: count, dominant: dom, bbox: bbox, width: w, height: h)
}

// MARK: - 命令：shot
func cmdShot(_ args: Args) {
    gJSONMode = args.flag("json")
    let outPath = args.str("out") ?? tmpDir().appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png").path
    let url = URL(fileURLWithPath: outPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var ok = false
    if let wid = args.int("window") {
        ok = captureWindowOnce(windowId: CGWindowID(wid), maxWidth: args.int("max-width"), to: url)
    } else if let pid = args.int("pid"), let wid = mainWindowId(for: pid_t(pid)) {
        ok = captureWindowOnce(windowId: wid, maxWidth: args.int("max-width"), to: url)
    } else if let appToken = args.str("app"), let app = findRunningApp(appToken),
              let wid = mainWindowId(for: app.processIdentifier) {
        ok = captureWindowOnce(windowId: wid, maxWidth: args.int("max-width"), to: url)
    } else {
        let r = CGRect(x: args.dbl("x") ?? 0, y: args.dbl("y") ?? 0,
                       width: args.dbl("w") ?? 0, height: args.dbl("h") ?? 0)
        guard r.width > 0, r.height > 0 else { fail("需要 --window <id> / --app / --pid，或 --x --y --w --h 区域") }
        ok = captureRegion(r, to: url)
    }

    var stats: PixelStats? = nil
    if ok, args.flag("analyze") || args.flag("purple"),
       let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        stats = analyzePurple(img)
    }
    if gJSONMode {
        var d: [String: Any] = ["ok": ok, "path": outPath]
        if let s = stats {
            d["purplePixels"] = s.purpleCount
            d["purpleRatio"] = Double(s.purpleCount) / Double(max(1, s.width * s.height))
            if let bb = s.bbox { d["purpleBBox"] = ["x": bb.minX, "y": bb.minY, "w": bb.width, "h": bb.height] }
            d["dominant"] = [s.dominant.r, s.dominant.g, s.dominant.b]
        }
        emit(d)
    } else {
        if ok {
            var line = "✅ \(outPath)"
            if let s = stats {
                line += "  purple=\(s.purpleCount)px rgb=\(s.dominant.r),\(s.dominant.g),\(s.dominant.b)"
                if let bb = s.bbox { line += " bbox=\(Int(bb.minX)),\(Int(bb.minY)) \(Int(bb.width))x\(Int(bb.height))" }
            }
            emitText(line)
        } else { emitText("❌ 截图失败") }
    }
    exit(ok ? 0 : 1)
}

// MARK: - 命令：analyze（对已有 PNG 做紫胶囊分析）
func cmdAnalyze(_ args: Args) {
    gJSONMode = args.flag("json")
    guard let p = args.positional.first else { fail("需要图片路径") }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("读不到图片: \(p)") }
    guard let s = analyzePurple(img) else { fail("像素分析失败") }
    let ratio = Double(s.purpleCount) / Double(max(1, s.width * s.height))
    if gJSONMode {
        var d: [String: Any] = ["ok": true, "purplePixels": s.purpleCount, "ratio": ratio,
                                "dominant": [s.dominant.r, s.dominant.g, s.dominant.b],
                                "size": [s.width, s.height],
                                "verdict": ratio > 0.002 ? "存在紫色胶囊候选" : "未见紫色区域"]
        if let bb = s.bbox { d["bbox"] = ["x": bb.minX, "y": bb.minY, "w": bb.width, "h": bb.height] }
        emit(d)
    } else {
        emitText("像素 \(s.width)x\(s.height) 紫色像素=\(s.purpleCount) 占比=\(String(format: "%.4f", ratio)) 主色=\(s.dominant.r),\(s.dominant.g),\(s.dominant.b)")
    }
    exit(0)
}

// MARK: - SCStream 持续捕获
final class StreamBox: NSObject, SCStreamOutput, SCStreamDelegate {
    var frameCount = 0
    var lastImage: CGImage?
    var errorText: String?
    var outputDir: URL?
    var saveEvery = 1
    let lock = NSLock()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 只取完整帧（避免 idle 帧）
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let status = arr.first?[SCStreamFrameInfo.status.rawValue] as? Int,
           status != Int(SCFrameStatus.complete.rawValue) {
            return
        }
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        lock.lock()
        frameCount += 1
        lastImage = cg
        let n = frameCount
        lock.unlock()
        if let dir = outputDir, n % saveEvery == 0, n <= 6 {
            let f = dir.appendingPathComponent(String(format: "frame-%03d.png", n))
            _ = writePNG(cg, to: f)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorText = "\(error)"
    }
}

func cmdStream(_ args: Args) {
    gJSONMode = args.flag("json")
    let seconds = args.dbl("seconds") ?? 6.0
    let wid: CGWindowID? = args.int("window").map { CGWindowID($0) }
        ?? args.int("pid").flatMap { mainWindowId(for: pid_t($0)) }
        ?? args.str("app").flatMap { findRunningApp($0) }.flatMap { mainWindowId(for: $0.processIdentifier) }
    guard let windowId = wid else { fail("需要 --window <id> 或 --app/--pid") }
    enforceGuard(pid: args.int("pid").map { pid_t($0) } ?? pidForWindow(windowId) ?? 0, action: "stream")

    var outDirPath: String? = nil
    let dir: URL? = {
        guard let d = args.str("dir") else { return nil }
        let u = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    outDirPath = dir?.path

    let box = StreamBox()
    box.outputDir = dir
    box.saveEvery = args.int("save-every") ?? 1

    let sem = DispatchSemaphore(value: 0)
    var started = false
    var startError: String? = nil
    var streamRef: SCStream?
    var cfgInfo: [String: Any] = [:]

    Task.detached {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let win = content.windows.first(where: { $0.windowID == windowId }) else {
                startError = "窗口 \(windowId) 不在可共享列表中"
                sem.signal(); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = max(Int(win.frame.width * scale), 2)
            cfg.height = max(Int(win.frame.height * scale), 2)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            cfg.queueDepth = 5
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.scalesToFit = false
            cfgInfo = ["windowId": Int(windowId), "width": cfg.width, "height": cfg.height,
                       "app": win.owningApplication?.applicationName ?? "",
                       "title": win.title ?? "",
                       "scale": Double(scale)]
            let s = SCStream(filter: filter, configuration: cfg, delegate: box)
            try s.addStreamOutput(box, type: .screen, sampleHandlerQueue: DispatchQueue(label: "wbcu.stream"))
            try await s.startCapture()
            streamRef = s
            started = true
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            try? await s.stopCapture()
            sem.signal()
        } catch {
            startError = "\(error)"
            sem.signal()
        }
    }

    // 保持进程存活（RunLoop 让 CG/SCK 的回调正常跑）
    let deadline = Date().addingTimeInterval(seconds + 20)
    while sem.wait(timeout: .now() + 0.2) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        if Date() > deadline { break }
    }
    _ = streamRef

    let frames = box.frameCount
    var stats: [String: Any] = [:]
    if let img = box.lastImage, let s = analyzePurple(img) {
        stats = ["purplePixels": s.purpleCount,
                 "ratio": Double(s.purpleCount) / Double(max(1, s.width * s.height))]
    }
    if gJSONMode {
        var d: [String: Any] = ["ok": started, "frames": frames, "capture": cfgInfo]
        if let e = startError { d["error"] = e }
        if let o = outDirPath { d["dir"] = o }
        d["frameAnalysis"] = stats
        emit(d)
    } else if started {
        var line = "✅ 持续捕获 \(frames) 帧（\(seconds)s） \(cfgInfo["width"] ?? 0)x\(cfgInfo["height"] ?? 0)"
        if let o = outDirPath { line += "\n   帧目录: \(o)" }
        if let e = startError { line += "\n   ⚠️ \(e)" }
        emitText(line)
    } else {
        emitText("❌ 捕获启动失败: \(startError ?? "unknown")")
    }
    exit(started ? 0 : 1)
}
