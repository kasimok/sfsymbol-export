// SF Symbol → clean SVG, built on Apple's `sfsymbols` CLI (ships inside SF Symbols.app, Xcode 27 era).
//
// The CLI's PDF export is the symbol renderer's own vector output. This script rewrites it as a
// minimal SVG — black → currentColor, layer opacity kept, tight viewBox; monochrome merged into one
// <path> — then checks every SVG against the CLI's PNG export of the same symbol (IoU of alpha masks).
// When the CLI writes a bitmap instead (a layer erases the ones below it), the outlines come from a
// mode that stays vector, or — monochrome at medium scale — from the SF Pro glyph.
//
// Usage: swift export.swift [options] <outDir> <name>...
//   --weight <w>   ultralight thin light regular medium semibold bold heavy black (default regular)
//   --scale <s>    small | medium | large (default medium — what Image(systemName:) uses)
//   --mode <m>     monochrome | hierarchical | palette | multicolor (default monochrome)
// Writes <outDir>/<name>.svg per symbol and <outDir>/_sheet.png: [name iou | CLI PNG | SVG render].
// Env: SFSYMBOLS_CLI overrides the CLI path.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Config: Sendable {
    var weight = "regular", scale = "medium", mode = "monochrome"
    var outDir = URL(fileURLWithPath: ".")
    var cli = ProcessInfo.processInfo.environment["SFSYMBOLS_CLI"]
        ?? "/Applications/SF Symbols.app/Contents/Executables/sfsymbols"
}

/// Pixel scale of the PNG ground truth; 2 keeps thin strokes (ultralight) measurable.
let checkScale: CGFloat = 2
/// Below this the SVG is flagged. Measured on 360 random symbols: PDF-sourced exports score ≥ 0.986;
/// font-glyph ones dip to ~0.975 on fine dotted shapes while still correct.
let iouWarn = 0.98

// MARK: - Model

/// One filled region, in SVG space (y down, page origin).
struct Layer: @unchecked Sendable {
    var path: CGPath
    var evenOdd: Bool
    var rgb: [CGFloat]   // 1 (gray) or 3 (RGB) components
    var alpha: CGFloat
}

struct Result: @unchecked Sendable {
    var line: String
    var ok: Bool
    var png: CGImage?
    var svgRender: CGImage?
}

// MARK: - CLI

/// Runs the CLI; returns (stdout, nil) on success or (nil, error message).
func cli(_ cfg: Config, _ args: [String]) -> (out: Data?, err: String?) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cfg.cli)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (nil, "cannot launch \(cfg.cli): \(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()   // outputs are small; no pipe-buffer deadlock
    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return p.terminationStatus == 0 ? (data, nil) : (nil, msg.trimmingCharacters(in: .whitespacesAndNewlines))
}

func runCLI(_ cfg: Config, _ args: [String]) -> String? { cli(cfg, args).err }

func exportArgs(_ cfg: Config, _ name: String, mode: String) -> [String] {
    ["export", name, "--weight", cfg.weight, "--symbol-scale", cfg.scale, "--rendering-mode", mode,
     // Black maps back to currentColor unambiguously; the default `label` color is 85% alpha.
     "--color", "black"]
}

// MARK: - PDF content-stream walker

/// Graphics state that q/Q save and restore.
struct GState {
    var ctm = CGAffineTransform.identity
    var clip: (path: CGPath, evenOdd: Bool)?
    var rgb: [CGFloat] = [0]
    var alpha: CGFloat = 1
}

final class Walker {
    var gs = GState()
    var saved: [GState] = []
    var path = CGMutablePath()
    var pendingClip: (path: CGPath, evenOdd: Bool)?
    var layers: [Layer] = []
    var warnings: Set<String> = []
    var raster = false
    var extGState: [String: CGFloat] = [:]   // resource name → fill alpha (/ca)
    let flip: CGAffineTransform               // PDF y-up page → SVG y-down

