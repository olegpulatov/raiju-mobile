// MODIFIED FOR RAIJU: native Spark voice transport and lifecycle boundary.
import AVFoundation
import Flutter
import UIKit

enum SparkApplicationActivity {
  static func allowsStart(_ state: UIApplication.State) -> Bool {
    state == .active
  }

  static func allowsPermissionCompletion(_ state: UIApplication.State) -> Bool {
    state != .background
  }
}

// Mark background immediately, even if audio.start/connect holds the state queue.
final class SparkStartupLifecycle {
  private let lock = NSLock()
  private var backgroundEpoch: UInt64 = 0
  private var pending = false
  private var pendingEpoch: UInt64 = 0

  func epoch() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return backgroundEpoch
  }

  func begin(requestEpoch: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard backgroundEpoch == requestEpoch else { return false }
    pending = true
    pendingEpoch = requestEpoch
    return true
  }

  func background() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    backgroundEpoch &+= 1
    return backgroundEpoch
  }

  func accepts(_ epoch: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending && backgroundEpoch == epoch
  }

  func finish(_ epoch: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard pending && backgroundEpoch == epoch else { return false }
    pending = false
    return true
  }

  func cancel() {
    lock.lock()
    pending = false
    lock.unlock()
  }

  func cancelPendingOnBackground(epoch: UInt64, _ cancel: () -> Void) {
    lock.lock()
    let shouldCancel = pending && pendingEpoch < epoch
    lock.unlock()
    if shouldCancel { cancel() }
  }
}

// Registered by the bridge and exercised with a private notification center in XCTest.
enum SparkLifecycleNotifications {
  static func observe(
    center: NotificationCenter,
    onBackground: @escaping () -> Void,
    onShutdown: @escaping () -> Void
  ) -> [NSObjectProtocol] {
    [
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
        onBackground()
      },
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        onShutdown()
      },
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
        onShutdown()
      }
    ]
  }
}

final class SparkDeliveryFence {
  private let lock = NSLock()
  private var epoch: UInt64 = 0

  func set(_ value: UInt64) {
    lock.lock()
    epoch = value
    lock.unlock()
  }

  func accepts(_ value: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return epoch == value
  }
}

final class SparkNativeBridge: NSObject, FlutterStreamHandler {
  static let methodChannelName = "raiju/spark/methods"
  static let eventChannelName = "raiju/spark/events"

  private let audio: SparkAudioEngine
  private let stateQueue = DispatchQueue(label: "app.raiju.spark.native")
  private var eventSink: FlutterEventSink?
  private var handle: UInt64 = 0
  private var startupFence = SparkStartupFence()
  private let startupLifecycle = SparkStartupLifecycle()
  private var pollTimer: DispatchSourceTimer?
  private var observers: [NSObjectProtocol] = []
  private let deliveryFence = SparkDeliveryFence()

