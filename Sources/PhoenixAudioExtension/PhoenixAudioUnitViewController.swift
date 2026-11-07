import AudioToolbox
import CoreAudioKit
import Foundation
import SovereignCore
import SwiftUI

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

/// Principal class for the macOS & iOS Audio Unit v3 (`AUv3` — `com.apple.AudioUnit-UI`) plugin extension.
/// Conforms to `AUAudioUnitFactory` and hosts the 60 fps `PhoenixMarineSenseAUView` (4096-Bucket 384 kHz
/// Time-Domain Spectrogram + `VOCALS ONLY EMOTION` & `FULL MUSIC EMOTION` Wheels).
@MainActor
public final class PhoenixAudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var phoenixUnit: PhoenixAudioUnit?

    public override func loadView() {
        #if os(macOS)
            let root = NSHostingView(rootView: PhoenixMarineSenseAUView(unitProvider: { [weak self] in self?.phoenixUnit }))
            root.frame = NSRect(x: 0, y: 0, width: 920, height: 540)
            self.view = root
        #elseif os(iOS)
            let host = UIHostingController(
                rootView: PhoenixMarineSenseAUView(unitProvider: { [weak self] in self?.phoenixUnit })
            )
            self.addChild(host)
            self.view = host.view
            host.didMove(toParent: self)
        #endif
    }

    nonisolated public func createAudioUnit(with desc: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try PhoenixAudioUnit(componentDescription: desc)
        Task { @MainActor in
            self.phoenixUnit = unit
        }
        return unit
    }
}

/// 60 fps SwiftUI view for the PhoeniX Svara & Marine-Sense AUv3 Audio Filter (macOS & iOS).
public struct PhoenixMarineSenseAUView: View {
    let unitProvider: () -> PhoenixAudioUnit?

    @State private var selectedPreset: RustPhoenixSound.Preset = .alexandraSanctuary
    @State private var autoMagical: Bool = true
    @State private var alexandraReset: Bool = false
    @State private var feelVoice: Double = 100
    @State private var feelBass: Double = 100
    @State private var feelSpace: Double = 100
    @State private var showStudioTrim: Bool = false
    @State private var naadSub: Double = 280
    @State private var svaraVocal: Double = 280
    @State private var warmth: Double = 360
    @State private var goonjVelvet: Double = 380
    @State private var babbageAir: Double = 240

    public init(unitProvider: @escaping () -> PhoenixAudioUnit?) {
        self.unitProvider = unitProvider
    }

    public var body: some View {
        VStack(spacing: 8) {
            headerBar
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                PhoenixMarineCanvasView(
                    date: context.date,
                    snapshot: unitProvider()?.snapshotTelemetry()
                        ?? RustPhoenixSound.TelemetrySnapshot(
                            marineBuckets64: [UInt16](repeating: 0, count: 64),
                            marineVocal64: [UInt16](repeating: 0, count: 64),
                            dominantHz: 432,
                            soulQ10: 980
                        )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            parameterStrip
        }
        .padding(12)
        .background(Color(red: 0.02, green: 0.03, blue: 0.05))
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image("PhoenixEmblem", bundle: Bundle(for: PhoenixAudioUnitViewController.self))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .cornerRadius(6)

            Text("PhoeniX Audio Restore × Marine-Sense")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.38, green: 0.90, blue: 0.79))

