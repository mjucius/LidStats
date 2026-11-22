import Darwin
import Foundation
import Security

@main
enum Daemon {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("LidStats: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        guard geteuid() == 0, (2...3).contains(CommandLine.arguments.count),
              let owner = uid_t(CommandLine.arguments[1]), owner >= 501,
              owner != UInt32.max else {
            throw LidStatsError("Launch the helper through its installed LaunchDaemon.")
        }

        // An interrupted upgrade can boot the new binary with the original two-argument plist.
        let recoveryOnly = CommandLine.arguments.count == 2
        let clientPolicy = recoveryOnly ? "local-development" : CommandLine.arguments[2]
        var requirement: SecRequirement?
        if clientPolicy != "local-development" {
            guard SecRequirementCreateWithString(clientPolicy as CFString, [], &requirement) == errSecSuccess,
                  requirement != nil else { throw LidStatsError("Invalid client signing requirement.") }
        }
        umask(0o077)
        let sessions = try Sessions()
        let chipPower = ChipPower()
        let listener = try LocalSocket.open()
        // The listening socket is private to the installing account.
        if unlink(socketPath) != 0 && errno != ENOENT { throw LocalSocket.systemError("Removing stale socket") }
        try listener.bind()
        guard chown(socketPath, owner, gid_t.max) == 0, listen(listener.descriptor, 4) == 0 else {
            throw LocalSocket.systemError("Starting the local listener")
        }
        let flags = fcntl(listener.descriptor, F_GETFL)
        guard flags >= 0, fcntl(listener.descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LocalSocket.systemError("Configuring the local listener")
        }

        let queue = DispatchQueue.main
        let clientSlots = DispatchSemaphore(value: 8)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener.descriptor, queue: queue)
        source.setEventHandler {
            let client = accept(listener.descriptor, nil, nil)
            guard client >= 0 else { return }
            guard clientSlots.wait(timeout: .now()) == .success else { close(client); return }
            // Socket I/O runs off the timer queue so an incomplete request cannot delay a thermal cutoff.
            DispatchQueue.global(qos: .utility).async {
                defer {
                    close(client)
                    clientSlots.signal()
                }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == owner else { return }
                if let requirement, !matchesSigningRequirement(client, requirement: requirement) { return }
                let connection = LocalSocket(descriptor: client)
                do {
                    let request = try connection.receive(Request.self)
                    let status = queue.sync {
                        var status: Status
                        if recoveryOnly && (request.action == .start || request.action == .setBatteryCutoff) {
                            status = sessions.status(error: "Finish upgrading the power helper before changing session settings.")
                        } else {
                            status = sessions.handle(request)
                        }
                        if recoveryOnly {
                            status.supportsSafetyWatch = false
                            return status
                        }
                        status.supportsChipPower = true
                        if request.action == .status, request.wantsChipPower == true, status.lidClosed == false {
                            status.chipWatts = chipPower.latestAndRefresh()
                        }
                        return status
                    }
                    try connection.send(status)
                } catch {
                    // Invalid or disconnected clients cannot change power settings.
                }
            }
        }
        source.resume()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { sessions.tick() }
        timer.resume()

        let safetyTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.lidshift.safety", qos: .userInitiated))
        safetyTimer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(50))
        let safety = sessions.safety
        safetyTimer.setEventHandler {
            if safety.poll() {
                queue.async { sessions.enforceSafety() }
            }
        }
        safetyTimer.resume()

        let signals = [SIGTERM, SIGINT].map { code in
            signal(code, SIG_IGN)
            let handler = DispatchSource.makeSignalSource(signal: code, queue: queue)
            handler.setEventHandler {
                sessions.finish("Power helper stopped.")
                unlink(socketPath)
                exit(0)
            }
            handler.resume()
            return handler
        }
        withExtendedLifetime((source, timer, safetyTimer, signals)) { dispatchMain() }
    }
    private static func matchesSigningRequirement(_ descriptor: Int32, requirement: SecRequirement) -> Bool {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout<audit_token_t>.size else { return false }
        let auditToken = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess,
              let peer else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }
}
