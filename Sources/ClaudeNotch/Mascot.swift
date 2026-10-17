import AppKit
import SwiftUI

// MARK: - Palette

enum Palette {
    static let claudeNS = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
    static let claudeLightNS = NSColor(srgbRed: 238 / 255, green: 156 / 255, blue: 126 / 255, alpha: 1)
    static let claudeShadeNS = NSColor(srgbRed: 176 / 255, green: 84 / 255, blue: 57 / 255, alpha: 1)
    static let inkNS = NSColor(srgbRed: 28 / 255, green: 22 / 255, blue: 20 / 255, alpha: 1)
    static let amberNS = NSColor(srgbRed: 1, green: 176 / 255, blue: 32 / 255, alpha: 1)
    static let greenNS = NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)
    static let goldNS = NSColor(srgbRed: 246 / 255, green: 198 / 255, blue: 122 / 255, alpha: 1)

    static let claude = Color(nsColor: claudeNS)
    static let amber = Color(nsColor: amberNS)
    static let green = Color(nsColor: greenNS)
}

// MARK: - Sprite

/// A 12×8 pixel critter. Eyes, arms and legs are layered onto the body per frame.
enum Sprite {
    static let columns = 12
    static let rows = 8

    enum Eyes: Equatable { case open, blink, closed, happy, left, right }
    enum Arms: Equatable { case down, up, leftUp, rightUp }
    enum Legs: Equatable { case planted, stepA, stepB }

    // h highlight · o body · d shade · e eye
    private static let body: [[Character]] = [
        "..hooooooo..",
        ".hooooooooo.",
        ".oooooooooo.",
        ".oooooooooo.",
        ".oooooooooo.",
        ".dddddddddd.",
        "............",
        "............",
    ].map { Array($0) }

    static func pixels(eyes: Eyes, arms: Arms, legs: Legs) -> [[Character]] {
        var grid = body

        let (left, right): ([Int], [Int])
        switch arms {
        case .down: (left, right) = ([3, 4], [3, 4])
        case .up: (left, right) = ([0, 1], [0, 1])
        case .leftUp: (left, right) = ([0, 1], [3, 4])
        case .rightUp: (left, right) = ([3, 4], [0, 1])
        }
        left.forEach { grid[$0][0] = "o" }
        right.forEach { grid[$0][columns - 1] = "o" }

        let eyePixels: [(Int, Int)]
        switch eyes {
        case .open: eyePixels = [(2, 3), (3, 3), (2, 8), (3, 8)]
        case .blink: eyePixels = [(3, 3), (3, 8)]
        case .closed: eyePixels = [(3, 2), (3, 3), (3, 8), (3, 9)]
        case .happy: eyePixels = [(2, 2), (2, 3), (2, 4), (3, 2), (3, 4), (2, 7), (2, 8), (2, 9), (3, 7), (3, 9)]
        case .left: eyePixels = [(2, 2), (3, 2), (2, 7), (3, 7)]
        case .right: eyePixels = [(2, 4), (3, 4), (2, 9), (3, 9)]
        }
        eyePixels.forEach { grid[$0.0][$0.1] = "e" }

        for (i, column) in [2, 4, 7, 9].enumerated() {
            grid[6][column] = "d"
            let lifted = (legs == .stepA && i % 2 == 0) || (legs == .stepB && i % 2 == 1)
            if !lifted { grid[7][column] = "d" }
        }
        return grid
    }
}

// MARK: - Frame

struct Particle: Equatable {
    enum Kind: Equatable { case spark, confetti(Int), zee }
    var kind: Kind
    var x: CGFloat   // sprite px from the ground point
    var y: CGFloat   // sprite px from the ground point; negative is up
    var vx: CGFloat
    var vy: CGFloat
    var life: Int
    var span: Int

    var fade: CGFloat { CGFloat(life) / CGFloat(max(span, 1)) }
}

/// Everything the painter needs for one tick. Offsets are in sprite pixels so the
/// same frame renders crisply at any pixel size.
struct MascotFrame: Equatable {
    enum Glow: Equatable { case none, amber, green }

    var eyes = Sprite.Eyes.open
    var arms = Sprite.Arms.down
    var legs = Sprite.Legs.planted
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    /// Positive squashes (wider, shorter); negative stretches.
    var squash: CGFloat = 0
    var bang = false
    var glow = Glow.none
    var particles: [Particle] = []
    var tick = 0
}

// MARK: - Engine

