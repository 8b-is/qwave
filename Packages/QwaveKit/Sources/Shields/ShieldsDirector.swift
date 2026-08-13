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
        let resolved = policy.resolvedPolicy(forHost: host)
        controller.removeAllContentRuleLists()
        if resolved.adsBlocked, let adsList {
            controller.add(adsList)
        }
        if resolved.httpsFirst, let httpsUpgradeList {
            controller.add(httpsUpgradeList)
        }
    }

    /// Initial installation for a fresh configuration (before first navigation).
    public func installDefaultLists(on controller: WKUserContentController) {
        applyLists(to: controller, forHost: nil)
    }
}