    init(page: CGPDFPage) {
        let box = page.getBoxRect(.mediaBox)
        flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
        if let res = page.dictionary.flatMap({ dict($0, "Resources") }), let egs = dict(res, "ExtGState") {
            CGPDFDictionaryApplyBlock(egs, { key, obj, _ in
                var d: CGPDFDictionaryRef?
                var ca: CGPDFReal = 1
                if CGPDFObjectGetValue(obj, .dictionary, &d), let d, CGPDFDictionaryGetNumber(d, "ca", &ca) {
                    self.extGState[String(cString: key)] = CGFloat(ca)
                }
                return true
            }, nil)
        }
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y).applying(gs.ctm.concatenating(flip))
    }

    func paint(evenOdd: Bool) {
        if let clip = gs.clip {
            // CoreGraphics' PDF writer encodes each layer as "clip to the glyph, fill a covering rect",
            // so the clip is the real shape. Anything else would need clip ∩ path.
            if !path.isEmpty, !path.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).contains(clip.path.boundingBoxOfPath) {
                warnings.insert("fill does not cover its clip; clip used as-is")
            }
            layers.append(Layer(path: clip.path, evenOdd: clip.evenOdd, rgb: gs.rgb, alpha: gs.alpha))
        } else if !path.isEmpty {
            layers.append(Layer(path: path.copy()!, evenOdd: evenOdd, rgb: gs.rgb, alpha: gs.alpha))
        }
        path = CGMutablePath()
    }
}

func dict(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
    var out: CGPDFDictionaryRef?
    return CGPDFDictionaryGetDictionary(d, key, &out) ? out : nil
}

/// Pops up to `n` numeric operands, returned in stream order. n = nil pops all of them
/// (sc/scn take as many operands as the color space has components).
func popNumbers(_ s: CGPDFScannerRef, _ n: Int? = nil) -> [CGFloat] {
    var out: [CGFloat] = []
    var v: CGPDFReal = 0
    while out.count < (n ?? .max), CGPDFScannerPopNumber(s, &v) { out.append(CGFloat(v)) }
    return out.reversed()
}

func walker(_ info: UnsafeMutableRawPointer?) -> Walker {
    Unmanaged<Walker>.fromOpaque(info!).takeUnretainedValue()
}

