import Foundation

/// The plugin's one way to log — its own lines and PJSIP's.
///
/// `NSLog` reaches both places a developer reads: the unified log
/// (Console.app, `log collect`) and stderr (an attached debugger or
/// `devicectl … --console`). stderr is unbuffered, so a crash cannot swallow
/// the last lines. Writing to stdout as well printed every line twice.
func pjsipLog(_ message: String) {
    NSLog("%@", message as NSString)
}
