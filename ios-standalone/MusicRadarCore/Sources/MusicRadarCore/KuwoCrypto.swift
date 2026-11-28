import Foundation
import JavaScriptCore

public final class KuwoCrypto {
    public static let shared = KuwoCrypto()
    private let context: JSContext?
    private let lock = NSLock()

    private init() {
        var ctx: JSContext?
        if let url = Bundle.module.url(forResource: "kwdes", withExtension: "js"),
           let src = try? String(contentsOf: url, encoding: .utf8),
           let c = JSContext() {
            c.evaluateScript(src)
            ctx = c
        }
        context = ctx
    }

    public func encryptQuery(_ query: String) -> String? {
        guard let ctx = context else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let fn = ctx.objectForKeyedSubscript("__kwEncryptQuery"), !fn.isUndefined else { return nil }
        let value = fn.call(withArguments: [query])
        return value?.toString()
    }
}