func makeOperatorTable() -> CGPDFOperatorTableRef {
    let t = CGPDFOperatorTableCreate()!
    CGPDFOperatorTableSetCallback(t, "q") { _, i in let w = walker(i); w.saved.append(w.gs) }
    CGPDFOperatorTableSetCallback(t, "Q") { _, i in let w = walker(i); if let g = w.saved.popLast() { w.gs = g } }
    CGPDFOperatorTableSetCallback(t, "cm") { s, i in
        let w = walker(i), m = popNumbers(s, 6)
        guard m.count == 6 else { return }
        w.gs.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(w.gs.ctm)
    }
    CGPDFOperatorTableSetCallback(t, "m") { s, i in
        let w = walker(i), p = popNumbers(s, 2); w.path.move(to: w.point(p[0], p[1]))
    }
    CGPDFOperatorTableSetCallback(t, "l") { s, i in
        let w = walker(i), p = popNumbers(s, 2); w.path.addLine(to: w.point(p[0], p[1]))
    }
    CGPDFOperatorTableSetCallback(t, "c") { s, i in
        let w = walker(i), p = popNumbers(s, 6)
        w.path.addCurve(to: w.point(p[4], p[5]), control1: w.point(p[0], p[1]), control2: w.point(p[2], p[3]))
    }
    CGPDFOperatorTableSetCallback(t, "v") { s, i in
        let w = walker(i), p = popNumbers(s, 4)
        w.path.addCurve(to: w.point(p[2], p[3]), control1: w.path.currentPoint, control2: w.point(p[0], p[1]))
    }
    CGPDFOperatorTableSetCallback(t, "y") { s, i in
        let w = walker(i), p = popNumbers(s, 4)
        w.path.addCurve(to: w.point(p[2], p[3]), control1: w.point(p[0], p[1]), control2: w.point(p[2], p[3]))
    }
    CGPDFOperatorTableSetCallback(t, "h") { _, i in walker(i).path.closeSubpath() }
    CGPDFOperatorTableSetCallback(t, "re") { s, i in
        let w = walker(i), r = popNumbers(s, 4)
        w.path.move(to: w.point(r[0], r[1]))
        w.path.addLine(to: w.point(r[0] + r[2], r[1]))
        w.path.addLine(to: w.point(r[0] + r[2], r[1] + r[3]))
        w.path.addLine(to: w.point(r[0], r[1] + r[3]))
        w.path.closeSubpath()
    }
    CGPDFOperatorTableSetCallback(t, "W") { _, i in let w = walker(i); w.pendingClip = (w.path.copy()!, false) }
    CGPDFOperatorTableSetCallback(t, "W*") { _, i in let w = walker(i); w.pendingClip = (w.path.copy()!, true) }
    CGPDFOperatorTableSetCallback(t, "n") { _, i in
        let w = walker(i)
        if let c = w.pendingClip {
            if w.gs.clip != nil { w.warnings.insert("nested clips; only the innermost is kept") }
            w.gs.clip = c
        }
        w.pendingClip = nil
        w.path = CGMutablePath()
    }
    CGPDFOperatorTableSetCallback(t, "f") { _, i in walker(i).paint(evenOdd: false) }
    CGPDFOperatorTableSetCallback(t, "F") { _, i in walker(i).paint(evenOdd: false) }
    CGPDFOperatorTableSetCallback(t, "f*") { _, i in walker(i).paint(evenOdd: true) }
    // The renderer falls back to an embedded bitmap when a layer must erase what is under it.
    CGPDFOperatorTableSetCallback(t, "Do") { _, i in walker(i).raster = true }
    for op in ["S", "s", "B", "B*", "b", "b*", "sh", "Tj", "TJ"] {
        CGPDFOperatorTableSetCallback(t, op) { _, i in walker(i).warnings.insert("unsupported paint operator (stroke/shading/text)") }
    }
    for op in ["sc", "scn", "rg", "g"] {
        CGPDFOperatorTableSetCallback(t, op) { s, i in
            let w = walker(i), c = popNumbers(s)
            if c.count == 1 || c.count == 3 { w.gs.rgb = c } else { w.warnings.insert("unsupported color with \(c.count) components") }
        }
    }
    CGPDFOperatorTableSetCallback(t, "gs") { s, i in
        let w = walker(i)
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(s, &name), let name else { return }
        if let a = w.extGState[String(cString: name)] { w.gs.alpha = a }
    }
    return t
}

func walk(pdf: URL) -> (Walker, CGRect)? {
    guard let doc = CGPDFDocument(pdf as CFURL), let page = doc.page(at: 1) else { return nil }
    let w = Walker(page: page)
    let scanner = CGPDFScannerCreate(CGPDFContentStreamCreateWithPage(page), makeOperatorTable(),
                                     Unmanaged.passUnretained(w).toOpaque())
    CGPDFScannerScan(scanner)
    return (w, page.getBoxRect(.mediaBox))
}

// MARK: - Knockout fallback (monochrome, hierarchical)

/// Per-layer rule for one rendering mode, from the CLI's template SVG (`.<mode>-N[:level] {…}`).
struct LayerRule {
    var hidden: Bool        // opacity:0
    var clearBehind: Bool   // -sfsymbols-clear-behind:true — erases the layers below it
    var level: String?      // hierarchical only: primary | secondary | tertiary
}

/// Hierarchical level → layer opacity, measured from vector hierarchical exports (--color black).
let levelAlpha: [String: CGFloat] = ["primary": 1, "secondary": 0.5, "tertiary": 0.18]

func templateRules(_ templateSVG: URL, mode: String) -> [LayerRule]? {
    guard let text = try? String(contentsOf: templateSVG, encoding: .utf8) else { return nil }
    let re = try! NSRegularExpression(pattern: #"\.\#(mode)-(\d+)(?::(\w+))? \{([^}]*)\}"#)
    var rules: [Int: LayerRule] = [:]
    for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let group = { (i: Int) in Range(m.range(at: i), in: text).map { String(text[$0]) } }
        let body = group(3)!.replacingOccurrences(of: " ", with: "")
        rules[Int(group(1)!)!] = LayerRule(hidden: body.contains("opacity:0;") || body.contains("opacity:0.0;"),
                                           clearBehind: body.contains("-sfsymbols-clear-behind:true"),
                                           level: group(2))
    }
    guard !rules.isEmpty, rules.keys.sorted() == Array(0..<rules.count) else { return nil }
    return (0..<rules.count).map { rules[$0]! }
}

