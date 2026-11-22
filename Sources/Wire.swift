import Darwin
import Foundation

let label = "com.lidshift.power"
let socketPath = "/var/run/\(label).sock"
let defaultBatteryCutoff = 10
let lidHistoryLimit = 12
let powerHelperProtocolRevision = 1

struct Request: Codable {
    enum Action: String, Codable { case status, start, stop, setBatteryCutoff, repairSleep }
    let action: Action
    var hours: Int? = nil
    var wantsChipPower: Bool? = nil
    var batteryCutoff: Int? = nil
    var startRequestedAtUptime: TimeInterval? = nil
    var startExpiresAtUptime: TimeInterval? = nil
}

struct LidActivity: Codable, Equatable {
    let closedAt: Date
    let batteryAtClose: Int?
    var reopenedAt: Date? = nil
    var batteryAtReopen: Int? = nil
    var sessionEndedAt: Date? = nil
    var interruption: String? = nil
    var detectedSleep: Bool? = nil
    var displaySleepFailed: Bool? = nil

    var isOpenInterval: Bool { reopenedAt == nil && interruption == nil }
}

struct Status: Codable {
    let pluggedIn: Bool
    let deadline: Date?
    let lidClosed: Bool?
    let lowPowerEnabled: Bool
    let message: String
    let recovering: Bool
    var batteryPercentage: Int? = nil
    var batteryCutoff: Int? = nil
    var error: String? = nil
    var sessionActive: Bool? = nil
    var lidHistory: [LidActivity]? = nil
    var chipWatts: Double? = nil
    var supportsChipPower: Bool? = nil
    var recoveryRequired: Bool? = nil
    var supportsSafetyWatch: Bool? = nil
    var helperProtocolRevision: Int? = nil

    var hasCurrentPowerHelper: Bool {
        supportsSafetyWatch == true && helperProtocolRevision == powerHelperProtocolRevision
    }

    var isActive: Bool { sessionActive ?? (deadline != nil) }
}

struct LidStatsError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct LocalSocket {
    let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    }

    static func open() throws -> LocalSocket {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemError("Opening the local socket") }
        return LocalSocket(descriptor: descriptor)
    }

    func connectToPowerHelper(deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 3) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Self.systemError("Configuring the local connection")
        }
        try withAddress { address, length in
            try checkDeadline(deadline)
            if Darwin.connect(descriptor, address, length) == 0 { return }
            guard errno == EINPROGRESS || errno == EINTR || errno == EALREADY else {
                throw Self.systemError("Connecting to the power helper")
            }
            try wait(for: POLLOUT, until: deadline)
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else {
                throw Self.systemError("Checking the local connection")
            }
            if failure != 0 { throw Self.systemError("Connecting to the power helper", code: failure) }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == 0 else {
            throw LidStatsError("The power helper’s identity could not be verified.")
        }
    }

    func bind() throws {
        try withAddress { address, length in
            guard Darwin.bind(descriptor, address, length) == 0 else {
                throw Self.systemError("Binding the power helper socket")
            }
        }
    }

    private func withAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: socketPath.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let length = socklen_t(address.sun_len)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, length)
            }
        }
    }

    func send<T: Encodable>(_ value: T, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 3) throws {
        let data = try JSONEncoder().encode(value)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(for: POLLOUT, until: deadline)
                let count = Darwin.send(descriptor, base + offset, bytes.count - offset, MSG_DONTWAIT)
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                guard count > 0 else { throw Self.systemError("Writing to the local socket") }
                offset += count
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)
    }

    func receive<T: Decodable>(_ type: T.Type, timeout: TimeInterval = 3) throws -> T {
        try receive(type, deadline: ProcessInfo.processInfo.systemUptime + timeout)
    }

    func receive<T: Decodable>(_ type: T.Type, deadline: TimeInterval) throws -> T {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while data.count < 4096 {
            try wait(for: POLLIN, until: deadline)
            let available = 4096 - data.count
            let count = bytes.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, min($0.count, available), MSG_DONTWAIT)
            }
            if count == 0 { return try JSONDecoder().decode(type, from: data) }
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { throw Self.systemError("Reading from the local socket") }
            data.append(contentsOf: bytes.prefix(count))
        }
        throw LidStatsError("The local message is too large.")
    }

    @discardableResult
    private func checkDeadline(_ deadline: TimeInterval) throws -> TimeInterval {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw LidStatsError("The local message timed out.") }
        return remaining
    }

    private func wait(for events: Int32, until deadline: TimeInterval) throws {
        while true {
            let remaining = try checkDeadline(deadline)
            var event = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let ready = poll(&event, 1, Int32((remaining * 1_000).rounded(.up)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw Self.systemError("Waiting for the local message") }
            guard ready > 0 else { throw LidStatsError("The local message timed out.") }
            try checkDeadline(deadline)
            return
        }
    }

    static func systemError(_ operation: String, code: Int32 = errno) -> LidStatsError {
        let detail = String(cString: strerror(code))
        return LidStatsError("\(operation): \(detail)")
    }
}
