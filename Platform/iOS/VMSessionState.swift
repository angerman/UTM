//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

/// Represents the UI state for a single VM session.
@MainActor class VMSessionState: NSObject, ObservableObject {
    let vm: UTMQemuVirtualMachine
    
    var qemuConfig: UTMQemuConfiguration! {
        vm.config.qemuConfig
    }
    
    @Published var vmState: UTMVMState = .vmStopped
    
    @Published var fatalError: String?
    
    @Published var nonfatalError: String?
    
    @Published var primaryInput: CSInput?
    
    #if !WITH_QEMU_TCI
    private var primaryUsbManager: CSUSBManager?
    
    @Published var mostRecentConnectedDevice: CSUSBDevice?
    
    @Published var allUsbDevices: [CSUSBDevice] = []
    
    @Published var connectedUsbDevices: [CSUSBDevice] = []
    #else
    let mostRecentConnectedDevice: Any? = nil
    
    let allUsbDevices: [Any] = []
    
    let connectedUsbDevices: [Any] = []
    #endif
    
    @Published var isUsbBusy: Bool = false
    
    @Published var devices: [VMWindowState.Device] = []
    
    @Published var windows: [UUID] = []
    
    @Published var primaryWindow: UUID?
    
    @Published var activeWindow: UUID?
    
    @Published var windowDeviceMap: [UUID: VMWindowState.Device] = [:]
    
    init(for vm: UTMQemuVirtualMachine) {
        self.vm = vm
        super.init()
        vm.delegate = self
        vm.ioDelegate = self
    }
    
    func registerWindow(_ window: UUID) {
        windows.append(window)
        if primaryWindow == nil {
            primaryWindow = window
        }
        if activeWindow == nil {
            activeWindow = window
        }
    }
    
    func removeWindow(_ window: UUID) {
        windows.removeAll { $0 == window }
        if primaryWindow == window {
            primaryWindow = windows.first
        }
        if activeWindow == window {
            activeWindow = windows.first
        }
    }
}

extension VMSessionState: UTMVirtualMachineDelegate {
    nonisolated func virtualMachine(_ vm: UTMVirtualMachine, didTransitionTo state: UTMVMState) {
        Task { @MainActor in
            vmState = state
            if state == .vmStopped {
                clearDevices()
            }
        }
    }
    
    nonisolated func virtualMachine(_ vm: UTMVirtualMachine, didErrorWithMessage message: String) {
        Task { @MainActor in
            fatalError = message
        }
    }
}

extension VMSessionState: UTMSpiceIODelegate {
    nonisolated func spiceDidCreateInput(_ input: CSInput) {
        Task { @MainActor in
            guard primaryInput == nil else {
                return
            }
            primaryInput = input
        }
    }
    
    nonisolated func spiceDidDestroyInput(_ input: CSInput) {
        Task { @MainActor in
            guard primaryInput == input else {
                return
            }
            primaryInput = nil
        }
    }
    
    nonisolated func spiceDidCreateDisplay(_ display: CSDisplay) {
        Task { @MainActor in
            assert(display.monitorID < qemuConfig.displays.count)
            let device = VMWindowState.Device.display(display, display.monitorID)
            devices.append(device)
            // associate with the next available window
            for windowId in windows {
                if windowDeviceMap[windowId] == nil {
                    windowDeviceMap[windowId] = device
                }
            }
        }
    }
    
    nonisolated func spiceDidDestroyDisplay(_ display: CSDisplay) {
        Task { @MainActor in
            let device = VMWindowState.Device.display(display, display.monitorID)
            devices.removeAll { $0 == device }
            for windowId in windows {
                if windowDeviceMap[windowId] == device {
                    windowDeviceMap[windowId] = nil
                }
            }
        }
    }
    
    nonisolated func spiceDidUpdateDisplay(_ display: CSDisplay) {
        // nothing to do
    }
    
    nonisolated private func configIdForSerial(_ serial: CSPort) -> Int? {
        let prefix = "com.utmapp.terminal."
        guard serial.name?.hasPrefix(prefix) ?? false else {
            return nil
        }
        return Int(serial.name!.dropFirst(prefix.count))
    }
    
