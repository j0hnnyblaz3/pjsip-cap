import Foundation

/// The plugin's one way to log — its own lines and PJSIP's.
///
/// Writes to both places a developer reads: `NSLog` (the unified log —
/// Console.app, `log collect`) and stdout (an attached debugger or
/// `devicectl … --console`). NSLog alone never reaches an attached console,
/// and `print` alone never reaches the unified log; mixing them per call site
/// is how PJSIP's SIP messages went missing from call traces. stdout is
/// flushed per line so a crash cannot swallow the last messages.
func pjsipLog(_ message: String) {
    NSLog("%@", message as NSString)
    print(message)
    fflush(stdout)
}
