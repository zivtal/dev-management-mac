import Foundation
import IOKit

final class USBConnectionMonitor {
    var onConnectionChanged: (() -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var isStarted = false

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let matching = IOServiceMatching("IOUSBHostDevice") {
            IOServiceAddMatchingNotification(
                port,
                kIOFirstMatchNotification,
                matching,
                usbConnectionCallback,
                context,
                &matchedIterator
            )
            consume(iterator: matchedIterator, shouldNotify: false)
        }

        if let matching = IOServiceMatching("IOUSBHostDevice") {
            IOServiceAddMatchingNotification(
                port,
                kIOTerminatedNotification,
                matching,
                usbConnectionCallback,
                context,
                &terminatedIterator
            )
            consume(iterator: terminatedIterator, shouldNotify: false)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        if matchedIterator != 0 { IOObjectRelease(matchedIterator) }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator) }
        matchedIterator = 0
        terminatedIterator = 0
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
    }

    fileprivate func consume(iterator: io_iterator_t, shouldNotify: Bool = true) {
        var foundDevice = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            foundDevice = true
            IOObjectRelease(service)
        }
        if foundDevice, shouldNotify {
            onConnectionChanged?()
        }
    }
}

private func usbConnectionCallback(
    context: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let context else { return }
    let monitor = Unmanaged<USBConnectionMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.consume(iterator: iterator)
}
