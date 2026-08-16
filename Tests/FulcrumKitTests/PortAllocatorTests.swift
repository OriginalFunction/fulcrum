import Foundation
import Testing
@testable import FulcrumKit

// MARK: - The search

@Test func returnsTheStartingPortWhenItIsFree() {
    #expect(PortAllocator.freePort(startingAt: 10350, isAvailable: { _ in true }) == 10350)
}

@Test func returnsTheFirstFreePortAtOrAfterTheStart() {
    let taken: Set<Int> = [10350, 10351]
    #expect(PortAllocator.freePort(startingAt: 10350, isAvailable: { !taken.contains($0) }) == 10352)
}

@Test func probesEveryPortInOrderWithoutSkipping() {
    // A search that stepped by anything other than 1 would hand back a port
    // further from the default than necessary, and would silently skip a port
    // the user's other instances are not on.
    var probed: [Int] = []
    let free = PortAllocator.freePort(startingAt: 10350, isAvailable: { port in
        probed.append(port)
        return port == 10353
    })
    #expect(free == 10353)
    #expect(probed == [10350, 10351, 10352, 10353])
}

@Test func givesUpRatherThanScanningForever() {
    // Every port busy. Must return nil after a bounded number of probes.
    // Counted, not timed: a timing assertion would pass on a machine fast
    // enough to scan all 64k ports.
    var probes = 0
    let free = PortAllocator.freePort(startingAt: 10350, isAvailable: { _ in
        probes += 1
        return false
    })
    #expect(free == nil)
    #expect(probes == PortAllocator.searchLimit)
    #expect(probes <= 200, "the search must stay far short of scanning the whole port space")
}

// MARK: - Range

@Test func neverReturnsAPortOutsideTheValidRange() {
    // Starting near the top must not return 65536 and must not wrap to a low
    // port: both would be handed straight to `tilt --port`, which would fail
    // in a way that looks like Fulcrum picked a random port.
    var probed: [Int] = []
    let free = PortAllocator.freePort(startingAt: 65534, isAvailable: { port in
        probed.append(port)
        return false
    })
    #expect(free == nil)
    #expect(probed == [65534, 65535])
}

@Test func returnsTheLastValidPortWhenItIsTheOnlyOneFree() {
    #expect(PortAllocator.freePort(startingAt: 65535, isAvailable: { _ in true }) == 65535)
}

@Test func refusesToStartAboveTheValidRange() {
    var probes = 0
    let free = PortAllocator.freePort(startingAt: 70000, isAvailable: { _ in
        probes += 1
        return true
    })
    #expect(free == nil)
    #expect(probes == 0)
}

@Test func skipsPrivilegedPortsBelowTheValidRange() {
    // Binding below 1024 needs root; offering one would produce a launch
    // failure the user cannot act on.
    var probed: [Int] = []
    let free = PortAllocator.freePort(startingAt: 80, isAvailable: { port in
        probed.append(port)
        return true
    })
    #expect(free == 1024)
    #expect(probed == [1024])
}

// MARK: - The real probe

@Test func theRealProbeReportsABoundPortAsBusy() throws {
    // Verifies the default `isAvailable` genuinely touches the network stack
    // rather than optimistically answering "free". Uses a port the kernel
    // hands out (bind to 0), never a port a real tilt instance could be on.
    let listener = try LocalListener()
    defer { listener.close() }
    #expect(PortAllocator.isPortFree(listener.port) == false)
}

@Test func theRealProbeReportsAnUntouchedPortAsFree() {
    // This used to bind an ephemeral port, close it, and re-probe that same
    // port number expecting it free. That is a genuine TOCTOU race, not a
    // narrow window that a smaller sleep would fix: the moment between
    // close() and the next `isPortFree()` call is exactly when the kernel is
    // free to hand that port to someone else — plausibly another test's own
    // `LocalListener()` binding to port 0 concurrently, since swift-testing
    // runs tests in parallel and every such listener draws from the same
    // ephemeral range. Reported failing once in 45 runs; not fixable by
    // shrinking the window because the race is inherent to reusing a port we
    // ourselves just freed.
    //
    // This checks the real probe's positive case a different way: a fixed,
    // high, non-ephemeral port this test never binds or unbinds itself. That
    // removes the self-induced close-then-reprobe transition entirely, which
    // was the actual cause of the flake. It is not a zero-probability
    // guarantee — some unrelated process could in principle already hold
    // this exact port — but that is an ordinary environmental assumption
    // (the same one every test in this file already makes about ports 1024
    // through 65535 being generally available on a dev machine), not a race
    // this test creates by its own actions.
    #expect(PortAllocator.isPortFree(65_533) == true)
}

@Test func theRealProbeRejectsPortsOutsideTheValidRange() {
    #expect(PortAllocator.isPortFree(0) == false)
    #expect(PortAllocator.isPortFree(65536) == false)
}

/// A real socket bound to a kernel-assigned port on 127.0.0.1, so the probe
/// can be tested against a genuinely busy port without guessing one.
private final class LocalListener {
    let port: Int
    private var descriptor: Int32
    private var isClosed = false

    init() throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw LocalListenerError.failed }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fileDescriptor)
            throw LocalListenerError.failed
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fileDescriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fileDescriptor)
            throw LocalListenerError.failed
        }
        descriptor = fileDescriptor
        port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    deinit { close() }
}

private enum LocalListenerError: Error { case failed }
