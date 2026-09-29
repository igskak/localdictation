import CoreAudio
import Foundation

/// Collapses a burst of route notifications into one decision.
///
/// A Bluetooth switch or another app starting voice processing produces dozens
/// of property notifications within milliseconds. Acting on each one would stop
/// and restart the microphone dozens of times; acting on the last one, a short
/// quiet period later, rebinds once.
final class RouteChangeDebouncer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let quietPeriod: TimeInterval
    private let handler: @Sendable (InputRouteEvent) -> Void
    /// Invalidates work items scheduled before the latest event.
    private var generation = 0
    private var pending: InputRouteEvent?
    private var isCancelled = false

    init(
        queue: DispatchQueue,
        quietPeriod: TimeInterval,
        handler: @escaping @Sendable (InputRouteEvent) -> Void
    ) {
        self.queue = queue
        self.quietPeriod = quietPeriod
        self.handler = handler
    }

    /// Call from `queue`.
    func submit(_ event: InputRouteEvent) {
        guard !isCancelled else { return }
        if let current = pending, current.precedence >= event.precedence {
            // Keep the more informative event, but restart the quiet period:
            // the burst is still arriving.
        } else {
            pending = event
        }

        generation += 1
        let scheduled = generation
        queue.asyncAfter(deadline: .now() + quietPeriod) { [weak self] in
            guard let self, !self.isCancelled, self.generation == scheduled else { return }
            guard let event = self.pending else { return }
            self.pending = nil
            self.handler(event)
        }
    }

    /// Call from `queue`.
    func cancel() {
        isCancelled = true
        pending = nil
        generation += 1
    }
}

/// Watches the audio route while a recording runs.
///
/// Everything here happens on one private serial queue: Core Audio's listener
/// blocks are registered against it, the watchdog fires on it, and the
/// debounced event is delivered on it. Core Audio's own listener thread is
/// never asked to do work.
final class InputRouteMonitor: @unchecked Sendable {
    private let hardware: any AudioHardware
    private let queue: DispatchQueue
    private let quietPeriod: TimeInterval
    private let watchdogSilence: TimeInterval
    private let watchdogInterval: TimeInterval

    private var debouncer: RouteChangeDebouncer?
    private var systemTokens: [AudioPropertyListenerToken] = []
    private var deviceTokens: [AudioPropertyListenerToken] = []
    private var watchdog: DispatchSourceTimer?
    private var lastCallbackUptime: (@Sendable () -> TimeInterval)?
    private var stalled = false

    init(
        hardware: any AudioHardware,
        queue: DispatchQueue,
        quietPeriod: TimeInterval = 0.15,
        watchdogSilence: TimeInterval = 0.5,
        watchdogInterval: TimeInterval = 0.25
    ) {
        self.hardware = hardware
        self.queue = queue
        self.quietPeriod = quietPeriod
        self.watchdogSilence = watchdogSilence
        self.watchdogInterval = watchdogInterval
    }

    /// Starts watching. `onEvent` is called on the monitor's queue, at most once
    /// per quiet period.
    func start(
        device: AudioDeviceID,
        lastCallbackUptime: @escaping @Sendable () -> TimeInterval,
        onEvent: @escaping @Sendable (InputRouteEvent) -> Void
    ) {
        queue.async { [self] in
            stop_locked()
            stalled = false
            self.lastCallbackUptime = lastCallbackUptime
            let debouncer = RouteChangeDebouncer(queue: queue, quietPeriod: quietPeriod, handler: onEvent)
            self.debouncer = debouncer

            let system = AudioObjectID(kAudioObjectSystemObject)
            addSystemListener(system, kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged)
            addSystemListener(system, kAudioHardwarePropertyDevices, .deviceListChanged)
            bind_locked(to: device)
            startWatchdog_locked()
        }
    }

    /// Moves the per-device listeners onto a new binding, without disturbing the
    /// system-wide ones.
    func rebound(to device: AudioDeviceID) {
        queue.async { [self] in
            bind_locked(to: device)
            stalled = false
        }
    }

    func stop() {
        queue.async { [self] in stop_locked() }
    }

    // MARK: - On the monitor queue

    private func addSystemListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ event: InputRouteEvent
    ) {
        guard let token = hardware.addListener(
            object: object,
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            queue: queue,
            handler: { [weak self] in self?.debouncer?.submit(event) }
        ) else { return }
        systemTokens.append(token)
    }

    private func bind_locked(to device: AudioDeviceID) {
        for token in deviceTokens { hardware.removeListener(token) }
        deviceTokens.removeAll(keepingCapacity: true)

        let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope, InputRouteEvent)] = [
            (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, .boundDeviceFormatChanged),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, .boundDeviceFormatChanged),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, .boundDeviceDied),
        ]
        for (selector, scope, event) in watched {
            guard let token = hardware.addListener(
                object: device,
                selector: selector,
                scope: scope,
                queue: queue,
                handler: { [weak self] in self?.debouncer?.submit(event) }
            ) else { continue }
            deviceTokens.append(token)
        }
    }

    private func startWatchdog_locked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let lastCallbackUptime = self.lastCallbackUptime else { return }
            let silence = ProcessInfo.processInfo.systemUptime - lastCallbackUptime()
            guard silence > self.watchdogSilence else {
                self.stalled = false
                return
            }
            // One report per stall: the rebind resets it, and a device that
            // stays silent must not produce a new event every tick.
            guard !self.stalled else { return }
            self.stalled = true
            self.debouncer?.submit(.inputStalled)
        }
        timer.resume()
        watchdog = timer
    }

    private func stop_locked() {
        watchdog?.cancel()
        watchdog = nil
        debouncer?.cancel()
        debouncer = nil
        lastCallbackUptime = nil
        for token in systemTokens { hardware.removeListener(token) }
        systemTokens.removeAll(keepingCapacity: true)
        for token in deviceTokens { hardware.removeListener(token) }
        deviceTokens.removeAll(keepingCapacity: true)
    }
}
