import Combine
import Foundation

/// Best-effort check for a newer published release on GitHub. One unauthenticated
/// request to `releases/latest` (the canonical "newest stable"), gated to once
/// per 24h in `UserDefaults`, re-evaluated hourly so a transient failure
/// self-heals without a relaunch. Automatic checks are silent and suppressed in
/// `#if DEBUG`; a manual check surfaces its result. We never auto-update — the
/// menu just links to the release page. Mirrors blue-switch's UpdateChecker.
final class UpdateChecker: ObservableObject {
  // MARK: - Singleton

  static let shared = UpdateChecker()

  // MARK: - Constants

  private enum Constants {
    /// GitHub repo the update check polls. Matches the CLI's `REPO` and the git
    /// remote. GitHub treats owner/repo case-insensitively.
    static let repoSlug = "MegaManSec/wiz-light-controller"
    static let latestReleaseAPI = "https://api.github.com/repos/\(repoSlug)/releases/latest"
    static let latestReleasePage = "https://github.com/\(repoSlug)/releases/latest"
    /// GitHub's API rejects requests without a User-Agent (403).
    static let userAgent = "WiZ-Light-Controller"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let pollInterval: TimeInterval = 60 * 60
    static let requestTimeout: TimeInterval = 10
    static let lastCheckedKey = "com.wizlightcontroller.updatecheck.lastChecked"
    static let latestVersionKey = "com.wizlightcontroller.updatecheck.latestVersion"
    static let autoEnabledKey = "com.wizlightcontroller.updatecheck.autoEnabled"
  }

  // MARK: - Published state

  /// Newest version advertised by GitHub (e.g. "0.2.0"), or nil if never fetched
  /// successfully. Mutated on main only.
  @Published private(set) var latestVersion: String?

  /// True while a check is in flight (drives the "Checking…" button state).
  @Published private(set) var isChecking = false

  /// Set when a *manual* check fails to reach GitHub. Automatic checks stay silent.
  @Published private(set) var lastCheckFailed = false

  /// User preference. When off, the automatic checks (launch + hourly poll) never
  /// contact GitHub; the manual "Check for Updates" action ignores it. Default on,
  /// persisted in `UserDefaults`.
  @Published var autoCheckEnabled: Bool {
    didSet {
      UserDefaults.standard.set(autoCheckEnabled, forKey: Constants.autoEnabledKey)
      if autoCheckEnabled, !oldValue { checkIfNeeded() }
    }
  }

  // MARK: - Properties

  /// Browser URL for the latest release; `nil` only if the constant is malformed.
  let releasePageURL = URL(string: Constants.latestReleasePage)

  /// Hourly poll, retained for the singleton's lifetime.
  private var pollTimer: DispatchSourceTimer?

  // MARK: - Computed

  /// The running app's marketing version. Debug builds report "0.0.0".
  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  /// True when GitHub advertises a strictly-greater semantic version.
  var updateAvailable: Bool {
    guard let latest = latestVersion else { return false }
    return Self.isNewer(latest, than: currentVersion)
  }

  // MARK: - Init

  private init() {
    // Surface the cached result immediately so the menu reflects the last
    // successful check without waiting for the network.
    latestVersion = UserDefaults.standard.string(forKey: Constants.latestVersionKey)
    // Default on; `didSet` does not fire for this initial assignment.
    autoCheckEnabled = (UserDefaults.standard.object(forKey: Constants.autoEnabledKey) as? Bool) ?? true
    startPolling()
  }

  /// Tick hourly; `checkIfNeeded` decides whether the 24h gate has opened. First
  /// tick is one interval out — launch does the immediate check.
  private func startPolling() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + Constants.pollInterval, repeating: Constants.pollInterval)
    timer.setEventHandler { [weak self] in self?.checkIfNeeded() }
    timer.resume()
    pollTimer = timer
  }

  // MARK: - Public

  /// Fetch if it's been ≥24h since the last successful check. Returns
  /// immediately; `latestVersion` updates asynchronously on success.
  func checkIfNeeded() {
    guard autoCheckEnabled else { return }
    if let last = UserDefaults.standard.object(forKey: Constants.lastCheckedKey) as? Date,
      Date().timeIntervalSince(last) < Constants.checkInterval
    {
      return
    }
    check()
  }

  /// Force a check now (the manual "Check for Updates" action). Runs in Debug too.
  func checkNow() {
    performCheck(manual: true)
  }

  // MARK: - Private

  /// Automatic check — suppressed in Debug so a dev build (version "0.0.0")
  /// doesn't nag that every release is newer.
  private func check() {
    #if DEBUG
      return
    #else
      performCheck(manual: false)
    #endif
  }

  private func performCheck(manual: Bool) {
    guard !isChecking else { return }
    guard let url = URL(string: Constants.latestReleaseAPI) else { return }
    isChecking = true
    if manual { lastCheckFailed = false }

    var request = URLRequest(url: url)
    request.timeoutInterval = Constants.requestTimeout
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
      let version: String? = {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
          let data = data, let tag = Self.parseTagName(from: data)
        else { return nil }
        return Self.normalize(tag)
      }()

      DispatchQueue.main.async {
        guard let self = self else { return }
        self.isChecking = false
        guard let version = version else {
          if manual { self.lastCheckFailed = true }
          return
        }
        // Only record success: a transient failure shouldn't suppress retries
        // for a full 24h.
        UserDefaults.standard.set(Date(), forKey: Constants.lastCheckedKey)
        UserDefaults.standard.set(version, forKey: Constants.latestVersionKey)
        self.latestVersion = version
      }
    }.resume()
  }

  /// Pull `tag_name` out of the `releases/latest` JSON without a model type.
  private static func parseTagName(from data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = obj["tag_name"] as? String
    else { return nil }
    return tag
  }

  /// Strip a leading "v" so a `vX.Y.Z` tag compares against the bare version.
  private static func normalize(_ tag: String) -> String {
    tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
  }

  /// Numeric per-component semver compare. Missing/non-numeric components → 0.
  static func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
      let x = i < pa.count ? pa[i] : 0
      let y = i < pb.count ? pb[i] : 0
      if x != y { return x > y }
    }
    return false
  }
}
