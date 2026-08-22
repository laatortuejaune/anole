import Testing
import Foundation
@testable import AnoleCore

@Suite("Error codes")
struct ErrorCodeTests {

    @Test("Every error carries a unique code")
    func codesAreUnique() {
        let errors: [AnoleError] = [
            .toolingMissing("x"), .helperMissing, .pairingFileMissing,
            .noDeviceFound, .deviceNotPaired("x"), .developerModeDisabled,
            .developerImageUnavailable("x"),
            .tunnelFailed("x"), .connectionLost("x"), .notPrepared,
            .helperCrashed(1, "x"), .helperTimeout("x"), .helperUnreadable("x"),
            .serviceUnavailable("x"), .locationRejected("x"), .invalidCoordinate,
            .locationDenied, .locationReducedAccuracy, .locationTooImprecise(50),
            .locationUnavailable("x"),
            .routeNotFound, .routeTimedOut, .routeFailed("x"),
            .noDestination, .noOrigin,
            .commandFailed("c", 1, "o"), .unsupported("x"),
        ]
        let codes = errors.map(\.code)
        #expect(Set(codes).count == codes.count, "duplicate codes")
    }

    @Test("Codes are grouped by domain")
    func codesAreGrouped() {
        #expect(AnoleError.helperMissing.code / 100 == 1)
        #expect(AnoleError.noDeviceFound.code / 100 == 2)
        #expect(AnoleError.tunnelFailed("x").code / 100 == 3)
        #expect(AnoleError.invalidCoordinate.code / 100 == 4)
        #expect(AnoleError.locationDenied.code / 100 == 5)
        #expect(AnoleError.routeNotFound.code / 100 == 6)
    }

    @Test("The displayed message starts with the code, so it can be quoted")
    func messageStartsWithCode() {
        let text = AnoleError.locationDenied.errorDescription ?? ""
        #expect(text.hasPrefix("[501]"), "message: \(text)")
    }

    @Test("The technical detail is kept when there is one")
    func keepsDetail() {
        #expect(AnoleError.tunnelFailed("connection refused").detail == "connection refused")
        #expect(AnoleError.locationTooImprecise(1200).detail == "±1200 m")
        #expect(AnoleError.invalidCoordinate.detail == nil)
    }

    @Test("Actionable errors offer advice")
    func actionableErrorsAdvise() {
        for error in [AnoleError.locationDenied, .developerModeDisabled,
                      .noDeviceFound, .pairingFileMissing, .notPrepared] {
            #expect(error.advice != nil, "code \(error.code) without advice")
        }
    }

    @Test("The full message includes code, summary and detail")
    func fullDescription() {
        let text = AnoleError.commandFailed("usbmux list", 2, "nothing").fullDescription
        #expect(text.contains("[901]"))
        #expect(text.contains("usbmux list"))
        #expect(text.contains("code 2"))
    }
}