/// When a layer erases the ones below it (the checkmark cut out of checkmark.circle.fill), the CLI
/// writes a bitmap PDF. Every rendering mode shares one set of layer outlines, so take them from a
/// mode that stays vector and apply the target mode's template rules with path boolean operations.
func knockout(_ cfg: Config, _ name: String, tmp: URL) -> ([Layer], CGRect, String)? {
    let tpl = tmp.appendingPathComponent("\(name).template.svg")
    guard ["monochrome", "hierarchical"].contains(cfg.mode),
          runCLI(cfg, ["export", name, "--format", "svg", "--output", tpl.path]) == nil,
          let rules = templateRules(tpl, mode: cfg.mode) else { return nil }
    for donor in ["hierarchical", "multicolor", "palette", "monochrome"] where donor != cfg.mode {
        let pdf = tmp.appendingPathComponent("\(name).\(donor).pdf")
        guard runCLI(cfg, exportArgs(cfg, name, mode: donor) + ["--format", "pdf", "--output", pdf.path]) == nil,
              let (w, box) = walk(pdf: pdf), !w.raster, w.layers.count == rules.count else { continue }
        var out: [Layer] = []
        for (layer, rule) in zip(w.layers, rules) {
            let fill: CGPathFillRule = layer.evenOdd ? .evenOdd : .winding
            if rule.clearBehind {
                out = out.map { var l = $0; l.path = l.path.subtracting(layer.path, using: fill); return l }
            } else if !rule.hidden {
                let alpha = cfg.mode == "monochrome" ? 1 : rule.level.flatMap { levelAlpha[$0] }
                guard let alpha else { return nil }   // an unmeasured level; don't guess its opacity
                // Normalize so every layer means the same thing under the default nonzero rule.
                out.append(Layer(path: layer.path.normalized(using: fill), evenOdd: false, rgb: [0], alpha: alpha))
            }
        }
        return out.isEmpty ? nil : (out, box, donor)
    }
    return nil
}

/// Monochrome layers all share one color, so they collapse into a single <path> — one `d` string per
/// symbol for consumers that store bare path data. Plain concatenation is wrong: where two nonzero
/// layers overlap with opposite winding they would cancel into a hole. Even a single layer is
/// normalized (overlaps removed) because the raw outlines rely on nonzero winding: crossing strokes
/// (plus, xmark, arrow heads) turn into holes under fill-rule="evenodd", which Cineo's kit.js hard-codes.
func mergedMonochrome(_ layers: [Layer]) -> [Layer] {
    guard !layers.isEmpty, Set(layers.map(\.alpha)).count == 1, Set(layers.map(\.rgb)).count == 1 else { return layers }
    let shapes = layers.map { $0.path.normalized(using: $0.evenOdd ? .evenOdd : .winding) }
    let merged = shapes.dropFirst().reduce(shapes[0]) { $0.union($1) }
    return [Layer(path: merged, evenOdd: false, rgb: layers[0].rgb, alpha: layers[0].alpha)]
}

// MARK: - Font-glyph fallback (monochrome, medium scale)

