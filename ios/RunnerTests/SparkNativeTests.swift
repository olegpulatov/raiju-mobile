// MODIFIED FOR RAIJU: deterministic native Spark audio and startup-fence fixtures.
import AVFoundation
import UIKit
import XCTest
@testable import Raiju

final class SparkNativeTests: XCTestCase {
  func testStartupFenceRejectsCancelledPermissionCompletion() {
    var fence = SparkStartupFence()
    let pending = fence.begin()
    XCTAssertTrue(fence.accepts(pending))
    fence.cancel()
    XCTAssertFalse(fence.accepts(pending))
  }

  func testPermissionDenialDoesNotProceedToAudioAcquisition() {
    var fence = SparkStartupFence()
    let request = fence.begin()
    XCTAssertEqual(
      fence.permissionDecision(granted: false, requestEpoch: request),
      .denied
    )
  }

  func testLatePermissionGrantAfterShutdownIsCancelled() {
    var fence = SparkStartupFence()
    let request = fence.begin()
    fence.cancel()
    XCTAssertEqual(
      fence.permissionDecision(granted: true, requestEpoch: request),
      .cancelled
    )
  }

  func testBackgroundRejectsStartAndLatePermissionCompletion() {
    XCTAssertFalse(SparkApplicationActivity.allowsStart(.background))
    XCTAssertFalse(SparkApplicationActivity.allowsPermissionCompletion(.background))
  }

  func testPermissionDialogInactiveStateDoesNotMasqueradeAsBackground() {
    XCTAssertFalse(SparkApplicationActivity.allowsStart(.inactive))
    XCTAssertTrue(SparkApplicationActivity.allowsPermissionCompletion(.inactive))
  }

  func testRegisteredBackgroundCancelsPendingStartupBeforeQueuedCompletion() {
    let center = NotificationCenter()
    let lifecycle = SparkStartupLifecycle()
    var fence = SparkStartupFence()
    let requestEpoch = lifecycle.epoch()
    XCTAssertTrue(lifecycle.begin(requestEpoch: requestEpoch))
    let permissionEpoch = fence.begin()
    var cancellations = 0
    var deferred = [() -> Void]()
    let observers = SparkLifecycleNotifications.observe(
      center: center,
      onBackground: {
        let backgroundEpoch = lifecycle.background()
        // Simulate a blocked serialized audio queue: notification arrives first.
        deferred.append {
          lifecycle.cancelPendingOnBackground(epoch: backgroundEpoch) {
            cancellations += 1
            lifecycle.cancel()
            fence.cancel()
          }
        }
      },
      onShutdown: { XCTFail("Background must not interrupt an active session") }
    )
    defer { observers.forEach { center.removeObserver($0) } }

    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertFalse(lifecycle.accepts(requestEpoch))
    XCTAssertFalse(lifecycle.finish(requestEpoch))
    deferred.removeFirst()()
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(fence.permissionDecision(granted: true, requestEpoch: permissionEpoch), .cancelled)
    XCTAssertFalse(lifecycle.begin(requestEpoch: requestEpoch))

    let runningEpoch = lifecycle.epoch()
    XCTAssertTrue(lifecycle.begin(requestEpoch: runningEpoch))
    XCTAssertTrue(lifecycle.finish(runningEpoch))
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    deferred.removeFirst()()
    XCTAssertEqual(cancellations, 1)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(cancellations, 1)
  }

  func testOldBackgroundCleanupDoesNotCancelNewForegroundStartup() {
    let lifecycle = SparkStartupLifecycle()
    let previousEpoch = lifecycle.epoch()
    XCTAssertTrue(lifecycle.begin(requestEpoch: previousEpoch))
    let backgroundEpoch = lifecycle.background()
    lifecycle.cancel()
    XCTAssertTrue(lifecycle.begin(requestEpoch: backgroundEpoch))
    var cancellations = 0
    lifecycle.cancelPendingOnBackground(epoch: backgroundEpoch) { cancellations += 1 }
    XCTAssertEqual(cancellations, 0)
    XCTAssertTrue(lifecycle.finish(backgroundEpoch))
  }

  func testRegisteredAudioNotificationsOnlyStopForActualInterruptionOrReset() {
    let center = NotificationCenter()
    var shutdowns = 0
    let observers = SparkLifecycleNotifications.observe(
      center: center,
      onBackground: { XCTFail("Unexpected background cancellation") },
      onShutdown: { shutdowns += 1 }
    )
    defer { observers.forEach { center.removeObserver($0) } }

    center.post(
      name: AVAudioSession.interruptionNotification,
      object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
    )
    XCTAssertEqual(shutdowns, 0)
    center.post(
      name: AVAudioSession.interruptionNotification,
      object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
    )
    center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    XCTAssertEqual(shutdowns, 2)
  }

  func testQueuedEventFenceRejectsDeliveryAfterShutdownGeneration() {
    let fence = SparkDeliveryFence()
    fence.set(7)
    XCTAssertTrue(fence.accepts(7))
    fence.set(8)
    XCTAssertFalse(fence.accepts(7))
  }

  func testCaptureRingMuteDropsPreMuteAudio() {
    let ring = SparkCaptureRing(slots: 2, frameCapacity: 4)
    ring.setEnabled(true)
    [Float(1), 2, 3, 4].withUnsafeBufferPointer {
      ring.tryWrite($0.baseAddress!, count: $0.count)
    }
    ring.setEnabled(false)
    XCTAssertNil(ring.read())
  }

  func testCaptureRingIsBoundedAndDropsNewestFrame() {
    let ring = SparkCaptureRing(slots: 1, frameCapacity: 2)
    ring.setEnabled(true)
    [Float(1), 2].withUnsafeBufferPointer { ring.tryWrite($0.baseAddress!, count: 2) }
    [Float(3), 4].withUnsafeBufferPointer { ring.tryWrite($0.baseAddress!, count: 2) }
    XCTAssertEqual(ring.read(), [1, 2])
    XCTAssertEqual(ring.dropped, 1)
  }


  func testPlaybackSchedulingIsBounded() {
    XCTAssertEqual(SparkAudioEngine.maximumScheduledBuffers, 8)
  }
}
