import Darwin
import Foundation
import os
import WatchKit

extension WatchSample {
    static func markerURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("listen-telemetry.json")
    }

    @MainActor
    static func current(date: Date, listenSeconds: Double) -> WatchSample {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel
        let memory = vmInfo()
        return WatchSample(
            date: date,
            listenSeconds: listenSeconds,
            virtualMB: megabytes(memory?.virtual_size ?? 0),
            footprintMB: megabytes(memory?.phys_footprint ?? 0),
            availableMB: megabytes(UInt64(os_proc_available_memory())),
            appState: appState(WKApplication.shared().applicationState),
            thermalState: thermalState(ProcessInfo.processInfo.thermalState),
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            battery: battery < 0 ? nil : Double(battery),
            runtime: ListenRuntimeSession.shared.status
        )
    }

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }

    private static func appState(_ state: WKApplicationState) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