            Text("384 kHz · 4096-Bucket · Zero-FFT")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(red: 0.09, green: 0.16, blue: 0.16))
                .foregroundColor(Color(red: 0.38, green: 0.90, blue: 0.79))
                .cornerRadius(99)

            Spacer()

            Button(action: {
                alexandraReset.toggle()
                if alexandraReset {
                    selectedPreset = .alexandraSanctuary
                }
                unitProvider()?.setAlexandraReset(alexandraReset)
            }) {
                Text(alexandraReset ? "💖 Alexandra Reset: SOOTHING [ON]" : "💖 Alexandra Reset")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(alexandraReset ? Color(red: 0.08, green: 0.24, blue: 0.20) : Color(red: 0.16, green: 0.08, blue: 0.18))
                    .foregroundColor(alexandraReset ? Color(red: 0.22, green: 0.95, blue: 0.76) : Color(red: 1.0, green: 0.57, blue: 0.82))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Button(action: {
                autoMagical.toggle()
                unitProvider()?.setFeelControls(
                    automagic: autoMagical,
                    voicePct: UInt16(feelVoice),
                    bassPct: UInt16(feelBass),
                    spacePct: UInt16(feelSpace)
                )
            }) {
                Text(autoMagical ? "✨ Auto-Magical: ON" : "✨ Auto-Magical: OFF")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(autoMagical ? Color(red: 0.08, green: 0.22, blue: 0.20) : Color(red: 0.10, green: 0.13, blue: 0.20))
                    .foregroundColor(autoMagical ? Color(red: 0.22, green: 0.95, blue: 0.76) : Color.gray)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Picker("Preset", selection: $selectedPreset) {
                ForEach(RustPhoenixSound.Preset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            .onChange(of: selectedPreset) { newValue in
                unitProvider()?.applyPreset(newValue)
            }
        }
    }

    private var parameterStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                feelMacroSlider(title: "🎤 Voice", value: $feelVoice) { pct in
                    unitProvider()?.setFeelControls(
                        automagic: autoMagical,
                        voicePct: UInt16(pct),
                        bassPct: UInt16(feelBass),
                        spacePct: UInt16(feelSpace)
                    )
                }
                feelMacroSlider(title: "🔊 Bass (<140Hz)", value: $feelBass) { pct in
                    unitProvider()?.setFeelControls(
                        automagic: autoMagical,
                        voicePct: UInt16(feelVoice),
                        bassPct: UInt16(pct),
                        spacePct: UInt16(feelSpace)
                    )
                }
                feelMacroSlider(title: "🌌 Space & 384kHz Air", value: $feelSpace) { pct in
                    unitProvider()?.setFeelControls(
                        automagic: autoMagical,
                        voicePct: UInt16(feelVoice),
                        bassPct: UInt16(feelBass),
                        spacePct: UInt16(pct)
                    )
                }
                Button("↺ Auto") {
                    autoMagical = true
                    feelVoice = 100
                    feelBass = 100
                    feelSpace = 100
                    unitProvider()?.setFeelControls(automagic: true, voicePct: 100, bassPct: 100, spacePct: 100)
                    unitProvider()?.applyPreset(selectedPreset)
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Button(showStudioTrim ? "Hide Pro" : "Pro Trim") {
                    showStudioTrim.toggle()
                }
                .font(.system(size: 10, weight: .regular, design: .monospaced))
            }
            if showStudioTrim {
                HStack(spacing: 16) {
                    paramKnob(title: "Naad Sub (<140Hz)", value: $naadSub, address: 1)
                    paramKnob(title: "Svara Vocal Emotion", value: $svaraVocal, address: 2)
                    paramKnob(title: "Triode Warmth", value: $warmth, address: 3)
                    paramKnob(title: "Goonj Velvet", value: $goonjVelvet, address: 4)
                    paramKnob(title: "384kHz Air", value: $babbageAir, address: 5)
                }
            }
        }
        .padding(.top, 4)
    }

    private func feelMacroSlider(title: String, value: Binding<Double>, onUpdate: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(Int(value.wrappedValue))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(red: 0.38, green: 0.90, blue: 0.79))
            Slider(value: value, in: 0...200, step: 5)
                .onChange(of: value.wrappedValue) { newVal in
                    onUpdate(newVal)
                }
        }
    }

    private func paramKnob(title: String, value: Binding<Double>, address: AUParameterAddress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(Int(value.wrappedValue))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.54, green: 0.70, blue: 0.78))
            Slider(value: value, in: 0...1024)
                .onChange(of: value.wrappedValue) { newVal in
                    unitProvider()?.parameterTree?.parameter(withAddress: address)?.value = AUValue(newVal)
                }
        }
    }
}

private struct PhoenixMarineCanvasView: View {
    let date: Date
    let snapshot: RustPhoenixSound.TelemetrySnapshot

    private static let vocalSectors = [
        "Joyful", "Intimate", "Tender", "Longing", "Velvet", "Raw Edge", "Belting", "Soaring",
    ]
    private static let musicSectors = [
        "Euphoria", "Warmth", "Sanctuary", "Mystery", "Sub-Bass", "Drive", "Passion", "384kHz Air",
    ]

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let dockW = min(260.0, max(180.0, w * 0.26))
            let specW = max(120.0, w - dockW - 24.0)
            let specRect = CGRect(x: 8, y: 8, width: specW, height: max(80.0, h - 24.0))

            ctx.fill(Path(specRect), with: .color(Color(red: 0.025, green: 0.035, blue: 0.065)))
            ctx.stroke(Path(specRect), with: .color(Color(red: 0.09, green: 0.13, blue: 0.20)), lineWidth: 1)

