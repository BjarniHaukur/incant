import Foundation
import IOKit.hid
import OSLog

/// The MacBook lid angle, straight off the sensor the hinge already has.
///
/// It is an ordinary HID device — Apple's vendor ID, the sensor usage page, usage
/// 0x8A — so reading it needs no private framework and asks for no permission.
/// Report 1 carries the angle in degrees as a little-endian pair after the report
/// ID, and the device only sends when the hinge actually moves, which is exactly
/// when the fluid should notice.
@MainActor
final class LidAngleSensor {
    /// The angle in degrees, and how fast it is changing in degrees per second.
    var onChange: ((Double, Double) -> Void)?

    private var device: IOHIDDevice?
    /// The callback keeps this pointer after registration returns, so it cannot
    /// be a Swift array's buffer.
    private let report = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
    private var lastAngle: Double?
    private var lastSample = CFAbsoluteTimeGetCurrent()
    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "LidAngle")

    deinit { report.deallocate() }

    func start() {
        guard device == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let found = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first,
              IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            // Desktops, and any Mac whose hinge does not report, simply never
            // deliver lid motion. Nothing else about the orb depends on it.
            logger.info("No lid angle sensor available")
            return
        }
        device = found

        IOHIDDeviceRegisterInputReportCallback(
            found, report, 32,
            { context, _, _, _, _, bytes, length in
                guard let context, length >= 3 else { return }
                let degrees = Double(Int(bytes[1]) | (Int(bytes[2]) << 8))
                MainActor.assumeIsolated {
                    Unmanaged<LidAngleSensor>.fromOpaque(context)
                        .takeUnretainedValue()
                        .received(degrees)
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            found, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        logger.info("Lid angle sensor attached")
    }

    private func received(_ degrees: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            lastAngle = degrees
            lastSample = now
        }
        // Reports arrive about once a second while the lid is still, so the first
        // one after a pause says nothing about speed.
        guard let previous = lastAngle, now - lastSample < 0.6 else { return }
        let elapsed = max(now - lastSample, 1.0 / 240.0)
        onChange?(degrees, (degrees - previous) / elapsed)
    }
}