    nonisolated func spiceDidCreateSerial(_ serial: CSPort) {
        Task { @MainActor in
            guard let id = configIdForSerial(serial) else {
                logger.error("cannot setup window for serial '\(serial.name ?? "(null)")'")
                return
            }
            let device = VMWindowState.Device.serial(serial, id)
            assert(id < qemuConfig.serials.count)
            assert(qemuConfig.serials[id].mode == .builtin && qemuConfig.serials[id].terminal != nil)
            devices.append(device)
            // associate with the next available window
            for windowId in windows {
                if windowDeviceMap[windowId] == nil {
                    windowDeviceMap[windowId] = device
                }
            }
        }
    }
    
    nonisolated func spiceDidDestroySerial(_ serial: CSPort) {
        Task { @MainActor in
            guard let id = configIdForSerial(serial) else {
                return
            }
            let device = VMWindowState.Device.serial(serial, id)
            devices.removeAll { $0 == device }
            for windowId in windows {
                if windowDeviceMap[windowId] == device {
                    windowDeviceMap[windowId] = nil
                }
            }
        }
    }
    
    #if !WITH_QEMU_TCI
    nonisolated func spiceDidChangeUsbManager(_ usbManager: CSUSBManager?) {
        Task { @MainActor in
            primaryUsbManager?.delegate = nil
            primaryUsbManager = usbManager
            usbManager?.delegate = self
        }
    }
    #endif
}

#if !WITH_QEMU_TCI
extension VMSessionState: CSUSBManagerDelegate {
    nonisolated func spiceUsbManager(_ usbManager: CSUSBManager, deviceError error: String, for device: CSUSBDevice) {
        Task { @MainActor in
            nonfatalError = error
        }
    }
    
    nonisolated func spiceUsbManager(_ usbManager: CSUSBManager, deviceAttached device: CSUSBDevice) {
        Task { @MainActor in
            mostRecentConnectedDevice = device
        }
    }
    
    nonisolated func spiceUsbManager(_ usbManager: CSUSBManager, deviceRemoved device: CSUSBDevice) {
        Task { @MainActor in
            disconnectDevice(device)
        }
    }
    
    func refreshDevices() {
        guard let usbManager = self.primaryUsbManager else {
            logger.error("no usb manager connected")
            return
        }
        isUsbBusy = true
        Task.detached { [self] in
            let devices = usbManager.usbDevices
            await MainActor.run {
                allUsbDevices = devices
                isUsbBusy = false
            }
        }
    }
    
    func connectDevice(_ usbDevice: CSUSBDevice) {
        guard let usbManager = self.primaryUsbManager else {
            logger.error("no usb manager connected")
            return
        }
        isUsbBusy = true
        Task.detached { [self] in
            let (success, message) = await usbManager.connectUsbDevice(usbDevice)
            await MainActor.run {
                if success {
                    self.connectedUsbDevices.append(usbDevice)
                } else {
                    nonfatalError = message
                }
                isUsbBusy = false
            }
        }
    }
    
    func disconnectDevice(_ usbDevice: CSUSBDevice) {
        guard let usbManager = self.primaryUsbManager else {
            logger.error("no usb manager connected")
            return
        }
        isUsbBusy = true
        Task.detached { [self] in
            await usbManager.disconnectUsbDevice(usbDevice)
            await MainActor.run {
                connectedUsbDevices.removeAll(where: { $0 == usbDevice })
                isUsbBusy = false
            }
        }
    }
    
    private func clearDevices() {
        connectedUsbDevices.removeAll()
        allUsbDevices.removeAll()
    }
}
#endif

extension VMSessionState {
    @objc private func suspend() {
        // dummy function for selector
    }
    
    func terminateApplication() {
        DispatchQueue.main.async { [self] in
            // animate to home screen
            let app = UIApplication.shared
            app.performSelector(onMainThread: #selector(suspend), with: nil, waitUntilDone: true)
            
            // wait 2 seconds while app is going background
            Thread.sleep(forTimeInterval: 2)
            
            // exit app when app is in background
            exit(0);
        }
    }
    
    func powerDown() {
        vm.requestVmDeleteState()
        vm.vmStop { _ in
            self.terminateApplication()
        }
    }
    
    func pauseResume() {
        let shouldSaveState = !vm.isRunningAsSnapshot
        if vm.state == .vmStarted {
            vm.requestVmPause(save: shouldSaveState)
        } else if vm.state == .vmPaused {
            vm.requestVmResume()
        }
    }
    
    func reset() {
        vm.requestVmReset()
    }
}