            // Render 64 -> 4096 Catmull-Rom expanded spectrum columns (20 Hz .. 384,000 Hz)
            let buckets = snapshot.marineBuckets64
            let vocals = snapshot.marineVocal64
            let cols = Int(specW)
            if cols > 1, buckets.count == 64 {
                for px in 0..<cols {
                    let pos64 = (Double(px) * 63.0) / Double(max(1, cols - 1))
                    let i = min(62, max(0, Int(pos64)))
                    let frac = pos64 - Double(i)
                    let bVal = Double(buckets[i]) * (1.0 - frac) + Double(buckets[i + 1]) * frac
                    let vVal = Double(vocals[i]) * (1.0 - frac) + Double(vocals[i + 1]) * frac

                    let normB = min(1.0, max(0.0, bVal / 1024.0))
                    let normV = min(1.0, max(0.0, vVal / 1024.0))
                    let colH = normB * Double(specRect.height - 4)
                    let vocH = normV * Double(specRect.height - 4)
                    let x = specRect.minX + CGFloat(px)

                    if colH > 1 {
                        let r = CGRect(x: x, y: specRect.maxY - CGFloat(colH), width: 1.5, height: CGFloat(colH))
                        ctx.fill(Path(r), with: .color(thermalOceanicColor(normB)))
                    }
                    if vocH > 1 {
                        let vr = CGRect(x: x, y: specRect.maxY - CGFloat(vocH), width: 1.5, height: CGFloat(vocH))
                        ctx.fill(Path(vr), with: .color(Color(red: 1.0, green: 0.42, blue: 0.83).opacity(0.85)))
                    }
                }
            }

            // Right Dock: Wheel 1 (VOCALS ONLY EMOTION) & Wheel 2 (FULL MUSIC EMOTION)
            let wheelCx = w - dockW * 0.5
            let wheelR = min(dockW * 0.36, h * 0.20)
            let wheel1Cy = h * 0.27
            let wheel2Cy = h * 0.73

            let vocState = computeVocalEmotionState(vocals: vocals)
            let musDot = computeMusicEmotionDot(buckets: buckets, domHz: snapshot.dominantHz)

