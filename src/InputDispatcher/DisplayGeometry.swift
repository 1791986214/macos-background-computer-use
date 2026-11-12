import Foundation
import CoreGraphics
import AppKit

// ============================================================
// DisplayCoordinateTransformer —— 坐标空间的唯一入口
//
// v0.4.2 的问题不是「翻转公式错」，而是**把所有点都当成在主屏上**：
// Ghost 定位时用 `NSScreen.screens.first` 取屏幕尺寸，然后把窗口夹进这块屏幕。
// 一旦目标窗口在副屏（尤其是负 X 的左侧副屏），光标会被夹回主屏 ——
// 画的位置和点的位置就不是同一处了。
//
// 这里把四个坐标空间显式命名，并且只允许通过本模块互转：
//
//   ① CGGlobal    CoreGraphics 全局坐标，左上原点，y 向下，主屏左上为 (0,0)
//                  → CGEvent、CGWindowList、AXPosition 都在这套里
//   ② AppKit      AppKit 屏幕坐标，左下原点，y 向上，主屏左下为 (0,0)
//                  → NSScreen.frame / NSWindow.frame 在这套里
//   ③ WindowLocal 目标窗口局部坐标，左上原点，y 向下，以窗口 bounds 左上角为 (0,0)
//                  → CGEventSetWindowLocation、AX 相对定位用
//   ④ CapturePixel ScreenCaptureKit 图像像素坐标，窗口左上原点，y 向下
//                  → 与 ③ 之间只差一个 backingScale
//
// 关键事实（容易搞错的地方）：
//   · **点的翻转是全局的**：appkitY = primaryHeight − cgY，与目标在哪块屏无关。
//   · **矩形的翻转是逐边的**：appkitRect.y = primaryHeight − cgRect.maxY。
//   · 但「选哪块屏」是局部的：必须按点所在的 CG 矩形去选，不能默认主屏。
//
// 所有函数都是纯函数（displays 可注入），因此副屏、负坐标、混合缩放的场景
// 可以脱离硬件做单元测试 —— 硬件没接的场景仍然标 Not Tested。
// ============================================================

struct DisplayInfo: Equatable {
    var id: String
    var cgFrame: CGRect          // 左上原点，可负
    var appKitFrame: CGRect      // 左下原点
    var backingScale: CGFloat
    var isPrimary: Bool

    var cgBounds: CGRect { cgFrame }
}

enum CoordSpace: String {
    case cgGlobal, appKit, windowLocal, capturePixel
}

enum DisplayCoordinateTransformer {

    // MARK: - 读取真实显示器

    static func liveDisplays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryH = primary.frame.height
        return screens.map { s in
            let f = s.frame
            // AppKit 矩形 → CG 矩形：y 是逐边翻转
            let cg = CGRect(x: f.minX, y: primaryH - f.maxY,
                            width: f.width, height: f.height)
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            return DisplayInfo(
                id: num.map { String($0) } ?? s.localizedName,
                cgFrame: cg,
                appKitFrame: f,
                backingScale: s.backingScaleFactor,
                isPrimary: (f.origin == .zero)
            )
        }
    }

    static func primaryHeight(_ displays: [DisplayInfo]) -> CGFloat {
        (displays.first(where: { $0.isPrimary }) ?? displays.first)?.appKitFrame.height ?? 0
    }

    // MARK: - 点转换

    static func pointCGToAppKit(_ p: CGPoint, displays: [DisplayInfo] = liveDisplays()) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight(displays) - p.y)
    }

    static func pointAppKitToCG(_ p: CGPoint, displays: [DisplayInfo] = liveDisplays()) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight(displays) - p.y)   // 自反
    }

    // MARK: - 矩形转换

    static func rectCGToAppKit(_ r: CGRect, displays: [DisplayInfo] = liveDisplays()) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight(displays) - r.maxY,
               width: r.width, height: r.height)
    }

    static func rectAppKitToCG(_ r: CGRect, displays: [DisplayInfo] = liveDisplays()) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight(displays) - r.maxY,
               width: r.width, height: r.height)
    }

    // MARK: - 显示器归属

    /// 按 CG 全局点找所属显示器；落在所有屏幕之外时返回最近的（不返回 nil，
    /// 避免调用方因为「找不到」而退化回主屏 —— 那正是 v0.4.2 的毛病）
    static func display(containingCG p: CGPoint, displays: [DisplayInfo] = liveDisplays()) -> DisplayInfo? {
        if let d = displays.first(where: { $0.cgFrame.contains(p) }) { return d }
        return displays.min(by: { distance($0.cgFrame, p) < distance($1.cgFrame, p) })
    }

    static func display(containingAppKit p: CGPoint, displays: [DisplayInfo] = liveDisplays()) -> DisplayInfo? {
        if let d = displays.first(where: { $0.appKitFrame.contains(p) }) { return d }
        return displays.min(by: { distance($0.appKitFrame, p) < distance($1.appKitFrame, p) })
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    // MARK: - 窗口局部

    /// 全局点 → 窗口局部（左上原点）。这是字段 51 投递里 `CGEventSetWindowLocation` 要的值。
    static func windowLocal(_ global: CGPoint, windowFrameCG: CGRect) -> CGPoint {
        CGPoint(x: global.x - windowFrameCG.minX, y: global.y - windowFrameCG.minY)
    }

    static func windowGlobal(_ local: CGPoint, windowFrameCG: CGRect) -> CGPoint {
        CGPoint(x: windowFrameCG.minX + local.x, y: windowFrameCG.minY + local.y)
    }

    // MARK: - 捕获像素

    /// 窗口局部点 → 捕获图像像素坐标（左上原点，y 向下）
    static func windowLocalToCapturePixel(_ local: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: local.x * scale, y: local.y * scale)
    }

    /// 捕获图像像素 → 窗口局部（反向，用于「看图找元素」后点回去）
    static func capturePixelToWindowLocal(_ px: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return px }
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }

    // MARK: - 统一入口

    /// 把一个 CG 全局点换算成「该点所属显示器 + 该显示器内的 AppKit 点 + 局部点」
    struct Resolved {
        var display: DisplayInfo
        var cg: CGPoint
        var appKit: CGPoint
        var localInDisplay: CGPoint      // 相对该显示器 CG 左上角
    }

    static func resolve(cg p: CGPoint, displays: [DisplayInfo] = liveDisplays()) -> Resolved? {
        guard let d = display(containingCG: p, displays: displays) else { return nil }
        return Resolved(display: d, cg: p,
                        appKit: pointCGToAppKit(p, displays: displays),
                        localInDisplay: CGPoint(x: p.x - d.cgFrame.minX, y: p.y - d.cgFrame.minY))
    }

    // MARK: - 自我诊断（`wbcu displays` 用）

    static func describe(_ displays: [DisplayInfo] = liveDisplays()) -> [[String: Any]] {
        displays.map { d in
            ["id": d.id, "primary": d.isPrimary, "scale": d.backingScale,
             "cgFrame": ["x": d.cgFrame.minX, "y": d.cgFrame.minY,
                         "w": d.cgFrame.width, "h": d.cgFrame.height],
             "appKitFrame": ["x": d.appKitFrame.minX, "y": d.appKitFrame.minY,
                             "w": d.appKitFrame.width, "h": d.appKitFrame.height]]
        }
    }
}
