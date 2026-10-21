import FitnessCore
import Foundation
@preconcurrency import HealthKit
import XCTest

final class WatchCallbackBoundaryTests: XCTestCase {
    @MainActor
    func testMirrorCompletionFromDetachedTaskReachesMainActorForSuccessAndFailure() async {
        let success = expectation(description: "mirrored send succeeds")
        let failure = expectation(description: "mirrored send fails")
        let successCallback = CompanionCallbackBoundary.mirrorSendHandler { didSend, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(didSend)
            XCTAssertNil(error)
            success.fulfill()
        }
        let failureCallback = CompanionCallbackBoundary.mirrorSendHandler { didSend, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(didSend)
            XCTAssertEqual(error, "mirror unavailable")
            failure.fulfill()
        }

        await Task.detached {
            successCallback(true, nil)
            failureCallback(
                false,
                NSError(
                    domain: "WatchCallbackBoundaryTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "mirror unavailable"]))
        }.value
        await fulfillment(of: [success, failure], timeout: 3)
    }

    func testProductionHealthQueryHandlersResumeWhenInvokedFromDetachedTasks() async throws {
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let callback = WatchHealthQueryCallbacks.workouts(continuation)
            Task.detached {
                let query = HKSampleQuery(
                    sampleType: .workoutType(), predicate: nil, limit: 1,
                    sortDescriptors: nil, resultsHandler: callback)
                callback(query, nil, nil)
            }
        }
        XCTAssertTrue(workouts.isEmpty)

        let heart: ([HKQuantitySample], HKQueryAnchor?) = try await withCheckedThrowingContinuation {
            continuation in
            let callback = WatchHealthQueryCallbacks.heartSamples(continuation)
            Task.detached {
                let query = HKAnchoredObjectQuery(
                    type: HKQuantityType(.heartRate), predicate: nil,
                    anchor: nil, limit: 1, resultsHandler: callback)
                callback(query, nil, nil, nil, nil)
            }
        }
        XCTAssertTrue(heart.0.isEmpty)
        XCTAssertNil(heart.1)
    }

    func testProductionHealthQueryHandlersPreserveErrorsFromDetachedTasks() async {
        do {
            let _: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
                let callback = WatchHealthQueryCallbacks.workouts(continuation)
                Task.detached {
                    let query = HKSampleQuery(
                        sampleType: .workoutType(), predicate: nil, limit: 1,
                        sortDescriptors: nil, resultsHandler: callback)
                    callback(query, nil, NSError(domain: "WatchSampleQuery", code: 41))
                }
            }
            XCTFail("Expected sample query error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "WatchSampleQuery")
            XCTAssertEqual((error as NSError).code, 41)
        }

        do {
            let _: ([HKQuantitySample], HKQueryAnchor?) = try await withCheckedThrowingContinuation {
                continuation in
                let callback = WatchHealthQueryCallbacks.heartSamples(continuation)
                Task.detached {
                    let query = HKAnchoredObjectQuery(
                        type: HKQuantityType(.heartRate), predicate: nil,
                        anchor: nil, limit: 1, resultsHandler: callback)
                    callback(query, nil, nil, nil, NSError(domain: "WatchAnchoredQuery", code: 42))
                }
            }
            XCTFail("Expected anchored query error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "WatchAnchoredQuery")
            XCTAssertEqual((error as NSError).code, 42)
        }
    }
}