/// Small behaviour engine: a mood picks the loop (sleep, idle, work, alert), and
/// one-shot moves (hop, cheer, blink) layer on top. Ticks at 12 fps (6 asleep), but
/// motion snaps to the pixel grid and listeners only hear about frames that changed,
/// so most ticks cost nothing.
@MainActor
final class MascotEngine {
    enum Mood: Equatable { case sleeping, idle, waiting, working, alert }

    private(set) var frame = MascotFrame()
    private(set) var mood: Mood = .sleeping
    var reduceMotion = false
    /// How far (sprite px) the mascot may wander from the middle of its ear.
    var roam: CGFloat = 2

    private var listeners: [ObjectIdentifier: (MascotFrame) -> Void] = [:]
    private var timer: Timer?
    private var fps: Double = 12
    private var t = 0
    private var x: CGFloat = 0
    private var particles: [Particle] = []

    private var nextBlink = 30
    private var blinkUntil = 0
    private var nextBeat = 40
    private var lookUntil = 0
    private var look = Sprite.Eyes.open
    private var walkTarget: CGFloat?
    private var hopStart: Int?
    private var hopHeight: CGFloat = 3
    private var hopAir = 6
    private var cheerStart: Int?

    func subscribe(_ owner: AnyObject, _ handler: @escaping (MascotFrame) -> Void) {
        listeners[ObjectIdentifier(owner)] = handler
        handler(frame)
    }

    func unsubscribe(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
    }

    func start() { run(at: fps) }
    func pause() { timer?.invalidate(); timer = nil }
    func resume() { if timer == nil { run(at: fps) } }

    func setMood(_ new: Mood) {
        guard new != mood else { return }
        mood = new
        walkTarget = nil
        if new == .alert { hop(3, air: 5) }
        let rate: Double = new == .sleeping ? 6 : 12
        if rate != fps {
            fps = rate
            if timer != nil { run(at: rate) }
        }
    }

    func celebrate() {
        hopStart = nil
        cheerStart = t
    }

    /// Freeze one exact pose (snapshots).
    func pose(_ frame: MascotFrame) {
        pause()
        self.frame = frame
    }