  init(messenger: FlutterBinaryMessenger, audio: SparkAudioEngine = SparkAudioEngine()) {
    self.audio = audio
    super.init()
    let methods = FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    let events = FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)
    observeShutdownBoundaries()
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    audio.stop()
    if handle != 0 { spark_destroy(handle) }
  }

  func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    DispatchQueue.main.async {
      self.eventSink = eventSink
    }
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    DispatchQueue.main.async {
      self.eventSink = nil
    }
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start": start(arguments: call.arguments, result: result)
    case "stop":
      stateQueue.async {
        self.shutdownLocked(emitClosed: true)
        DispatchQueue.main.async { result(nil) }
      }
    case "setMuted":
      guard let args = call.arguments as? [String: Any], let muted = args["muted"] as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Spark mute requires a boolean.", details: nil)); return
      }
      stateQueue.async {
        let sessionEpoch = self.startupFence.epoch
        self.audio.setMuted(muted) { [weak self] in
          self?.stateQueue.async {
            guard let self, self.startupFence.accepts(sessionEpoch), self.handle != 0 else {
              DispatchQueue.main.async { result(nil) }
              return
            }
            guard self.command(["type": "setMuted", "muted": muted]) else {
              self.shutdownLocked(emitClosed: false)
              DispatchQueue.main.async {
                result(FlutterError(code: "spark_error", message: "Spark could not update microphone state.", details: nil))
              }
              return
            }
            DispatchQueue.main.async { result(nil) }
          }
        }
      }
    case "sendText":
      guard var args = call.arguments as? [String: Any], args["text"] is String else {
        result(FlutterError(code: "invalid_arguments", message: "Spark text is required.", details: nil)); return
      }
      args["type"] = "sendText"
      stateQueue.async { self.finishCommand(args, result: result) }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func start(arguments: Any?, result: @escaping FlutterResult) {
    guard SparkApplicationActivity.allowsStart(UIApplication.shared.applicationState) else {
      result(FlutterError(code: "app_inactive", message: "Bring Raiju to the foreground before starting Spark.", details: nil))
      return
    }
    guard var args = arguments as? [String: Any], args["accessToken"] is String else {
      result(FlutterError(code: "invalid_arguments", message: "Spark credentials are unavailable.", details: nil))
      return
    }
    let applicationEpoch = startupLifecycle.epoch()
    stateQueue.async {
      self.shutdownLocked(emitClosed: false)
      guard self.startupLifecycle.begin(requestEpoch: applicationEpoch) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "start_cancelled", message: "Spark start was cancelled in the background.", details: nil))
        }
        return
      }
      let requestedEpoch = self.startupFence.begin()
      self.deliveryFence.set(requestedEpoch)
      let permission: (@escaping (Bool) -> Void) -> Void = { completion in
        if #available(iOS 17.0, *) {
          AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
          AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
      }
      permission { [weak self] granted in
        guard let self else { return }
        DispatchQueue.main.async {
          let applicationState = UIApplication.shared.applicationState
          self.stateQueue.async {
            guard SparkApplicationActivity.allowsPermissionCompletion(applicationState),
                  self.startupLifecycle.accepts(applicationEpoch) else {
              if self.startupFence.accepts(requestedEpoch) {
                self.shutdownLocked(emitClosed: false)
              }
              DispatchQueue.main.async {
                result(FlutterError(code: "start_cancelled", message: "Spark start was cancelled in the background.", details: nil))
              }
              return
            }
          switch self.startupFence.permissionDecision(
            granted: granted,
            requestEpoch: requestedEpoch
          ) {
          case .cancelled:
            DispatchQueue.main.async {
              result(FlutterError(code: "start_cancelled", message: "Spark start was cancelled.", details: nil))
            }
            return
          case .denied:
            DispatchQueue.main.async {
              result(FlutterError(code: "microphone_denied", message: "Microphone permission is required to start Spark.", details: nil))
            }
            return
          case .proceed:
            break
          }
          guard self.startupLifecycle.accepts(applicationEpoch) else {
            self.cancelBackgroundStart(result: result)
            return
          }
          self.handle = spark_create()
          let createdHandle = self.handle
          guard createdHandle != 0 else {
            self.failStart("Spark could not initialize.", result: result)
            return
          }
          do {
            try self.audio.start(
              push: { samples in
                samples.withUnsafeBufferPointer {
                  spark_push_audio(createdHandle, $0.baseAddress, $0.count)
                }
              },
              pull: { output in
                spark_read_audio(createdHandle, output.baseAddress, output.count)
              },
              failure: { [weak self] in
                self?.stateQueue.async {
                  guard let self, self.startupFence.accepts(requestedEpoch) else { return }
                  self.shutdownLocked(emitClosed: false)
                  self.deliver(
                    ["type": "error", "message": "Spark audio conversion failed."],
                    sessionEpoch: self.startupFence.epoch
                  )
                }
              }
            )
          } catch {
            self.failStart("Spark audio could not start.", result: result)
            return
          }
          guard self.startupLifecycle.accepts(applicationEpoch) else {
            self.cancelBackgroundStart(result: result)
            return
          }
          args["type"] = "connect"
          guard self.command(args) else {
            self.failStart("Spark could not connect.", result: result)
            return
          }
          self.startPolling(epoch: requestedEpoch)
          guard self.startupLifecycle.finish(applicationEpoch) else {
            self.cancelBackgroundStart(result: result)
            return
          }
          DispatchQueue.main.async { result(nil) }
        }
      }
    }
  }
  }

  private func finishCommand(_ object: [String: Any], result: @escaping FlutterResult) {
    guard handle != 0 else {
      DispatchQueue.main.async { result(FlutterError(code: "not_started", message: "Spark is not running.", details: nil)) }; return
    }
    let ok = command(object)
    DispatchQueue.main.async {
      ok ? result(nil) : result(FlutterError(code: "spark_error", message: "Spark rejected the request.", details: nil))
    }
  }

  @discardableResult private func command(_ object: [String: Any]) -> Bool {
    guard handle != 0, JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let json = String(data: data, encoding: .utf8) else { return false }
    let pointer = json.withCString { spark_command(handle, $0) }
    guard let pointer else { return false }
    defer { spark_string_free(pointer) }
    guard let data = String(cString: pointer).data(using: .utf8),
          let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return response["ok"] as? Bool == true
  }

  private func startPolling(epoch: UInt64) {
    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in self?.poll(epoch: epoch) }
    pollTimer = timer
    timer.resume()
  }

  private func poll(epoch: UInt64) {
    guard startupFence.accepts(epoch), handle != 0 else { return }
    while let pointer = spark_poll_event(handle) {
      defer { spark_string_free(pointer) }
      let json = String(cString: pointer)
      if json == "null" { break }
      guard let data = json.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      if event["type"] as? String == "closed" || event["type"] as? String == "error" {
        shutdownLocked(emitClosed: false)
        deliver(event, sessionEpoch: startupFence.epoch)
        break
      }
      deliver(event, sessionEpoch: epoch)
    }
  }

  // Audio calls use the captured handle directly on the serialized audio worker.
  // Rust defines stale handles as safe no-ops, so teardown cannot create a lock cycle
  // or an unbounded dispatch backlog.

  func shutdown(emitClosed: Bool = true) { stateQueue.async { self.shutdownLocked(emitClosed: emitClosed) } }

  private func shutdownLocked(emitClosed: Bool) {
    startupLifecycle.cancel()
    startupFence.cancel()
    deliveryFence.set(startupFence.epoch)
    pollTimer?.cancel(); pollTimer = nil
    audio.stop()
    if handle != 0 { _ = command(["type": "stop"]); spark_destroy(handle); handle = 0 }
    if emitClosed { deliver(["type": "closed"], sessionEpoch: startupFence.epoch) }
  }


  private func deliver(_ event: [String: Any], sessionEpoch: UInt64?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, sessionEpoch == nil || self.deliveryFence.accepts(sessionEpoch!) else { return }
      self.eventSink?(event)
    }
  }

  private func failStart(_ message: String, result: @escaping FlutterResult) {
    shutdownLocked(emitClosed: false)
    DispatchQueue.main.async { result(FlutterError(code: "spark_start_failed", message: message, details: nil)) }
  }

  private func cancelBackgroundStart(result: @escaping FlutterResult) {
    shutdownLocked(emitClosed: false)
    DispatchQueue.main.async {
      result(FlutterError(code: "start_cancelled", message: "Spark start was cancelled in the background.", details: nil))
    }
  }

  private func observeShutdownBoundaries() {
    observers = SparkLifecycleNotifications.observe(
      center: .default,
      onBackground: { [weak self] in
        guard let self else { return }
        let backgroundEpoch = self.startupLifecycle.background()
        self.stateQueue.async { [weak self] in
          guard let self else { return }
          self.startupLifecycle.cancelPendingOnBackground(epoch: backgroundEpoch) {
            self.shutdownLocked(emitClosed: false)
          }
        }
      },
      onShutdown: { [weak self] in self?.shutdown() }
    )
  }
}
