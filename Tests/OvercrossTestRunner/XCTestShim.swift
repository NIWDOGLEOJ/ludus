import Foundation

open class XCTestCase: @unchecked Sendable {
    public init() {}
    open func setUp() throws {}
    open func tearDown() throws {}
}

nonisolated(unsafe) public var testFailuresCount = 0

public struct XCTUnwrapError: Error {}

public func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    let value = try expression()
    guard let unwrapped = value else {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTUnwrap failed: expected non-nil - \(message())")
        throw XCTUnwrapError()
    }
    return unwrapped
}

public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: ((Error) -> Void)? = nil
) {
    do {
        _ = try expression()
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertThrowsError failed: did not throw - \(message())")
    } catch {
        errorHandler?(error)
    }
}

public func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T?,
    _ expression2: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let val1 = try expression1()
        let val2 = try expression2()
        if val1 != val2 {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertEqual failed: (\"\(String(describing: val1))\") is not equal to (\"\(String(describing: val2))\") - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertEqual threw error: \(error) - \(message())")
    }
}

public func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T?,
    _ expression2: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let val1 = try expression1()
        let val2 = try expression2()
        if val1 == val2 {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertNotEqual failed: (\"\(String(describing: val1))\") is equal to (\"\(String(describing: val2))\") - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertNotEqual threw error: \(error) - \(message())")
    }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T?,
    _ expression2: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        guard let val1 = try expression1(), let val2 = try expression2() else {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertGreaterThanOrEqual failed: nil operand")
            return
        }
        if val1 < val2 {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertGreaterThanOrEqual failed: (\(val1)) is less than (\(val2)) - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertGreaterThanOrEqual threw error: \(error) - \(message())")
    }
}

public func XCTAssertGreaterThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T?,
    _ expression2: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        guard let val1 = try expression1(), let val2 = try expression2() else {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertGreaterThan failed: nil operand")
            return
        }
        if val1 <= val2 {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertGreaterThan failed: (\(val1)) is not greater than (\(val2)) - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertGreaterThan threw error: \(error) - \(message())")
    }
}


public func XCTAssertLessThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T?,
    _ expression2: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        guard let val1 = try expression1(), let val2 = try expression2() else {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertLessThanOrEqual failed: nil operand")
            return
        }
        if val1 > val2 {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertLessThanOrEqual failed: (\(val1)) is greater than (\(val2)) - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertLessThanOrEqual threw error: \(error) - \(message())")
    }
}

public func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if try !expression() {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertTrue failed - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertTrue threw error: \(error) - \(message())")
    }
}

public func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if try expression() {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertFalse failed - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertFalse threw error: \(error) - \(message())")
    }
}

public func XCTAssertNil(
    _ expression: @autoclosure () throws -> Any?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if let val = try expression() {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertNil failed: (\(val)) is not nil - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertNil threw error: \(error) - \(message())")
    }
}

public func XCTAssertNotNil(
    _ expression: @autoclosure () throws -> Any?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if try expression() == nil {
            testFailuresCount += 1
            print("[\(file):\(line)] XCTAssertNotNil failed: value is nil - \(message())")
        }
    } catch {
        testFailuresCount += 1
        print("[\(file):\(line)] XCTAssertNotNil threw error: \(error) - \(message())")
    }
}

public func XCTFail(
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    testFailuresCount += 1
    print("[\(file):\(line)] XCTFail: \(message)")
}
