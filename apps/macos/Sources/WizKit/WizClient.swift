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
/// `@unchecked Sendable`: the only mutable state (`pendingParams`,
/// `debounceWork`) is confined to the private serial `queue`; the query/send
/// methods (`getPilot`, `sendNow`, `setPilot`) are stateless socket calls. This
/// lets `AppState` hand the client to a background queue for the blocking
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

  /// Serializes coalescing + sends so a burst of `apply`/`power` calls from the
  /// UI funnels into a single debounced datagram.
  private let queue = DispatchQueue(label: "com.wizlightcontroller.client")
  private var pendingParams: [String: Any]?
  private var debounceWork: DispatchWorkItem?

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
  /// blocks on `recvfrom`).
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
    let n = recvfrom(fd, &buf, buf.count, 0, nil, nil)
    guard n > 0 else { return nil }

    let data = Data(buf[0..<n])
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return obj["result"] as? [String: Any]
  }

  /// Send a single `setPilot` datagram (fire-and-forget). The socket is always
  /// closed. Returns false only if the host/payload couldn't be formed.
  @discardableResult
  public func setPilot(params: [String: Any], host: String? = nil) -> Bool {
    Self.sendOnce(method: "setPilot", params: params, host: host ?? self.host)
  }

  // MARK: - Stateful, debounced sends (the UI path)

  /// Build the wire params for a desired state and send them debounced.
  public func apply(state: LightState, params: [String: Any]) {
    schedule(params)
  }

  /// Power on/off without altering colour, debounced.
  public func power(_ on: Bool) {
    schedule(["state": on])
  }

  /// Send `params` now, repeated `retries` times spaced `retryIntervalMs`, to
  /// survive packet loss. Bypasses the debounce — used internally after the
  /// window elapses, but public so callers can force an immediate send.
  public func sendNow(_ params: [String: Any]) {
    for i in 0..<Self.retries {
      Self.sendOnce(method: "setPilot", params: params, host: host)
      if i < Self.retries - 1 {
        usleep(useconds_t(Self.retryIntervalMs * 1000))
      }
    }
  }

  /// Coalesce: replace any pending payload, (re)arm the debounce timer. Only the
  /// latest payload in the window is sent — then `sendNow` fans it out 3×.
  private func schedule(_ params: [String: Any]) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.pendingParams = params
      self.debounceWork?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self = self, let next = self.pendingParams else { return }
        self.pendingParams = nil
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
