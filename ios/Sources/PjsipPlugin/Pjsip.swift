import Foundation

@objc public class Pjsip: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}
