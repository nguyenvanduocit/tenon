import CryptoKit
import Foundation
import XCTest
@testable import TenonIntentCore

final class IntentValueTests: XCTestCase {
    func testDecodesEveryOwnedJSONValueKind() throws {
        let data = Data(
            """
            {
              "array": [null, true, 42, 1.5, "tenon"],
              "object": {"ready": false}
            }
            """.utf8
        )

        let value = try IntentValue(jsonData: data)

        XCTAssertEqual(
            value,
            .object([
                "array": .array([
                    .null,
                    .bool(true),
                    .integer(42),
                    .number(1.5),
                    .string("tenon"),
                ]),
                "object": .object(["ready": .bool(false)]),
            ])
        )
    }

    func testCanonicalJSONSortsObjectKeysAndHasStableDigest() throws {
        let value: IntentValue = .object([
            "b": .integer(2),
            "a": .integer(1),
        ])

        let data = try value.canonicalJSONData()

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":1,"b":2}"#)
        XCTAssertEqual(
            try value.canonicalSHA256Digest().hex,
            "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777"
        )
    }

    func testAccountingReportsEncodedBytesDepthAndValueCount() throws {
        let value: IntentValue = .object([
            "items": .array([.integer(1), .string("two")]),
        ])

        let accounting = try value.accounting()

        XCTAssertEqual(accounting.encodedBytes, 19)
        XCTAssertEqual(accounting.maximumDepth, 3)
        XCTAssertEqual(accounting.valueCount, 4)
    }

    func testRejectsValuesThatExceedEachStructuralBudget() throws {
        let nested: IntentValue = .array([.array([.integer(1)])])
        let tooManyValues: IntentValue = .array([.integer(1), .integer(2)])
        let tooManyEntries: IntentValue = .object(["a": .null, "b": .null])
        let longString: IntentValue = .string("12345")

        XCTAssertThrowsError(
            try nested.validate(
                limits: IntentValueLimits(
                    maxEncodedBytes: 64,
                    maxDepth: 2,
                    maxValueCount: 8,
                    maxCollectionCount: 8,
                    maxStringBytes: 64,
                    maxObjectKeyBytes: 64
                )
            )
        ) { error in
            XCTAssertEqual(error as? IntentValueError, .maximumDepthExceeded(limit: 2))
        }

        XCTAssertThrowsError(
            try tooManyValues.validate(
                limits: IntentValueLimits(
                    maxEncodedBytes: 64,
                    maxDepth: 8,
                    maxValueCount: 2,
                    maxCollectionCount: 8,
                    maxStringBytes: 64,
                    maxObjectKeyBytes: 64
                )
            )
        ) { error in
            XCTAssertEqual(error as? IntentValueError, .maximumValueCountExceeded(limit: 2))
        }

        XCTAssertThrowsError(
            try tooManyEntries.validate(
                limits: IntentValueLimits(
                    maxEncodedBytes: 64,
                    maxDepth: 8,
                    maxValueCount: 8,
                    maxCollectionCount: 1,
                    maxStringBytes: 64,
                    maxObjectKeyBytes: 64
                )
            )
        ) { error in
            XCTAssertEqual(error as? IntentValueError, .maximumCollectionCountExceeded(limit: 1))
        }

        XCTAssertThrowsError(
            try longString.validate(
                limits: IntentValueLimits(
                    maxEncodedBytes: 64,
                    maxDepth: 8,
                    maxValueCount: 8,
                    maxCollectionCount: 8,
                    maxStringBytes: 4,
                    maxObjectKeyBytes: 64
                )
            )
        ) { error in
            XCTAssertEqual(error as? IntentValueError, .maximumStringBytesExceeded(limit: 4))
        }
    }

    func testRejectsOversizedJSONBeforeDecoding() {
        let data = Data(#""12345""#.utf8)
        let limits = IntentValueLimits(
            maxEncodedBytes: 4,
            maxDepth: 8,
            maxValueCount: 8,
            maxCollectionCount: 8,
            maxStringBytes: 64,
            maxObjectKeyBytes: 64
        )

        XCTAssertThrowsError(try IntentValue(jsonData: data, limits: limits)) { error in
            XCTAssertEqual(error as? IntentValueError, .maximumEncodedBytesExceeded(limit: 4))
        }
    }

    func testRejectsNonFiniteNumbers() {
        XCTAssertThrowsError(try IntentValue.number(.infinity).validate()) { error in
            XCTAssertEqual(error as? IntentValueError, .nonFiniteNumber)
        }
    }

    func testDefaultAndHardPayloadBudgetsMatchTheADR() {
        XCTAssertEqual(IntentValueLimits.default.maxEncodedBytes, 64 * 1024)
        XCTAssertEqual(IntentValueLimits.hardMaximumEncodedBytes, 1024 * 1024)
    }
}