/// Some symbols rasterize in every mode (overlapping layers that erase each other: lightbulb.2,
/// sun.haze, align.vertical.center…), so no vector outlines exist to rebuild them from. SF Pro carries
/// every symbol as a finished monochrome glyph in Unicode plane 16 (U+100000+); `search --json`
/// gives the exact codepoint. Its outline matches the renderer's medium scale to ~0.3 pt at 100 pt.
func fontGlyph(_ cfg: Config, _ name: String, truth: CGImage, tmp: URL) -> (layers: [Layer]?, why: String) {
    guard cfg.mode == "monochrome" else { return (nil, "no vector donor mode matched") }
    guard cfg.scale == "medium" else { return (nil, "no vector donor mode, and the SF Pro glyph fallback needs --scale medium") }
    guard let cp = codepoint(cfg, name, truth: truth, tmp: tmp), let scalar = Unicode.Scalar(cp) else {
        return (nil, "no vector donor mode, and the symbol has no SF Pro codepoint (typical for symbols new this year)")
    }
    let ps = "SFPro-" + cfg.weight.capitalized                       // SFPro-Regular, SFPro-Semibold…
    let font = CTFontCreateWithName(ps as CFString, 100, nil)
    guard CTFontCopyPostScriptName(font) as String == ps else { return (nil, "no vector donor mode, and font \(ps) is not installed") }
    var chars = Array(String(scalar).utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count), glyphs[0] != 0,
          let glyph = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
        return (nil, "no vector donor mode, and the installed SF Pro lacks U+\(String(cp, radix: 16, uppercase: true))")
    }
    var flip = CGAffineTransform(scaleX: 1, y: -1)                   // font space is y-up
    return ([Layer(path: glyph.copy(using: &flip)!, evenOdd: false, rgb: [0], alpha: 1)], "")
}

func searchJSON(_ cfg: Config, _ args: [String]) -> [(name: String, codepoint: UInt32?)] {
    guard let json = cli(cfg, ["search", "--json"] + args).out,
          let rows = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
    return rows.compactMap { r in
        (r["name"] as? String).map { ($0, (r["codepoint"] as? String).flatMap { UInt32($0.dropFirst(2), radix: 16) }) }
    }
}

/// `exactName` only knows current names, but `export` also takes old ones (doc.on.doc, renamed
/// document.on.document in iOS 18). A permissive search ranks the current name first via its alias
/// list; accept a candidate only if its PNG is pixel-identical to the requested name's.
func codepoint(_ cfg: Config, _ name: String, truth: CGImage, tmp: URL) -> UInt32? {
    if let hit = searchJSON(cfg, ["--match-style", "exactName", name]).first { return hit.codepoint }
    for (i, cand) in searchJSON(cfg, ["--limit", "5", name]).enumerated() {
        guard let cp = cand.codepoint else { continue }
        let png = tmp.appendingPathComponent("\(name).alias\(i).png")
        guard runCLI(cfg, exportArgs(cfg, cand.name, mode: cfg.mode) + ["--format", "png", "--output", png.path,
                                                                       "--image-scale", fmt(checkScale)]) == nil,
              let img = loadPNG(png), img.width == truth.width, img.height == truth.height,
              alphaIoU(img, truth) > 0.9999 else { continue }
        return cp
    }
    return nil
}

/// Alpha-weighted centre of an image, in points; places the font glyph on the PNG to sub-pixel accuracy.
func centroid(_ img: CGImage) -> CGPoint {
    let a = alphaChannel(img)
    var sx = 0.0, sy = 0.0, sum = 0.0
    for y in 0..<img.height { for x in 0..<img.width {
        let v = Double(a[y * img.width + x]); sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5); sum += v
    } }
    return CGPoint(x: sx / max(sum, 1) / checkScale, y: sy / max(sum, 1) / checkScale)
}

// MARK: - SVG writing

