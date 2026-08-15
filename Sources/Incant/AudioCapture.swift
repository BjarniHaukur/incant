import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "Audio")
    private var converter: AVAudioConverter?
    private var levelPeak: Float = 0
    private var levelLogged = Date.distantPast
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    static func requestPermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }

    func start(
        onAudio: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        let input = engine.inputNode
        routeAwayFromBluetoothMicrophone(input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "Incant.Audio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not prepare the microphone"
            ])
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer, using: converter) else { return }
            let level = self.level(from: buffer)
            self.reportLevel(level)
            onLevel(level)
            if let pointer = converted.int16ChannelData?.pointee {
                onAudio(Data(bytes: pointer, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Opening an AirPods microphone forces Bluetooth into its low-bandwidth
    /// headset profile and degrades music playback. Keep the user's output
    /// device untouched, but route this engine to a built-in input whenever
    /// the current default input is Bluetooth.
    private func routeAwayFromBluetoothMicrophone(_ input: AVAudioInputNode) {
        guard let defaultInput = Self.defaultInputDeviceID(),
              Self.isBluetooth(defaultInput),
              let builtInInput = Self.builtInInputDeviceID(),
              let audioUnit = input.audioUnit else {
            return
        }

        var deviceID = builtInInput
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            logger.info("Using built-in microphone to preserve Bluetooth output quality")
        } else {
            logger.error("Could not route away from Bluetooth microphone: \(status, privacy: .public)")
        }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        guard let transport = transportType(of: deviceID) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return nil }

        return devices.first { deviceID in
            transportType(of: deviceID) == kAudioDeviceTransportTypeBuiltIn
                && hasInputStreams(deviceID)
        }
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transport
        ) == noErr else { return nil }
        return transport
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// One line a second with the loudest level in it, so "the orb is not
    /// reacting" can be told apart from "the microphone is not being heard"
    /// without a debugger.
    private func reportLevel(_ level: Float) {
        levelPeak = max(levelPeak, level)
        guard Date.now.timeIntervalSince(levelLogged) >= 1 else { return }
        levelLogged = .now
        logger.info("Microphone level peak \(self.levelPeak, format: .fixed(precision: 2), privacy: .public)")
        levelPeak = 0
    }

    private func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_01))
        return min(max((db + 48) / 42, 0), 1)
    }
}
