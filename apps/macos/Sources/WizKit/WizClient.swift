import Darwin
import Foundation

/// UDP transport for a single WiZ bulb. The bulb listens on :38899 and speaks
/// line-free JSON: `setPilot` mutates state (no reply needed), `getPilot`
/// returns the live state. Mirrors the shared engine's `WizLight`: rapid
/// updates (slider drags) coalesce into one debounced send, which is then
/// transmitted a few times to ride out UDP packet loss and the firmware's
/// "micro-sleeps".
///
/// Built on Darwin POSIX sockets (`socket`/`sendto`/`recvfrom`) — simplest for
/// fire-and-forget datagrams. Each `WizClient` owns a serial queue; the public
/// methods are safe to call from the main actor.
///
/// `@unchecked Sendable`: the mutable state is either confined to the private
/// serial `queue` (`pendingParams`, `debounceWork`) or guarded by `genLock`
/// (`sendGen`); the query methods (`getPilot` etc.) are stateless socket calls.
/// This lets `AppState` hand the client to a background queue for the blocking
/// `getPilot` without tripping Sendable diagnostics.
public final class WizClient: @unchecked Sendable {
  // MARK: - Tunables (match wiz-light-core's protocol defaults)

  public static let port: UInt16 = 38899
  public static let timeoutMs = 1000
  public static let retries = 3
  public static let retryIntervalMs = 120
  public static let debounceMs = 250

  // MARK: - Per-host state

  public let host: String

  /// Serializes coalescing + sends so a burst of `send`/`power` calls from the
  /// UI funnels into a single debounced datagram.
  private let queue = DispatchQueue(label: "com.wizlightcontroller.client")
  private var pendingParams: [String: Any]?
  private var debounceWork: DispatchWorkItem?

  /// Send generation, mirroring the engine `WizLight`'s `#sendGen`: every
  /// `sendNow` bumps it, each retry iteration re-checks it (so a newer send
  /// abandons an in-flight retry loop and a stale payload can't land after the
  /// new one), and a debounced send armed before a direct `sendNow` is dropped
  /// when its window elapses. Guarded by `genLock` — `sendNow` runs on whatever
  /// thread called it (main for the sleep power-off, `queue` for debounced sends).
  private var sendGen = 0
  private let genLock = NSLock()

  private func bumpGen() -> Int {
    genLock.lock()
    defer { genLock.unlock() }
    sendGen += 1
    return sendGen
  }

  private func currentGen() -> Int {
    genLock.lock()
    defer { genLock.unlock() }
    return sendGen
  }

  public init(host: String) {
    self.host = host
  }

  // MARK: - One-shot queries / sends (stateless)

  /// Query `getPilot` and return the bulb's `result` object, or `nil` on a 1s
  /// timeout or any socket error. Never throws — callers treat `nil` as
  /// "unreachable". Safe to call off the main thread (it blocks on `recvfrom`).
  public func getPilot(host: String? = nil) -> [String: Any]? {
    query(method: "getPilot", host: host ?? self.host)
  }

  /// Query `getModelConfig` and return its `result` — the bulb's capabilities,
  /// including `cctRange` (its real white-temperature range) and `minDimLevel`.
  /// Same timeout/failure semantics as `getPilot`.
  public func getModelConfig(host: String? = nil) -> [String: Any]? {
    query(method: "getModelConfig", host: host ?? self.host)
  }

  /// Query `getSystemConfig` and return its `result` — identity / firmware
  /// (`mac`, `moduleName`, `fwVersion`). Same semantics as `getPilot`.
  public func getSystemConfig(host: String? = nil) -> [String: Any]? {
    query(method: "getSystemConfig", host: host ?? self.host)
  }

  /// Query `getUserConfig` and return its `result` — user config incl.
  /// `dim2WarmPoints` (the dim-to-warm brightness→Kelvin curve).
  public func getUserConfig(host: String? = nil) -> [String: Any]? {
    query(method: "getUserConfig", host: host ?? self.host)
  }

  /// Send a no-param request and return the parsed `result`, or `nil` on a 1s
  /// timeout / any socket error. Never throws. Safe off the main thread (it
  /// blocks on `recvfrom`). Only a datagram *from the queried host* counts —
  /// the socket's ephemeral port is otherwise open to any sender, and a stray
  /// (or spoofed) reply must not be read as the bulb's state; foreign datagrams
  /// are skipped and the receive keeps waiting out the timeout (mirrors the
  /// engine `query`).
  private func query(method: String, host: String) -> [String: Any]? {
    guard let payload = Self.encode(method: method, params: [:]) else { return nil }

    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }

