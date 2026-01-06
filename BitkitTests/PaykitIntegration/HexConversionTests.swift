//
//  HexConversionTests.swift
//  BitkitTests
//
//  Tests for hex-to-binary conversion to verify the noise key storage bug fix.
//

import XCTest
@testable import Bitkit

final class HexConversionTests: XCTestCase {
    
    /// Verify that hexaData produces the correct 32-byte output for a 64-char hex string
    func testHexToDataProduces32Bytes() {
        let hexKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let data = hexKey.hexaData
        XCTAssertEqual(data.count, 32, "64-char hex should decode to 32 bytes")
    }
    
    /// Verify that UTF-8 encoding produces the WRONG 64-byte output (this is the bug we fixed)
    func testUTF8ConversionProduces64Bytes() {
        let hexKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let data = hexKey.data(using: .utf8)!
        XCTAssertEqual(data.count, 64, "UTF-8 encoding of 64-char hex gives 64 bytes (WRONG for crypto)")
    }
    
    /// Verify round-trip hex encoding/decoding
    func testHexRoundTrip() {
        let original = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
        let hex = original.hex
        let restored = hex.hexaData
        XCTAssertEqual(original, restored, "Round-trip should preserve bytes")
    }
    
    /// Verify that hexaBytes produces correct byte array
    func testHexaBytes() {
        let hex = "01234567"
        let bytes = hex.hexaBytes
        XCTAssertEqual(bytes, [0x01, 0x23, 0x45, 0x67])
    }
    
    /// Verify that empty string produces empty data
    func testEmptyHexString() {
        let hex = ""
        let data = hex.hexaData
        XCTAssertEqual(data.count, 0)
    }
    
    /// Verify X25519 key length requirements
    func testX25519KeyLength() {
        // X25519 keys are 32 bytes = 64 hex characters
        let validHexKey = String(repeating: "a", count: 64)
        let data = validHexKey.hexaData
        XCTAssertEqual(data.count, 32, "X25519 key should be 32 bytes")
    }
}

