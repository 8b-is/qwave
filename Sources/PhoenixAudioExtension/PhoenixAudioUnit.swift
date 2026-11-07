import AVFoundation
import AudioToolbox
import Foundation
import SovereignCore

/// Apple Audio Unit v3 (`AUv3` — `aufx` / `phx8` / `8bIS`) Real-Time Audio Filter for macOS and iOS.
///
/// Runs the 100% Zero-Float Rust `PhoenixLiveProcessor` (`libqwave_core.a`) inside CoreAudio's
/// real-time render thread with zero heap allocations:
/// - Stage 1: 16x (768 kHz) Integer Catmull-Rom Cubic Hermite Clipping & Dropout Repair
/// - Stage 2: <140 Hz Naad Sub-Bass Resonator + 3.7 Hz Ultra-Low DC Blocker
/// - Stage 3: Soul-Coupled Svara F1/F2/F3 Singer Vocal Emotion & Class-A Triode Chest Warmth
/// - Stage 4: 3-Stage Anti-Clipping Headroom Governor + Silk-Knee Studio Master Limiter
/// - Stage 5: 64-Anchor -> 4096-Bucket (20 Hz .. 384,000 Hz) Time-Domain Marine Salience & Vocal Gate
public final class PhoenixAudioUnit: AUAudioUnit, @unchecked Sendable {
    private let dspEngine: RustPhoenixSound
    private var inputBus: AUAudioUnitBus
    private var outputBus: AUAudioUnitBus
    private var internalInputBuses: AUAudioUnitBusArray!
    private var internalOutputBuses: AUAudioUnitBusArray!
    private var pcmScratchBuffer: UnsafeMutablePointer<Int16>?
    private var pcmScratchCapacityFrames: Int = 0
    private var pullBufferList: AudioBufferList = AudioBufferList()

    private var currentPresetID: UInt8 = RustPhoenixSound.Preset.alexandraSanctuary.rawValue
    private var naadSubQ10: Int32 = 280
    private var svaraVocalQ10: Int32 = 280
    private var warmthQ10: Int32 = 360
    private var goonjVelvetQ10: Int32 = 380
    private var airQ10: Int32 = 240
    private var stereoWidthQ10: Int32 = 1320
    private var alexandraResetOn: Bool = false

    public override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        self.dspEngine = RustPhoenixSound(sampleRateHz: 48_000, preset: .alexandraSanctuary)
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        self.inputBus = try AUAudioUnitBus(format: defaultFormat)
        self.outputBus = try AUAudioUnitBus(format: defaultFormat)

        try super.init(componentDescription: componentDescription, options: options)

