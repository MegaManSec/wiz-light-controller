import Darwin
import Foundation

/// LAN discovery of WiZ bulbs. Bulbs answer a broadcast `getSystemConfig` with
/// their MAC and module name, so a few broadcasts over a couple of seconds
/// enumerate everything on the subnet. Deduplicated by MAC — the stable
/// identity the app keys saved lights on.
///
/// On macOS, broadcasting only to the global `255.255.255.255` is unreliable;
/// the kernel routes it out a single interface. We also broadcast to each
/// interface's *directed* subnet broadcast address (computed from its address +
/// netmask via `getifaddrs`), which materially improves the hit rate.
public enum Discovery {
  /// A discovered bulb. `name` is the module name, falling back to the MAC.
  /// `mac` is `""` when the reply omitted one. Hashable so lists can identify
  /// rows by the whole value (two MAC-less bulbs would collide on `mac` alone).
  public struct Light: Equatable, Hashable {
    public let name: String
    public let ip: String
    public let mac: String
    public init(name: String, ip: String, mac: String) {
      self.name = name
      self.ip = ip
      self.mac = mac
    }
  }

  public static let port: UInt16 = 38899

  /// Broadcast for ~`duration` seconds, then call `completion` on the main queue
  /// with the unique bulbs found (deduped by MAC, insertion-ordered).
  ///
  /// Runs the blocking socket work on a background queue. Re-broadcasts a few
  /// times across the window so a bulb that missed the first packet still answers.
  public static func discover(
    duration: TimeInterval = 2.5,
    completion: @escaping ([Light]) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let found = run(duration: duration)
      DispatchQueue.main.async { completion(found) }
    }
  }

  // MARK: - Blocking implementation

  private static func run(duration: TimeInterval) -> [Light] {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return [] }
    defer { Darwin.close(fd) }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

    // Short receive timeout so the recv loop polls cooperatively against the
    // overall deadline instead of blocking a full second per call.
    var tv = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    guard let payload = try? JSONSerialization.data(
      withJSONObject: ["method": "getSystemConfig", "params": [:]]
    ) else { return [] }

    // Global broadcast + every interface's directed subnet broadcast.
    var targets = Set<String>(["255.255.255.255"])
    targets.formUnion(broadcastAddresses())

    let deadline = Date().addingTimeInterval(duration)
    var found: [String: Light] = [:]
    var order: [String] = []

    // Three broadcast bursts spread across the window.
    let bursts = 3
    var nextBurst = Date()
    var burstsLeft = bursts

    while Date() < deadline {
      if burstsLeft > 0, Date() >= nextBurst {
        for target in targets { send(payload, to: target, fd: fd) }
        burstsLeft -= 1
        nextBurst = Date().addingTimeInterval(duration / Double(bursts))
      }

      if let (light, key) = receive(fd: fd), found[key] == nil {
        found[key] = light
        order.append(key)
      }
    }

    return order.compactMap { found[$0] }
  }

  private static func send(_ payload: Data, to host: String, fd: Int32) {
    guard var addr = WizClient.makeSockaddr(for: host, port: port) else { return }
    _ = payload.withUnsafeBytes { raw in
      withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  /// One `recvfrom`; returns the parsed bulb plus its dedupe key (MAC, or source
  /// IP when the reply omits a MAC), or `nil` on timeout / unparseable data.
  private static func receive(fd: Int32) -> (Light, String)? {
    var buf = [UInt8](repeating: 0, count: 4096)
    var from = sockaddr_in()
    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = withUnsafeMutablePointer(to: &from) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
      }
    }
    guard n > 0 else { return nil }

    let data = Data(buf[0..<n])
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let result = obj["result"] as? [String: Any]
    else { return nil }

    let srcIp = ipString(from: from)
    let mac = result["mac"] as? String
    let name = (result["moduleName"] as? String) ?? mac ?? srcIp
    let key = mac ?? srcIp
    return (Light(name: name, ip: srcIp, mac: mac ?? ""), key)
  }

  // MARK: - Interface enumeration

  /// Directed subnet broadcast address for every up, non-loopback IPv4
  /// interface (host address OR'd with the inverse of its netmask).
  static func broadcastAddresses() -> [String] {
    var addrs: [String] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return addrs }
    defer { freeifaddrs(ifap) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = ptr {
      defer { ptr = cur.pointee.ifa_next }
      let flags = Int32(cur.pointee.ifa_flags)
      // IFF_BROADCAST: only interfaces that actually have a broadcast address.
      // A point-to-point link (utun VPNs etc.) has a /32 mask, so addr | ~mask
      // would just unicast the probe back at our own address.
      guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, (flags & IFF_BROADCAST) != 0,
        let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
        let nm = cur.pointee.ifa_netmask
      else { continue }

      let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
      let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
      // host | ~mask == directed broadcast (still in network byte order).
      let bcast = addr | ~mask
      addrs.append(ipString(fromBE: bcast))
    }
    return addrs
  }

  // MARK: - Address formatting

  private static func ipString(from addr: sockaddr_in) -> String {
    ipString(fromBE: addr.sin_addr.s_addr)
  }

  /// Format a big-endian (network-order) IPv4 word as dotted quad.
  private static func ipString(fromBE be: in_addr_t) -> String {
    let host = UInt32(bigEndian: be)
    return "\((host >> 24) & 0xff).\((host >> 16) & 0xff).\((host >> 8) & 0xff).\(host & 0xff)"
  }
}
