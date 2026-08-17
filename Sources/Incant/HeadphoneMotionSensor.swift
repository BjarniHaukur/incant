import CoreMotion
import OSLog
import simd

/// Motion from the AirPods' own inertial sensor.
///
/// MacBooks have carried no accelerometer since drives stopped spinning — the
/// Sudden Motion Sensor existed to park platters and left with them — so a head
/// is the only inertial sensor within reach of a Mac. It is enough: walking
/// arrives as a steady series of jolts, and the fluid can feel every one.
///
/// Only runs during a dictation, so the motion permission is asked for while the
/// user is looking at the thing that wants it, and nothing is sampled the rest of
/// the time.
@MainActor
final class HeadphoneMotionSensor {
    /// A unit direction in the plane of the screen, and how hard the shove was.
    var onMotion: ((SIMD2<Float>, Float) -> Void)?

    private let manager = CMHeadphoneMotionManager()
    private var running = false
    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "HeadphoneMotion")

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.logger.info("Headphone motion unavailable: \(error.localizedDescription, privacy: .public)")
                    self.running = false
                    return
                }
                guard let motion else { return }
                self.received(motion)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
    }

    private func received(_ motion: CMDeviceMotion) {
        // Gravity is already removed from userAcceleration, so what is left is the
        // walking itself. Forward and sideways head motion map to the plane of the
        // screen; the vertical bounce of a step is what carries most of it.
        let acceleration = motion.userAcceleration
        let shove = SIMD2(Float(acceleration.x), Float(-acceleration.z))
        let magnitude = simd_length(shove)
        guard magnitude > 0.025 else { return }
        onMotion?(shove / magnitude, min(1.8, magnitude * 3.2))
    }
}