        self.internalInputBuses = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .input,
            busses: [inputBus]
        )
        self.internalOutputBuses = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .output,
            busses: [outputBus]
        )
        self.maximumFramesToRender = 4096
        setupParameterTree()
    }

    deinit {
        if let ptr = pcmScratchBuffer {
            ptr.deallocate()
            pcmScratchBuffer = nil
        }
    }

    public override var inputBusses: AUAudioUnitBusArray {
        internalInputBuses
    }

    public override var outputBusses: AUAudioUnitBusArray {
        internalOutputBuses
    }

    public override var canProcessInPlace: Bool {
        true
    }

    public func snapshotTelemetry() -> RustPhoenixSound.TelemetrySnapshot {
        dspEngine.telemetry()
    }

    public func applyPreset(_ preset: RustPhoenixSound.Preset) {
        currentPresetID = preset.rawValue
        dspEngine.setPreset(preset)
        parameterTree?.parameter(withAddress: 0)?.value = AUValue(preset.rawValue)
    }

    public func setFeelControls(automagic: Bool, voicePct: UInt16, bassPct: UInt16, spacePct: UInt16) {
        dspEngine.setFeelControls(
            automagic: automagic,
            voicePct: voicePct,
            bassPct: bassPct,
            spacePct: spacePct
        )
    }

    public func setAlexandraReset(_ active: Bool) {
        alexandraResetOn = active
        dspEngine.setAlexandraReset(active)
        if active {
            currentPresetID = RustPhoenixSound.Preset.alexandraSanctuary.rawValue
            parameterTree?.parameter(withAddress: 0)?.value = AUValue(currentPresetID)
        }
        parameterTree?.parameter(withAddress: 6)?.value = active ? 1.0 : 0.0
    }

    private func setupParameterTree() {
        let pPreset = AUParameterTree.createParameter(
            withIdentifier: "preset",
            name: "PhoeniX Preset",
            address: 0,
            min: 0,
            max: 5,
            unit: .indexed,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: RustPhoenixSound.Preset.allCases.map(\.displayName),
            dependentParameters: nil
        )
        let pNaad = AUParameterTree.createParameter(
            withIdentifier: "naadSub",
            name: "Naad Sub-Bass (<140Hz)",
            address: 1,
            min: 0,
            max: 1024,
            unit: .generic,
            unitName: "Q10",
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        let pSvara = AUParameterTree.createParameter(
            withIdentifier: "svaraVocal",
            name: "Svara Vocal Emotion",
            address: 2,
            min: 0,
            max: 1024,
            unit: .generic,
            unitName: "Q10",
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        let pWarmth = AUParameterTree.createParameter(
            withIdentifier: "warmth",
            name: "Triode Chest Warmth",
            address: 3,
            min: 0,
            max: 1024,
            unit: .generic,
            unitName: "Q10",
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        let pGoonj = AUParameterTree.createParameter(
            withIdentifier: "goonjVelvet",
            name: "Goonj Ternary Velvet",
            address: 4,
            min: 0,
            max: 1024,
            unit: .generic,
            unitName: "Q10",
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        let pAir = AUParameterTree.createParameter(
            withIdentifier: "babbageAir",
            name: "384kHz Babbage Air",
            address: 5,
            min: 0,
            max: 1024,
            unit: .generic,
            unitName: "Q10",
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        let pAlexReset = AUParameterTree.createParameter(
            withIdentifier: "alexandraReset",
            name: "Alexandra Sanctuary Reset Wave",
            address: 6,
            min: 0,
            max: 1,
            unit: .boolean,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )

        pPreset.value = AUValue(currentPresetID)
        pNaad.value = AUValue(naadSubQ10)
        pSvara.value = AUValue(svaraVocalQ10)
        pWarmth.value = AUValue(warmthQ10)
        pGoonj.value = AUValue(goonjVelvetQ10)
        pAir.value = AUValue(airQ10)
        pAlexReset.value = alexandraResetOn ? 1.0 : 0.0

        let tree = AUParameterTree.createTree(withChildren: [
            pPreset, pNaad, pSvara, pWarmth, pGoonj, pAir, pAlexReset,
        ])

        tree.implementorValueObserver = { [weak self] param, value in
            guard let self else { return }
            switch param.address {
            case 0:
                let id = UInt8(max(0, min(5, Int(value.rounded()))))
                self.currentPresetID = id
                if let preset = RustPhoenixSound.Preset(rawValue: id) {
                    self.dspEngine.setPreset(preset)
                }
            case 1:
                self.naadSubQ10 = Int32(max(0, min(1024, Int(value))))
                self.syncCustomParams()
            case 2:
                self.svaraVocalQ10 = Int32(max(0, min(1024, Int(value))))
                self.syncCustomParams()
            case 3:
                self.warmthQ10 = Int32(max(0, min(1024, Int(value))))
                self.syncCustomParams()
            case 4:
                self.goonjVelvetQ10 = Int32(max(0, min(1024, Int(value))))
                self.syncCustomParams()
            case 5:
                self.airQ10 = Int32(max(0, min(1024, Int(value))))
                self.syncCustomParams()
            case 6:
                let active = value >= 0.5
                self.alexandraResetOn = active
                self.dspEngine.setAlexandraReset(active)
            default:
                break
            }
        }

        tree.implementorValueProvider = { [weak self] param in
            guard let self else { return 0 }
            switch param.address {
            case 0: return AUValue(self.currentPresetID)
            case 1: return AUValue(self.naadSubQ10)
            case 2: return AUValue(self.svaraVocalQ10)
            case 3: return AUValue(self.warmthQ10)
            case 4: return AUValue(self.goonjVelvetQ10)
            case 5: return AUValue(self.airQ10)
            case 6: return self.alexandraResetOn ? 1.0 : 0.0
            default: return 0
            }
        }

        self.parameterTree = tree
    }

    private func syncCustomParams() {
        dspEngine.setParams(
            naadSubQ10: naadSubQ10,
            svaraVocalQ10: svaraVocalQ10,
            warmthQ10: warmthQ10,
            goonjVelvetQ10: goonjVelvetQ10,
            airQ10: airQ10,
            stereoWidthQ10: stereoWidthQ10
        )
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let maxFrames = Int(maximumFramesToRender)
        if pcmScratchBuffer == nil || pcmScratchCapacityFrames < maxFrames {
            if let existing = pcmScratchBuffer {
                existing.deallocate()
            }
            pcmScratchBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: maxFrames * 2)
            pcmScratchBuffer?.initialize(repeating: 0, count: maxFrames * 2)
            pcmScratchCapacityFrames = maxFrames
        }
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        if let existing = pcmScratchBuffer {
            existing.deallocate()
            pcmScratchBuffer = nil
            pcmScratchCapacityFrames = 0
        }
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let engine = self.dspEngine
        return { [weak self] actionFlags, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let self, let scratch = self.pcmScratchBuffer else {
                return kAudioUnitErr_Uninitialized
            }
            let frames = min(Int(frameCount), self.pcmScratchCapacityFrames)
            if let pullInputBlock {
                var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
                let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
                if status != noErr {
                    return status
                }
            } else {
                _ = actionFlags
                return kAudioUnitErr_NoConnection
            }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 1 else { return noErr }

            let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float32.self)
            let rightPtr = (abl.count > 1 ? abl[1].mData : abl[0].mData)?.assumingMemoryBound(to: Float32.self)
            guard let lIn = leftPtr, let rIn = rightPtr else { return noErr }

            for f in 0..<frames {
                let sl = max(-1.0, min(1.0, lIn[f]))
                let sr = max(-1.0, min(1.0, rIn[f]))
                scratch[f * 2] = Int16(sl * 32767.0)
                scratch[f * 2 + 1] = Int16(sr * 32767.0)
            }

            engine.processInterleavedStereo(scratch, frames: frames)

            let invScale: Float32 = 1.0 / 32768.0
            for f in 0..<frames {
                let outL = Float32(scratch[f * 2]) * invScale
                let outR = Float32(scratch[f * 2 + 1]) * invScale
                lIn[f] = outL
                if abl.count > 1 {
                    rIn[f] = outR
                }
            }
            return noErr
        }
    }
}