            drawWheel(
                ctx: &ctx,
                center: CGPoint(x: wheelCx, y: wheel1Cy),
                radius: wheelR,
                dotOffset: vocState.dot,
                dotColor: Color(red: 0.22, green: 0.95, blue: 0.76),
                hitBrightness: vocState.hitIntensity,
                phosphorGlow: vocState.phosphorGlow,
                rosettePhase: Self.kluverVocalPhase,
                petals: 6
            )
            drawWheel(
                ctx: &ctx,
                center: CGPoint(x: wheelCx, y: wheel2Cy),
                radius: wheelR,
                dotOffset: musDot,
                dotColor: Color(red: 0.0, green: 0.94, blue: 1.0),
                hitBrightness: 0.65,
                phosphorGlow: 0.90,
                rosettePhase: Self.chladniMusicPhase,
                petals: 5
            )
        }
    }

    private func drawWheel(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        dotOffset: CGPoint,
        dotColor: Color,
        hitBrightness: Double,
        phosphorGlow: Double,
        rosettePhase: Double,
        petals: Int
    ) {
        for mult in [0.33, 0.66, 1.0] {
            let r = radius * CGFloat(mult)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(Color(red: 0.12, green: 0.18, blue: 0.28)),
                lineWidth: 1
            )
        }
        for s in 0..<8 {
            let ang = Double(s) * (.pi / 4.0)
            let p = CGPoint(
                x: center.x + CGFloat(cos(ang)) * radius,
                y: center.y + CGFloat(sin(ang)) * radius
            )
            var spoke = Path()
            spoke.move(to: center)
            spoke.addLine(to: p)
            ctx.stroke(spoke, with: .color(Color(red: 0.08, green: 0.12, blue: 0.20)), lineWidth: 1)
        }

        // Bressloff-Cowan Kluver Form-Constant / Chladni-Fische Dihedral Rosette
        if phosphorGlow > 0.16 {
            var rosePath = Path()
            for step in 0...64 {
                let th = Double(step) * (.pi * 2.0) / 64.0
                let mod = cos(Double(petals) * th + rosettePhase) * sin(2.0 * th - rosettePhase)
                let rNode = radius * CGFloat(0.36 + 0.30 * mod)
                let pt = CGPoint(
                    x: center.x + CGFloat(cos(th + rosettePhase * 0.33)) * rNode,
                    y: center.y + CGFloat(sin(th + rosettePhase * 0.33)) * rNode
                )
                if step == 0 {
                    rosePath.move(to: pt)
                } else {
                    rosePath.addLine(to: pt)
                }
            }
            rosePath.closeSubpath()
            ctx.stroke(rosePath, with: .color(dotColor.opacity(phosphorGlow * 0.42)), lineWidth: 1)
        }

        let dotPt = CGPoint(
            x: center.x + dotOffset.x * (radius - 6),
            y: center.y + dotOffset.y * (radius - 6)
        )
        let haloR = CGFloat(6.0 + hitBrightness * 14.0)
        let haloRect = CGRect(x: dotPt.x - haloR, y: dotPt.y - haloR, width: haloR * 2, height: haloR * 2)
        ctx.stroke(Path(ellipseIn: haloRect), with: .color(dotColor.opacity(phosphorGlow * 0.75)), lineWidth: hitBrightness > 0.6 ? 2.5 : 1.5)

        let coreR = CGFloat(3.0 + hitBrightness * 5.0 * phosphorGlow)
        let coreRect = CGRect(x: dotPt.x - coreR, y: dotPt.y - coreR, width: coreR * 2, height: coreR * 2)
        ctx.fill(Path(ellipseIn: coreRect), with: .color(dotColor.opacity(max(0.22, phosphorGlow))))

        if phosphorGlow > 0.25 {
            let hotR = CGFloat(1.5 + hitBrightness * 2.5)
            let hotRect = CGRect(x: dotPt.x - hotR, y: dotPt.y - hotR, width: hotR * 2, height: hotR * 2)
            ctx.fill(Path(ellipseIn: hotRect), with: .color(Color.white.opacity(phosphorGlow)))
        }
    }

    private static var persistedVocalDot: CGPoint = .zero
    private static var persistedPhosphorGlow: Double = 0.18
    private static var kluverVocalPhase: Double = 0.0
    private static var chladniMusicPhase: Double = 0.0

    private func computeVocalEmotionState(vocals: [UInt16]) -> (dot: CGPoint, hitIntensity: Double, phosphorGlow: Double) {
        guard vocals.count == 64 else {
            return (Self.persistedVocalDot, 0.0, Self.persistedPhosphorGlow)
        }
        let f0 = avg(vocals, 6...12)
        let chest = avg(vocals, 13...19)
        let heart = avg(vocals, 20...27)
        let belt = avg(vocals, 28...34)
        let air = avg(vocals, 35...45)
        let total = f0 + chest + heart + belt + air
        if total > 42 {
            let vx = ((heart + chest) - f0 * 1.5) / 480.0
            let vy = ((chest + f0) - (belt + air)) / 480.0
            let mag = max(1.0, hypot(vx, vy))
            let target = CGPoint(x: vx / mag * min(0.92, mag), y: vy / mag * min(0.92, mag))
            Self.persistedVocalDot = CGPoint(
                x: Self.persistedVocalDot.x * 0.65 + target.x * 0.35,
                y: Self.persistedVocalDot.y * 0.65 + target.y * 0.35
            )
            let hit = min(1.0, max(0.15, total / 950.0))
            Self.kluverVocalPhase += 0.04 + hit * 0.08
            Self.persistedPhosphorGlow = max(Self.persistedPhosphorGlow, min(1.0, 0.35 + hit * 0.65))
            return (Self.persistedVocalDot, hit, Self.persistedPhosphorGlow)
        } else {
            // Persist & Fade: dot freezes where the voice left off while phosphor slowly cools down
            Self.persistedPhosphorGlow = max(0.15, Self.persistedPhosphorGlow * 0.965)
            return (Self.persistedVocalDot, 0.0, Self.persistedPhosphorGlow)
        }
    }

    private func computeMusicEmotionDot(buckets: [UInt16], domHz: UInt32) -> CGPoint {
        guard buckets.count == 64 else { return .zero }
        let sub = avg(buckets, 0...5)
        let body = avg(buckets, 6...19)
        let mid = avg(buckets, 20...34)
        let ultra = avg(buckets, 46...63)
        Self.chladniMusicPhase += 0.025 + min(0.08, (sub + mid) / 8000.0)
        let shrutiAng = Double(domHz % 22) * (.pi * 2.0 / 22.0)
        let mx = ((body + mid) - sub * 1.6) / 700.0 + cos(shrutiAng) * 0.18
        let my = ((body + sub) - (ultra + mid)) / 700.0 + sin(shrutiAng) * 0.18
        let mag = max(1.0, hypot(mx, my))
        return CGPoint(x: mx / mag * min(0.92, mag), y: my / mag * min(0.92, mag))
    }

    private func avg(_ arr: [UInt16], _ range: ClosedRange<Int>) -> Double {
        var s = 0.0
        for i in range { s += Double(arr[i]) }
        return s / Double(range.count)
    }

    private func thermalOceanicColor(_ t: Double) -> Color {
        if t < 0.35 {
            return Color(red: 0.04, green: 0.35 + t * 1.2, blue: 0.65 + t * 0.8)
        } else if t < 0.70 {
            return Color(red: (t - 0.35) * 2.5, green: 0.88, blue: 0.75 - (t - 0.35) * 1.2)
        } else {
            return Color(red: 1.0, green: 0.85 - (t - 0.70) * 1.2, blue: 0.35 + (t - 0.70) * 1.8)
        }
    }
}
