import XCTest

@testable import osasfom_cadCore

final class ExpressionTests: XCTestCase {
    private func value(_ source: String, _ variables: [String: Double] = [:]) throws -> Double {
        try Expression(source: source).value(variables: variables)
    }

    // MARK: - Arithmetic

    func testArithmeticAndPrecedence() throws {
        XCTAssertEqual(try value("1 + 2 * 3"), 7)
        XCTAssertEqual(try value("(1 + 2) * 3"), 9)
        XCTAssertEqual(try value("10 / 4"), 2.5)
        XCTAssertEqual(try value("7 % 3"), 1)
        XCTAssertEqual(try value("2 ^ 3 ^ 2"), 512, "power is right associative")
    }

    func testUnaryBindsLooserThanPower() throws {
        XCTAssertEqual(try value("-2 ^ 2"), -4)
        XCTAssertEqual(try value("2 ^ -1"), 0.5)
        XCTAssertEqual(try value("--3"), 3)
    }

    func testNumberFormats() throws {
        XCTAssertEqual(try value("1e-3"), 0.001)
        XCTAssertEqual(try value("2.5E+2"), 250)
        XCTAssertEqual(try value(".5"), 0.5)
    }

    /// The old code accepted `,` as a decimal separator, which silently changed
    /// a file's meaning between locales.
    func testCommaIsNotADecimalSeparator() {
        XCTAssertThrowsError(try value("1,5"))
    }

    // MARK: - Variables and builtins

    func testVariablesAndFunctions() throws {
        let variables = ["patch_w": 40.0, "gap": 0.5]
        XCTAssertEqual(try value("patch_w / 2", variables), 20)
        XCTAssertEqual(try value("patch_w - 2 * gap", variables), 39)
        XCTAssertEqual(try value("sqrt(16)"), 4)
        XCTAssertEqual(try value("max(1, 7, 3)"), 7)
        XCTAssertEqual(try value("clamp(15, 0, 10)"), 10)
        XCTAssertEqual(try value("sind(30)"), 0.5, accuracy: 1e-12)
    }

    func testSpeedOfLightConstantIsAvailable() throws {
        // 2.45 GHz free-space wavelength in mm.
        let wavelength = try value("c0 / (2.45e9) * 1000")
        XCTAssertEqual(wavelength, 122.365, accuracy: 0.01)
    }

    func testUnknownNamesAndBadCallsAreErrors() {
        XCTAssertThrowsError(try value("nope + 1")) { error in
            XCTAssertEqual(error as? ExpressionError, .unknownVariable("nope"))
        }
        XCTAssertThrowsError(try value("nosuchfn(1)")) { error in
            XCTAssertEqual(error as? ExpressionError, .unknownFunction("nosuchfn"))
        }
        XCTAssertThrowsError(try value("atan2(1)"))
        XCTAssertThrowsError(try value("1 / 0")) { error in
            XCTAssertEqual(error as? ExpressionError, .divisionByZero)
        }
        XCTAssertThrowsError(try value("(1 + 2"))
        XCTAssertThrowsError(try value("1 +"))
        XCTAssertThrowsError(try value("1 2"))
    }

    // MARK: - Renaming

    func testRenamingRewritesOnlyWholeIdentifiers() {
        let expression = Expression(source: "w * 2 + width - w_2 + sqrt(w)")
        let renamed = expression.renamingVariable("w", to: "patch_w")
        XCTAssertEqual(renamed.source, "patch_w * 2 + width - w_2 + sqrt(patch_w)")
    }

    func testRenamingPreservesSpacingAndSkipsFunctionNames() {
        let expression = Expression(source: "  max( a ,  b )   +a")
        XCTAssertEqual(
            expression.renamingVariable("a", to: "alpha").source,
            "  max( alpha ,  b )   +alpha"
        )
        // An identifier used as a function name is not a variable reference.
        let shadow = Expression(source: "max(1, 2)")
        XCTAssertEqual(shadow.renamingVariable("max", to: "peak").source, "max(1, 2)")
    }

    func testReferencedNamesExcludeConstantsAndFunctions() {
        let expression = Expression(source: "sqrt(patch_w) * pi + gap")
        XCTAssertEqual(expression.referencedVariableNames, ["patch_w", "gap"])
    }

    // MARK: - Formatting

    func testLiteralSourceIsLocaleIndependentAndRoundTrips() throws {
        for input in [0.0, 1.0, -42.0, 2.5, 0.000_001_5, 1.6, 1e13, 123_456.789] {
            let source = Expression.literalSource(input)
            XCTAssertFalse(source.contains(","), "\(source) must not use a comma separator")
            let parsed = try Expression(source: source).value()
            XCTAssertEqual(parsed, input, accuracy: abs(input) * 1e-6 + 1e-12)
        }
    }
}
