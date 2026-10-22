import Foundation
import OzCore

// Raw trackpad access through the private MultitouchSupport framework (same
// technique as MiddleClick / Jitouch / BetterTouchTool). This sees every finger
// regardless of which app is focused, and without Input Monitoring permission.

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterFn = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef?, Int32) -> Int32
private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef?) -> Int32

/// Size of MTTouch in MultitouchSupport (stable since 10.5).
private let touchStride = 96

private let contactCallback: MTContactCallback = { device, data, count, timestamp, _ in
    var touches: [Touch] = []
    if let data, count > 0 {
        touches.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let p = UnsafeRawPointer(data) + i * touchStride
            let id = p.loadUnaligned(fromByteOffset: 16, as: Int32.self)
            let state = p.loadUnaligned(fromByteOffset: 20, as: Int32.self)
            let x = p.loadUnaligned(fromByteOffset: 32, as: Float.self)
            let y = p.loadUnaligned(fromByteOffset: 36, as: Float.self)
            touches.append(Touch(id: id, x: Double(x), y: Double(y), state: state))
        }
    }
    TouchSource.shared.onFrame?(Int(bitPattern: device), touches, timestamp)
    return 0
}

final class TouchSource {
    static let shared = TouchSource()

    /// Called on MultitouchSupport's thread: (device, touches, timestamp).
    var onFrame: ((Int, [Touch], Double) -> Void)?

    private var handle: UnsafeMutableRawPointer?
    private var createList: MTDeviceCreateListFn?
    private var register: MTRegisterFn?
    private var unregister: MTRegisterFn?
    private var startDevice: MTDeviceStartFn?
    private var stopDevice: MTDeviceStopFn?
    private var deviceList: CFArray?
    private var devices: [MTDeviceRef] = []

    private init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        guard let handle else { return }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        createList = sym("MTDeviceCreateList", MTDeviceCreateListFn.self)
        register = sym("MTRegisterContactFrameCallback", MTRegisterFn.self)
        unregister = sym("MTUnregisterContactFrameCallback", MTRegisterFn.self)
        startDevice = sym("MTDeviceStart", MTDeviceStartFn.self)
        stopDevice = sym("MTDeviceStop", MTDeviceStopFn.self)
    }

    var isAvailable: Bool { createList != nil && register != nil && startDevice != nil }
    var deviceCount: Int { devices.count }

    @discardableResult
    func start() -> Bool {
        stop()
        guard let createList, let register, let startDevice,
              let list = createList()?.takeRetainedValue() else { return false }
        deviceList = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            register(dev, contactCallback)
            _ = startDevice(dev, 0)
            devices.append(dev)
        }
        return !devices.isEmpty
    }

    func stop() {
        for dev in devices {
            unregister?(dev, contactCallback)
            _ = stopDevice?(dev)
        }
        devices = []
        deviceList = nil
    }
}