    // 1s receive timeout via SO_RCVTIMEO so a silent bulb can't hang us.
    var tv = timeval(tv_sec: __darwin_time_t(Self.timeoutMs / 1000),
                     tv_usec: __darwin_suseconds_t((Self.timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    guard var addr = Self.makeSockaddr(for: host, port: Self.port) else { return nil }
    let sent = payload.withUnsafeBytes { raw in
      withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    guard sent >= 0 else { return nil }

    var buf = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(Double(Self.timeoutMs) / 1000)
    while true {
      var from = sockaddr_in()
      var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let n = withUnsafeMutablePointer(to: &from) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
        }
      }
      guard n > 0 else { return nil }  // timeout (EAGAIN) or socket error
      // Not the bulb we asked — keep waiting (bounded by the deadline, so a
      // chatty foreign sender can't keep the call alive past the timeout).
      guard from.sin_addr.s_addr == addr.sin_addr.s_addr else {
        if Date() >= deadline { return nil }
        continue
      }

      let data = Data(buf[0..<n])
      guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil  // malformed reply from the bulb itself (mirrors the engine)
      }
      return obj["result"] as? [String: Any]
    }
  }

  /// Send a single `setPilot` datagram (fire-and-forget). The socket is always
  /// closed. Returns false only if the host/payload couldn't be formed.
  @discardableResult
  public func setPilot(params: [String: Any], host: String? = nil) -> Bool {
    Self.sendOnce(method: "setPilot", params: params, host: host ?? self.host)
  }

  // MARK: - Stateful, debounced sends (the UI path)

  /// Send prebuilt wire params debounced (mirrors the engine `WizLight.send`;
  /// the params are built by the caller because `buildSetPilotParams` needs the
  /// device bounds and white-mix choice that live in the app layer).
  public func send(_ params: [String: Any]) {
    schedule(params)
  }

  /// Power on/off without altering colour, debounced.
  public func power(_ on: Bool) {
    schedule(["state": on])
  }

  /// Send `params` now, repeated `retries` times spaced `retryIntervalMs`, to
  /// survive packet loss. Bypasses the debounce — used internally after the
  /// window elapses, but public so callers can force an immediate send. A newer
  /// `sendNow` started mid-loop abandons the remaining retries (generation
  /// guard), so a stale payload can't land after the new one.
  public func sendNow(_ params: [String: Any]) {
    let gen = bumpGen()
    for i in 0..<Self.retries {
      if gen != currentGen() { return }  // superseded by a newer send
      Self.sendOnce(method: "setPilot", params: params, host: host)
      if i < Self.retries - 1 {
        usleep(useconds_t(Self.retryIntervalMs * 1000))
      }
    }
  }

  /// Coalesce: replace any pending payload, (re)arm the debounce timer. Only the
  /// latest payload in the window is sent — then `sendNow` fans it out 3×. A
  /// direct `sendNow` issued after the window was armed supersedes it: the stale
  /// payload is dropped when the window elapses (mirrors the engine `WizLight`).
  private func schedule(_ params: [String: Any]) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.pendingParams = params
      self.debounceWork?.cancel()
      let gen = self.currentGen()  // window-arm generation; a direct send bumps it
      let work = DispatchWorkItem { [weak self] in
        guard let self = self, let next = self.pendingParams else { return }
        self.pendingParams = nil
        guard gen == self.currentGen() else { return }  // superseded — drop the stale payload
        self.sendNow(next)
      }
      self.debounceWork = work
      self.queue.asyncAfter(deadline: .now() + .milliseconds(Self.debounceMs), execute: work)
    }
  }

  /// Cancel any pending debounced send.
  public func close() {
    queue.async { [weak self] in
      self?.debounceWork?.cancel()
      self?.debounceWork = nil
      self?.pendingParams = nil
    }
  }

  /// Cancel any pending debounced send and *wait* until nothing is in flight on
  /// the client queue. Used before a forced power-off at sleep/shutdown: a
  /// debounced colour edit from moments earlier must not fire after the off.
  /// Blocks the caller for at most one in-progress `sendNow` (~240 ms). Never
  /// call from the client queue itself (it would deadlock); the app calls it
  /// from the main actor only.
  public func cancelPendingSync() {
    queue.sync {
      debounceWork?.cancel()
      debounceWork = nil
      pendingParams = nil
    }
  }

  // MARK: - Socket helpers

  /// Open a datagram socket, send one `{method,params}` packet, close. Returns
  /// false if the host is unparseable or the JSON can't be built.
  @discardableResult
  private static func sendOnce(method: String, params: [String: Any], host: String) -> Bool {
    guard let payload = encode(method: method, params: params),
      var addr = makeSockaddr(for: host, port: port)
    else { return false }

    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }

    let sent = payload.withUnsafeBytes { raw in
      withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    return sent >= 0
  }

  private static func encode(method: String, params: [String: Any]) -> Data? {
    let body: [String: Any] = ["method": method, "params": params]
    return try? JSONSerialization.data(withJSONObject: body)
  }

  /// Build an IPv4 `sockaddr_in` for a dotted-quad host. `nil` if it doesn't
  /// parse (callers already validate IPs via `WizCore.isValidIp`).
  static func makeSockaddr(for host: String, port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
    return addr
  }
}