    private func run(at rate: Double) {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func ticks(_ seconds: Double) -> Int { max(1, Int(seconds * fps)) }
    private func ticks(in range: ClosedRange<Double>) -> Int { ticks(Double.random(in: range)) }
    private func wave(period: Double) -> CGFloat { CGFloat(sin(Double(t) / fps * 2 * .pi / period)) }

    private func hop(_ height: CGFloat, air: Int = 6) {
        guard !reduceMotion, hopStart == nil, cheerStart == nil else { return }
        hopStart = t
        hopHeight = height
        hopAir = air
    }

    private func emit(_ kind: Particle.Kind, x dx: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, life: Int) {
        guard !reduceMotion else { return }
        particles.append(Particle(kind: kind, x: x + dx, y: y, vx: vx, vy: vy, life: life, span: life))
    }

    private func step() {
        t += 1
        var f = MascotFrame()

        switch mood {
        case .sleeping: sleep(&f)
        case .idle: idle(&f, restless: false)
        case .waiting: idle(&f, restless: true)
        case .working: work(&f)
        case .alert: alert(&f)
        }
        applyHop(&f)
        applyCheer(&f)
        applyBlink(&f)

        particles = particles.compactMap { particle in
            var p = particle
            p.x += p.vx
            p.y += p.vy
            p.life -= 1
            if case .confetti = p.kind { p.vy += 0.06 }
            return p.life > 0 ? p : nil
        }
        if reduceMotion { x = 0 }

        // Snap to the half-pixel grid and quarter-step fades: it reads as pixel art,
        // and consecutive ticks often land on the same frame, which then isn't redrawn.
        f.dx = snap(x)
        f.dy = reduceMotion ? 0 : snap(f.dy)
        f.squash = reduceMotion ? 0 : (f.squash * 50).rounded() / 50
        f.particles = particles.map { p in
            var q = p
            q.x = snap(p.x)
            q.y = snap(p.y)
            q.life = Int((p.fade * 4).rounded(.up))
            q.span = 4
            return q
        }

        // Only the frame number differs? Nothing to draw.
        f.tick = frame.tick
        let changed = f != frame
        f.tick = t
        frame = f
        if changed { listeners.values.forEach { $0(f) } }
    }

    private func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    // MARK: Loops

    private func sleep(_ f: inout MascotFrame) {
        f.eyes = .closed
        f.squash = 0.08 + 0.05 * wave(period: 3.2)
        x = approach(x, 0, by: 0.1)
        if t % ticks(1.8) == 0 { emit(.zee, x: 4, y: -9, vx: 0.16, vy: -0.2, life: ticks(2.4)) }
    }

    private func idle(_ f: inout MascotFrame, restless: Bool) {
        f.squash = 0.035 * wave(period: 2.6)
        if t >= nextBeat {
            nextBeat = t + (restless ? ticks(in: 1.5...3) : ticks(in: 3...8))
            switch Int.random(in: 0..<10) {
            case 0..<4: walkTarget = CGFloat(Int.random(in: -Int(roam)...Int(roam)))
            case 4..<6 where !restless: hop(3)
            case 6..<9:
                look = Bool.random() ? .left : .right
                lookUntil = t + ticks(in: 0.8...1.6)
            default: nextBlink = t
            }
        }
        walk(&f, speed: 0.25, stepEvery: 3)
        if restless, walkTarget == nil { f.legs = (t / ticks(0.4)) % 2 == 0 ? .planted : .stepA }
        if t < lookUntil, f.eyes == .open { f.eyes = look }
    }

    private func work(_ f: inout MascotFrame) {
        // Scurry back and forth across the ear, kicking up Claude's thinking sparks.
        if walkTarget == nil { walkTarget = x <= 0 ? roam : -roam }
        walk(&f, speed: 0.34, stepEvery: 2)
        f.dy = (t / 2) % 2 == 0 ? 0 : -0.5
        if t % ticks(0.7) == 0 {
            emit(.spark, x: CGFloat.random(in: -4...4), y: -10, vx: 0, vy: -0.22, life: ticks(0.9))
        }
        if t >= nextBeat {
            nextBeat = t + ticks(in: 4...7)
            hop(2, air: 5)
        }
    }

    private func alert(_ f: inout MascotFrame) {
        x = approach(x, 0, by: 0.5)
        f.arms = (t / 3) % 2 == 0 ? .leftUp : .rightUp
        f.bang = t % 8 < 5
        f.glow = .amber
        if t % ticks(1.2) == 0 { hop(3, air: 5) }
    }

    private func walk(_ f: inout MascotFrame, speed: CGFloat, stepEvery: Int) {
        guard let target = walkTarget else { return }
        if abs(target - x) <= speed {
            x = target
            walkTarget = nil
            return
        }
        x += target > x ? speed : -speed
        f.legs = (t / stepEvery) % 2 == 0 ? .stepA : .stepB
        f.eyes = target > x ? .right : .left
    }

    // MARK: One-shots

    private func applyHop(_ f: inout MascotFrame) {
        guard let start = hopStart else { return }
        let k = t - start
        switch k {
        case 0..<2:
            f.squash = 0.18
        case 2..<(2 + hopAir):
            let p = CGFloat(k - 1) / CGFloat(hopAir + 1)
            f.dy = -hopHeight * 4 * p * (1 - p)
            f.squash = p < 0.5 ? -0.12 : -0.04
        case (2 + hopAir)..<(4 + hopAir):
            f.squash = 0.15
        default:
            hopStart = nil
        }
    }

    private func applyCheer(_ f: inout MascotFrame) {
        guard let start = cheerStart else { return }
        let k = t - start
        let air = 8
        f.eyes = .happy
        f.glow = .green
        switch k {
        case 0..<2:
            f.squash = 0.22
        case 2..<(2 + air):
            let p = CGFloat(k - 1) / CGFloat(air + 1)
            f.dy = -6 * 4 * p * (1 - p)
            f.squash = p < 0.5 ? -0.16 : -0.05
            f.arms = .up
        case 2 + air:
            f.squash = 0.22
            f.arms = .up
            burst()
        case (3 + air)..<(5 + air):
            f.squash = 0.1
            f.arms = .up
        case (5 + air)..<(5 + air + ticks(1.4)):
            f.arms = (t / 3) % 2 == 0 ? .leftUp : .rightUp
            f.dy = (k / 3) % 2 == 0 ? -1 : 0
        default:
            cheerStart = nil
        }
    }

    private func applyBlink(_ f: inout MascotFrame) {
        if t >= nextBlink {
            blinkUntil = t + 2
            nextBlink = t + (Int.random(in: 0..<5) == 0 ? 4 : ticks(in: 2.5...6))
        }
        if t < blinkUntil, [.open, .left, .right].contains(f.eyes) { f.eyes = .blink }
    }

    private func burst() {
        for i in 0..<7 {
            let angle = CGFloat.pi * (0.1 + 0.8 * CGFloat(i) / 6)
            emit(.confetti(i % 3), x: 0, y: -6, vx: cos(angle) * 0.55, vy: -sin(angle) * 0.75 - 0.15, life: ticks(1.0))
        }
    }

    private func approach(_ value: CGFloat, _ target: CGFloat, by step: CGFloat) -> CGFloat {
        abs(target - value) <= step ? target : value + (target > value ? step : -step)
    }
}

// MARK: - Painter

/// Plain Core Graphics, so the same code draws the live layer and the PNG snapshots.
/// Expects a y-down context (flipped NSView, or SwiftUI's Canvas).
enum MascotPainter {
    static func draw(_ f: MascotFrame, pixel p: CGFloat, ground: CGPoint, in cg: CGContext) {
        let grid = Sprite.pixels(eyes: f.eyes, arms: f.arms, legs: f.legs)
        let cellW = p * (1 + f.squash * 0.6)
        let cellH = p * (1 - f.squash)
        let width = CGFloat(Sprite.columns) * cellW
        let height = CGFloat(Sprite.rows) * cellH
        let originX = ground.x + f.dx * p - width / 2
        let originY = ground.y + f.dy * p - height

        if f.glow != .none {
            let color = f.glow == .amber ? Palette.amberNS : Palette.greenNS
            let center = CGPoint(x: originX + width / 2, y: originY + height * 0.5)
            let radius = p * 9
            let colors = [color.withAlphaComponent(0.3).cgColor, color.withAlphaComponent(0.1).cgColor,
                          color.withAlphaComponent(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1]) {
                // Squash the context instead of clipping to an ellipse, so the glow fades out
                // on every side rather than ending on a hard rim.
                cg.saveGState()
                cg.translateBy(x: center.x, y: center.y)
                cg.scaleBy(x: 1, y: 0.75)
                cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
                cg.restoreGState()
            }
        }

        // Fill the whole silhouette as one path, then lay the detail colors on top.
        // Filling cells one by one leaves antialiased seams once the sprite squashes.
        func cells(_ match: (Character) -> Bool) {
            cg.beginPath()
            for (r, row) in grid.enumerated() {
                for (c, cell) in row.enumerated() where match(cell) {
                    cg.addRect(CGRect(x: originX + CGFloat(c) * cellW, y: originY + CGFloat(r) * cellH,
                                      width: cellW, height: cellH))
                }
            }
        }
        cells { $0 != "." }
        cg.setFillColor(Palette.claudeNS.cgColor)
        cg.fillPath()
        for (mark, color) in [("h", Palette.claudeLightNS), ("d", Palette.claudeShadeNS), ("e", Palette.inkNS)] {
            cells { $0 == Character(mark) }
            cg.setFillColor(color.cgColor)
            cg.fillPath()
        }

        if f.bang {
            let bx = originX + width / 2 + p * 2
            let by = originY - p * 5
            cg.setFillColor(Palette.amberNS.cgColor)
            cg.fill(CGRect(x: bx, y: by, width: p, height: p * 2))
            cg.fill(CGRect(x: bx, y: by + p * 3, width: p, height: p))
        }

        for particle in f.particles {
            let at = CGPoint(x: ground.x + particle.x * p, y: ground.y + particle.y * p)
            switch particle.kind {
            case .spark:
                plus(at: at, unit: p * 0.5, color: Palette.goldNS.withAlphaComponent(particle.fade), in: cg)
            case .confetti(let i):
                let colors = [Palette.greenNS, Palette.goldNS, Palette.claudeLightNS]
                plus(at: at, unit: p * 0.6, color: colors[i % colors.count].withAlphaComponent(particle.fade), in: cg)
            case .zee:
                text("z", at: at, font: .monospacedSystemFont(ofSize: p * 4, weight: .bold),
                     color: NSColor.white.withAlphaComponent(0.7 * particle.fade), in: cg)
            }
        }
    }

    private static func plus(at c: CGPoint, unit u: CGFloat, color: NSColor, in cg: CGContext) {
        cg.setFillColor(color.cgColor)
        cg.fill(CGRect(x: c.x - u / 2, y: c.y - u * 1.5, width: u, height: u * 3))
        cg.fill(CGRect(x: c.x - u * 1.5, y: c.y - u / 2, width: u * 3, height: u))
    }

    /// Draws text centered on `at` in a y-down context.
    static func text(_ string: String, at: CGPoint, font: NSFont, color: NSColor, in cg: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: CGPoint(x: at.x - size.width / 2, y: at.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}
