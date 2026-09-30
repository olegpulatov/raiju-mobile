// MODIFIED FOR RAIJU: ephemeral full-duplex Spark audio. No audio is recorded to files.
import AVFoundation
import Foundation
import os.lock

struct SparkStartupFence {
  private(set) var epoch: UInt64 = 0
  mutating func begin() -> UInt64 { epoch &+= 1; return epoch }
  mutating func cancel() { epoch &+= 1 }
  func accepts(_ candidate: UInt64) -> Bool { candidate == epoch }
}

enum SparkPermissionDecision: Equatable {
  case proceed
  case denied
  case cancelled
}

extension SparkStartupFence {
  func permissionDecision(granted: Bool, requestEpoch: UInt64) -> SparkPermissionDecision {
    guard accepts(requestEpoch) else { return .cancelled }
    return granted ? .proceed : .denied
  }
}

final class SparkCaptureRing {
  private var lock = os_unfair_lock_s()
  private var storage: [[Float]]
  private var lengths: [Int]
  private var readIndex = 0
  private var writeIndex = 0
  private(set) var dropped = 0
  private let frameCapacity: Int
  private var enabled = false

  init(slots: Int = 8, frameCapacity: Int = 4096) {
    self.frameCapacity = frameCapacity
    storage = (0..<(slots + 1)).map { _ in Array(repeating: 0, count: frameCapacity) }
    lengths = Array(repeating: 0, count: slots + 1)
  }

  func setEnabled(_ value: Bool) {
    os_unfair_lock_lock(&lock); enabled = value
    if !value { readIndex = writeIndex }
    os_unfair_lock_unlock(&lock)
  }

  // Called by the realtime input tap: never waits for a contended lock or allocates.
  func tryWrite(_ source: UnsafePointer<Float>, count: Int) {
    guard os_unfair_lock_trylock(&lock) else { return }
    defer { os_unfair_lock_unlock(&lock) }
    guard enabled else { return }
    let next = (writeIndex + 1) % storage.count
    guard next != readIndex else { dropped += 1; return }
    let amount = min(count, frameCapacity)
    storage[writeIndex].withUnsafeMutableBufferPointer { destination in
      destination.baseAddress?.update(from: source, count: amount)
    }
    lengths[writeIndex] = amount
    writeIndex = next
  }

  func read() -> [Float]? {
    os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
    guard readIndex != writeIndex else { return nil }
    let result = Array(storage[readIndex].prefix(lengths[readIndex]))
    readIndex = (readIndex + 1) % storage.count
    return result
  }
}

final class SparkAudioEngine {
  static let inputRate = 16_000.0
  static let outputRate = 48_000.0
  static let maximumScheduledBuffers = 8

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let session: AVAudioSession
  private let capture = SparkCaptureRing()
  private let workQueue = DispatchQueue(label: "app.raiju.spark.audio")
  private var timer: DispatchSourceTimer?
  private var push: (([Float]) -> Void)?
  private var pull: ((UnsafeMutableBufferPointer<Float>) -> Int)?
  private var failure: (() -> Void)?
  private var running = false
  private var muted = false
  private var scheduled = 0
  private var hardwareInputRate = 48_000.0
  private var generation: UInt64 = 0
  private var inputConverter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var captureTapInstalled = false

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
    engine.attach(player)
  }

  func start(push: @escaping ([Float]) -> Void,
             pull: @escaping (UnsafeMutableBufferPointer<Float>) -> Int,
             failure: @escaping () -> Void) throws {
    stop()
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
    try session.setPreferredSampleRate(Self.outputRate)
    try session.setPreferredIOBufferDuration(0.02)
    try session.setActive(true)
    self.push = push; self.pull = pull; self.failure = failure; muted = false
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0, format.sampleRate > 0 else { throw SparkAudioError.unavailable }
    hardwareInputRate = format.sampleRate
    capture.setEnabled(true)
    guard let converterSource = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: hardwareInputRate,
      channels: 1,
      interleaved: false
    ), let converterTarget = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Self.inputRate,
      channels: 1,
      interleaved: false
    ), let converter = AVAudioConverter(from: converterSource, to: converterTarget) else {
      throw SparkAudioError.unavailable
    }
    converterInputFormat = converterSource
    inputConverter = converter
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [capture] buffer, _ in
      guard let channels = buffer.floatChannelData else { return }
      capture.tryWrite(channels[0], count: Int(buffer.frameLength))
    }
    captureTapInstalled = true
    guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false) else {
      throw SparkAudioError.unavailable
    }
    engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    engine.prepare(); try engine.start(); player.play(); running = true

    let timer = DispatchSource.makeTimerSource(queue: workQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(3))
    timer.setEventHandler { [weak self] in self?.serviceAudio() }
    self.timer = timer; timer.resume()
  }

  func setMuted(_ value: Bool, completion: @escaping () -> Void) {
    capture.setEnabled(!value)
    workQueue.async {
      self.muted = value
      if value { while self.capture.read() != nil {} }
      if value { self.inputConverter?.reset() }
      completion()
    }
  }

  func stop() {
    capture.setEnabled(false)
    workQueue.sync {
      generation &+= 1
      timer?.cancel(); timer = nil
      if captureTapInstalled {
        engine.inputNode.removeTap(onBus: 0)
        captureTapInstalled = false
      }
      player.stop(); engine.stop(); engine.reset()
      push = nil; pull = nil; failure = nil
      scheduled = 0; running = false
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func serviceAudio() {
    guard running else { return }
    if !muted {
      while let captured = capture.read() {
        guard let converted = convertCapture(captured) else {
          running = false
          failure?()
          return
        }
        if !converted.isEmpty { push?(converted) }
      }
    }
    guard scheduled < Self.maximumScheduledBuffers,
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960),
          let channel = buffer.floatChannelData?.pointee else { return }
    let count = UnsafeMutableBufferPointer(start: channel, count: 960)
    let received = pull?(count) ?? 0
    guard received > 0 else { return }
    buffer.frameLength = AVAudioFrameCount(min(received, 960)); scheduled += 1
    let scheduledGeneration = generation
    player.scheduleBuffer(buffer) { [weak self] in
      self?.workQueue.async {
        guard let self, self.generation == scheduledGeneration else { return }
        self.scheduled = max(0, self.scheduled - 1)
      }
    }
  }

  private func convertCapture(_ samples: [Float]) -> [Float]? {
    guard let converter = inputConverter, let sourceFormat = converterInputFormat,
          let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
          ), let inputChannel = input.floatChannelData?.pointee else { return nil }
    input.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
      guard let source = $0.baseAddress else { return }
      inputChannel.update(from: source, count: $0.count)
    }
    let capacity = AVAudioFrameCount(ceil(Double(samples.count) * Self.inputRate / hardwareInputRate) + 32)
    guard let output = AVAudioPCMBuffer(
      pcmFormat: converter.outputFormat,
      frameCapacity: capacity
    ) else { return nil }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }
    guard status != .error, error == nil, let channel = output.floatChannelData?.pointee else {
      return nil
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
  }

}

enum SparkAudioError: Error { case unavailable }
