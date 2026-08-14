import Foundation
import WebKit
import QwaveSupport

/// Applies the resolved shields policy to a web view's content-rule lists.
/// Rule lists are configuration-wide, so per-site enable/disable is done the
/// way Safari's own per-site "content blockers off" works: adjusted on the
/// user-content controller at main-frame navigation time, before the policy
/// decision is returned.
@MainActor
public final class ShieldsDirector {
    public let compiler: RuleListCompiler
    public let policy: ShieldsPolicy

    private var adsList: WKContentRuleList?
    private var httpsUpgradeList: WKContentRuleList?

    /// The exact list OBJECTS last attached to each controller, so a navigation
    /// whose resolved attachment is unchanged skips the remove-all + re-add.
    /// Weak key so a controller that goes away drops its entry automatically.
    private let lastApplied = NSMapTable<WKUserContentController, NSArray>.weakToStrongObjects()

    public init(compiler: RuleListCompiler, policy: ShieldsPolicy) {
        self.compiler = compiler
        self.policy = policy
    }

    /// Makes both built-in lists available fast (idempotent). On a list
    /// update this returns the previous compiled version immediately and
    /// swaps in the fresh one when its background compile finishes — new
    /// navigations reconcile via `applyLists`, so the swap needs no push.
    public func prepare() async {
        do {
            adsList = try await compiler.availableList(for: .adsAndTrackers) { [weak self] fresh in
                self?.adsList = fresh
            }
            httpsUpgradeList = try await compiler.availableList(for: .httpsUpgrade) { [weak self] fresh in
                self?.httpsUpgradeList = fresh
            }
        } catch {
            QwaveLog.shields.error("Rule list compilation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Installs the correct rule lists for a navigation to `host`.
    /// Safe to call repeatedly; it reconciles rather than appends.
    public func applyLists(to controller: WKUserContentController, forHost host: String?) {
        // P0 instrumentation: runs on the synchronous navigation-decision path
        // for every main-frame load. The interval's slow-path event count is
        // the redundant-rebuild signal the cache fix targets. See docs/PERF.md.
        let signpostID = QwaveSignposts.shields.makeSignpostID()
        let interval = QwaveSignposts.shields.beginInterval("applyLists", id: signpostID)
        defer { QwaveSignposts.shields.endInterval("applyLists", interval) }

        let resolved = policy.resolvedPolicy(forHost: host)
        var desired: [WKContentRuleList] = []
        if resolved.adsBlocked, let adsList {
            desired.append(adsList)
        }
        if resolved.httpsFirst, let httpsUpgradeList {
            desired.append(httpsUpgradeList)
        }

        // Fast path: the identical set of list OBJECTS is already attached — the
        // remove-all + re-add would be a no-op change, so skip it. This is keyed
        // on WKContentRuleList object identity, never on the policy bools: the
        // built-in lists start nil and swap to a freshly compiled object when
        // prepare()'s background compile finishes, so a bool cache would freeze
        // "ads on" while the list was still nil and never attach the real one.
        if let cached = lastApplied.object(forKey: controller) as? [WKContentRuleList],
            cached.count == desired.count,
            zip(cached, desired).allSatisfy({ $0 === $1 })
        {
            return
        }

        QwaveSignposts.shields.emitEvent("ruleListRebuild", id: signpostID)
        controller.removeAllContentRuleLists()
        for list in desired {
            controller.add(list)
        }
        lastApplied.setObject(desired as NSArray, forKey: controller)
    }

    /// Initial installation for a fresh configuration (before first navigation).
    public func installDefaultLists(on controller: WKUserContentController) {
        applyLists(to: controller, forHost: nil)
    }
}