func fmt(_ v: CGFloat) -> String {
    var s = String(format: "%.3f", Double(v))
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

func svgPathData(_ p: CGPath) -> String {
    var d: [String] = []
    p.applyWithBlock { el in
        let e = el.pointee, pt = e.points
        switch e.type {
        case .moveToPoint: d.append("M\(fmt(pt[0].x)) \(fmt(pt[0].y))")
        case .addLineToPoint: d.append("L\(fmt(pt[0].x)) \(fmt(pt[0].y))")
        case .addQuadCurveToPoint: d.append("Q\(fmt(pt[0].x)) \(fmt(pt[0].y)) \(fmt(pt[1].x)) \(fmt(pt[1].y))")
        case .addCurveToPoint:
            d.append("C\(fmt(pt[0].x)) \(fmt(pt[0].y)) \(fmt(pt[1].x)) \(fmt(pt[1].y)) \(fmt(pt[2].x)) \(fmt(pt[2].y))")
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined()
}

func fillAttr(_ rgb: [CGFloat]) -> String {
    let c = rgb.count == 1 ? [rgb[0], rgb[0], rgb[0]] : rgb
    if c.allSatisfy({ $0 < 0.002 }) { return "currentColor" }   // the tint layers (exported as black)
    return "#" + c.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
}

/// Layers are translated so the ink's bounding box starts at 0,0; viewBox = that box, in points at 100 pt.
func svgDocument(_ cfg: Config, name: String, layers: [Layer], ink: CGRect) -> String {
    var move = CGAffineTransform(translationX: -ink.minX, y: -ink.minY)
    let w = fmt(ink.width), h = fmt(ink.height)
    var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(w) \(h)\" width=\"\(w)\" height=\"\(h)\""
    out += " data-sfsymbol=\"\(name)\" data-weight=\"\(cfg.weight)\" data-scale=\"\(cfg.scale)\" data-mode=\"\(cfg.mode)\">\n"
    for l in layers {
        var attrs = "fill=\"\(fillAttr(l.rgb))\""
        if l.evenOdd { attrs += " fill-rule=\"evenodd\"" }
        if l.alpha < 0.999 { attrs += " fill-opacity=\"\(fmt(l.alpha))\"" }
        out += "<path d=\"\(svgPathData(l.path.copy(using: &move)!))\" \(attrs)/>\n"
    }
    return out + "</svg>\n"
}

// MARK: - Verification (reads the SVG back, so serialization is checked too)

/// Parser for the SVGs this script writes: absolute M/L/Q/C/Z only.
func parsePathData(_ d: String) -> CGPath {
    let p = CGMutablePath()
    let scalars = Array(d.unicodeScalars)
    var i = 0
    func number() -> CGFloat {
        while i < scalars.count, scalars[i] == " " || scalars[i] == "," { i += 1 }
        let start = i
        while i < scalars.count, "0123456789.-e".unicodeScalars.contains(scalars[i]) { i += 1 }
        return CGFloat(Double(String(String.UnicodeScalarView(scalars[start..<i]))) ?? 0)
    }
    func pt() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
    while i < scalars.count {
        let c = scalars[i]; i += 1
        switch c {
        case "M": p.move(to: pt())
        case "L": p.addLine(to: pt())
        case "Q": let c1 = pt(); p.addQuadCurve(to: pt(), control: c1)
        case "C": let c1 = pt(), c2 = pt(); p.addCurve(to: pt(), control1: c1, control2: c2)
        case "Z": p.closeSubpath()
        default: break
        }
    }
    return p
}

func readSVG(_ url: URL) -> [Layer] {
    guard let doc = try? XMLDocument(contentsOf: url),
          let paths = try? doc.nodes(forXPath: "//*[local-name()='path']") as? [XMLElement] else { return [] }
    return paths.map { el in
        let fill = el.attribute(forName: "fill")?.stringValue ?? "currentColor"
        var rgb: [CGFloat] = [0]
        if fill.hasPrefix("#"), let v = Int(fill.dropFirst(), radix: 16) {
            rgb = [CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255]
        }
        return Layer(path: parsePathData(el.attribute(forName: "d")?.stringValue ?? ""),
                     evenOdd: el.attribute(forName: "fill-rule")?.stringValue == "evenodd",
                     rgb: rgb,
                     alpha: CGFloat(Double(el.attribute(forName: "fill-opacity")?.stringValue ?? "1") ?? 1))
    }
}

func rgbaContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Draws SVG-space layers (offset back by the ink origin) onto a canvas the size of the PNG.
func renderLayers(_ layers: [Layer], inkOrigin: CGPoint, pixelSize: (Int, Int)) -> CGImage {
    let c = rgbaContext(pixelSize.0, pixelSize.1)
    c.translateBy(x: 0, y: CGFloat(pixelSize.1))
    c.scaleBy(x: checkScale, y: -checkScale)           // y down, points → pixels
    c.translateBy(x: inkOrigin.x, y: inkOrigin.y)
    for l in layers {
        let rgb = l.rgb.count == 1 ? [l.rgb[0], l.rgb[0], l.rgb[0]] : l.rgb
        c.setFillColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: l.alpha)
        c.addPath(l.path)
        c.fillPath(using: l.evenOdd ? .evenOdd : .winding)
    }
    return c.makeImage()!
}

/// Alpha bytes, row 0 = top.
func alphaChannel(_ img: CGImage) -> [UInt8] {
    let c = rgbaContext(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.bindMemory(to: UInt8.self, capacity: img.width * img.height * 4)
    return stride(from: 3, to: img.width * img.height * 4, by: 4).map { p[$0] }
}

func alphaIoU(_ a: CGImage, _ b: CGImage) -> Double {
    var inter = 0.0, union = 0.0
    for (x, y) in zip(alphaChannel(a), alphaChannel(b)) { inter += Double(min(x, y)); union += Double(max(x, y)) }
    return inter / max(union, 1)
}

func loadPNG(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - One symbol

func exportSymbol(_ cfg: Config, _ name: String, tmp: URL) -> Result {
    let pdf = tmp.appendingPathComponent("\(name).pdf"), png = tmp.appendingPathComponent("\(name).png")
    // Two calls: with --image-scale the CLI doubles the PDF's page box but not its content.
    if let err = runCLI(cfg, exportArgs(cfg, name, mode: cfg.mode) + ["--format", "pdf", "--output", pdf.path])
        ?? runCLI(cfg, exportArgs(cfg, name, mode: cfg.mode) + ["--format", "png", "--output", png.path,
                                                               "--image-scale", fmt(checkScale)]) {
        return Result(line: "FAIL \(name): \(err)", ok: false)
    }
    guard let (w, box) = walk(pdf: pdf) else { return Result(line: "FAIL \(name): unreadable PDF", ok: false) }
    guard let truth = loadPNG(png) else { return Result(line: "FAIL \(name): no PNG to check against", ok: false) }
    var layers = w.layers, note = ""
    if w.raster {
        if let (l, donorBox, donor) = knockout(cfg, name, tmp: tmp) {
            guard donorBox.size == box.size else { return Result(line: "FAIL \(name): donor page size differs", ok: false) }
            layers = l
            note = " knockout←\(donor)"
        } else {
            let glyph: (layers: [Layer]?, why: String) = ["monochrome", "hierarchical"].contains(cfg.mode)
                ? fontGlyph(cfg, name, truth: truth, tmp: tmp)
                : (nil, "\(cfg.mode) has no fallback; export it as monochrome or hierarchical and recolor by hand")
            guard let l = glyph.layers else {
                return Result(line: "FAIL \(name): the CLI rasterized this \(cfg.mode) export (a layer erases the ones below); \(glyph.why)", ok: false)
            }
            layers = l
            note = " font-glyph"
        }
    }
    guard !layers.isEmpty else { return Result(line: "FAIL \(name): no filled layers found", ok: false) }
    if cfg.mode == "monochrome" { layers = mergedMonochrome(layers) }
    let ink = layers.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    let out = cfg.outDir.appendingPathComponent("\(name).svg")
    do { try svgDocument(cfg, name: name, layers: layers, ink: ink).write(to: out, atomically: true, encoding: .utf8) }
    catch { return Result(line: "FAIL \(name): \(error)", ok: false) }

    let svgLayers = readSVG(out), size = (truth.width, truth.height)
    var origin = ink.origin
    if note == " font-glyph" {
        // The glyph has no page position of its own: line its centre up with the PNG's.
        let a = centroid(truth), b = centroid(renderLayers(svgLayers, inkOrigin: .zero, pixelSize: size))
        origin = CGPoint(x: a.x - b.x, y: a.y - b.y)
    }
    let render = renderLayers(svgLayers, inkOrigin: origin, pixelSize: size)
    var iou = alphaIoU(truth, render)
    if cfg.mode == "monochrome" {
        // Consumers often hard-code fill-rule="evenodd" (Cineo's kit.js does); the path must hold up under both rules.
        let evenOdd = svgLayers.map { var l = $0; l.evenOdd = true; return l }
        iou = min(iou, alphaIoU(truth, renderLayers(evenOdd, inkOrigin: origin, pixelSize: size)))
    }
    var line = String(format: "%@ %@ %@x%@ layers=%d iou=%.4f%@", iou >= iouWarn ? "OK" : "CHECK", name,
                      fmt(ink.width), fmt(ink.height), layers.count, iou, note)
    // The CLI's page box is not the ink box; ink past it means its PNG/PDF clip the symbol.
    if !CGRect(origin: .zero, size: box.size).insetBy(dx: -0.5, dy: -0.5).contains(CGRect(origin: origin, size: ink.size)) {
        line += " (ink exceeds CLI page box)"
    }
    if !w.warnings.isEmpty { line += "  WARN " + w.warnings.sorted().joined(separator: "; ") }
    return Result(line: line, ok: iou >= iouWarn, png: truth, svgRender: render)
}

// MARK: - Contact sheet

func writeSheet(_ names: [String], _ results: [Result], to url: URL) {
    let cell = 72, labelW = 470, rowH = cell + 8
    let width = labelW + (cell + 16) * 2, height = rowH * names.count + 8
    let c = rgbaContext(width, height)
    c.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    c.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (row, (name, r)) in zip(names, results).enumerated() {
        let y = CGFloat(height - (row + 1) * rowH)
        let label = (name.count > 50 ? name.prefix(49) + "…" : name) + "  " + (r.line.split(separator: " ").first { $0.hasPrefix("iou=") }.map(String.init) ?? "FAIL")
        drawText(label, in: c, at: CGPoint(x: 8, y: y + CGFloat(cell) / 2 - 6), red: !r.ok)
        for (col, img) in [r.png, r.svgRender].enumerated() {
            guard let img else { continue }
            let s = min(CGFloat(cell) / CGFloat(img.width), CGFloat(cell) / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            let x = CGFloat(labelW + col * (cell + 16))
            c.setStrokeColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
            c.stroke(CGRect(x: x - 1, y: y - 1, width: CGFloat(cell) + 2, height: CGFloat(cell) + 2))
            c.draw(img, in: CGRect(x: x + (CGFloat(cell) - w) / 2, y: y + (CGFloat(cell) - h) / 2, width: w, height: h))
        }
    }
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dst, c.makeImage()!, nil)
    CGImageDestinationFinalize(dst)
}

func drawText(_ s: String, in c: CGContext, at p: CGPoint, red: Bool) {
    let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
    let color = red ? CGColor(red: 0.8, green: 0, blue: 0, alpha: 1) : CGColor(gray: 0, alpha: 1)
    let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                          kCTForegroundColorAttributeName as NSAttributedString.Key: color])
    c.textPosition = p
    CTLineDraw(CTLineCreateWithAttributedString(attr), c)
}

// MARK: - Main

var cfg = Config()
var positional: [String] = []
var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    switch a {
    case "--weight": cfg.weight = argv.popFirst() ?? cfg.weight
    case "--scale": cfg.scale = argv.popFirst() ?? cfg.scale
    case "--mode": cfg.mode = argv.popFirst() ?? cfg.mode
    default: positional.append(a)
    }
}
guard positional.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift export.swift [--weight W] [--scale S] [--mode M] <outDir> <name>...\n".utf8))
    exit(64)
}
cfg.outDir = URL(fileURLWithPath: positional[0], isDirectory: true)
let names = Array(positional.dropFirst())
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sfsymbol-export-\(getpid())", isDirectory: true)
try FileManager.default.createDirectory(at: cfg.outDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// Each CLI call is ~1 s of mostly single-core work, so fan out.
let frozen = cfg
nonisolated(unsafe) var results = [Result](repeating: Result(line: "", ok: false), count: names.count)
let lock = NSLock()
DispatchQueue.concurrentPerform(iterations: names.count) { i in
    let r = exportSymbol(frozen, names[i], tmp: tmp)
    lock.withLock { results[i] = r }
}
for r in results { print(r.line) }
let sheet = cfg.outDir.appendingPathComponent("_sheet.png")
writeSheet(names, results, to: sheet)
print("sheet: \(sheet.path)")
exit(results.allSatisfy(\.ok) ? 0 : 1)
