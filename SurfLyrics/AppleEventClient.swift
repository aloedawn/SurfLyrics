import CoreServices
import Foundation

enum AppleEventError: Error, Equatable, Sendable {
    case permissionDenied(OSStatus)
    case targetUnavailable(OSStatus)
    case osError(OSStatus, String)
}

enum AppleEventClient {
    static let coreSuite = fourCharCode("core")
    static let getDataEvent = fourCharCode("getd")
    static let setDataEvent = fourCharCode("setd")
    static let spotifySuite = fourCharCode("spfy")
    static let spotifyPlayEvent = fourCharCode("Play")
    static let spotifyPauseEvent = fourCharCode("Paus")

    static let playerStateProperty = fourCharCode("pPlS")
    static let playerPositionProperty = fourCharCode("pPos")
    static let currentTrackProperty = fourCharCode("pTrk")
    static let trackNameProperty = fourCharCode("pnam")
    static let trackArtistProperty = fourCharCode("pArt")
    static let trackAlbumProperty = fourCharCode("pAlb")
    static let trackDurationProperty = fourCharCode("pDur")
    static let trackIDProperty = fourCharCode("ID  ")
    static let spotifyURLProperty = fourCharCode("spur")
    static let persistentIDProperty = fourCharCode("pPIS")

    static let playingEnum = fourCharCode("kPSP")
    static let fastForwardingEnum = fourCharCode("kPSF")
    static let rewindingEnum = fourCharCode("kPSR")
    static let pausedEnum = fourCharCode("kPSp")
    static let stoppedEnum = fourCharCode("kPSS")

    static func fourCharCode(_ code: StaticString) -> OSType {
        precondition(code.utf8CodeUnitCount == 4)
        return code.withUTF8Buffer { buffer in
            (OSType(buffer[0]) << 24)
                | (OSType(buffer[1]) << 16)
                | (OSType(buffer[2]) << 8)
                | OSType(buffer[3])
        }
    }

    static func propertySpecifier(
        container: NSAppleEventDescriptor = .null(),
        property: OSType
    ) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: DescType(typeProperty)),
            forKeyword: AEKeyword(keyAEDesiredClass)
        )
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: DescType(formPropertyID)),
            forKeyword: AEKeyword(keyAEKeyForm)
        )
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: property),
            forKeyword: AEKeyword(keyAEKeyData)
        )
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }

    static func currentTrackSpecifier() -> NSAppleEventDescriptor? {
        propertySpecifier(property: currentTrackProperty)
    }

    static func getData(
        of specifier: NSAppleEventDescriptor,
        pid: pid_t,
        timeout: TimeInterval = 3.0
    ) -> Result<NSAppleEventDescriptor, AppleEventError> {
        send(
            eventClass: coreSuite,
            eventID: getDataEvent,
            to: pid,
            directObject: specifier,
            timeout: timeout
        )
    }

    static func setProperty(
        _ property: OSType,
        value: NSAppleEventDescriptor,
        pid: pid_t,
        timeout: TimeInterval = 5.0
    ) -> Result<Void, AppleEventError> {
        guard let specifier = propertySpecifier(property: property) else {
            return .failure(.osError(OSStatus(errAEParamMissed), "Property specifier failed"))
        }
        return send(
            eventClass: coreSuite,
            eventID: setDataEvent,
            to: pid,
            directObject: specifier,
            parameters: [(AEKeyword(keyAEData), value)],
            timeout: timeout
        ).map { _ in () }
    }

    static func sendCommand(
        eventClass: OSType,
        eventID: OSType,
        pid: pid_t,
        timeout: TimeInterval = 5.0
    ) -> Result<Void, AppleEventError> {
        send(
            eventClass: eventClass,
            eventID: eventID,
            to: pid,
            timeout: timeout
        ).map { _ in () }
    }

    static func send(
        eventClass: OSType,
        eventID: OSType,
        to pid: pid_t,
        directObject: NSAppleEventDescriptor? = nil,
        parameters: [(AEKeyword, NSAppleEventDescriptor)] = [],
        timeout: TimeInterval = 3.0
    ) -> Result<NSAppleEventDescriptor, AppleEventError> {
        var targetPID = pid
        let target = NSAppleEventDescriptor(
            descriptorType: DescType(typeKernelProcessID),
            bytes: &targetPID,
            length: MemoryLayout<pid_t>.size
        )
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(eventClass),
            eventID: AEEventID(eventID),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let directObject {
            event.setDescriptor(directObject, forKeyword: AEKeyword(keyDirectObject))
        }
        for (keyword, value) in parameters {
            event.setDescriptor(value, forKeyword: keyword)
        }

        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
            return decodeReply(reply)
        } catch let error as NSError {
            return .failure(mapNSError(error))
        }
    }

    static func decodeReply(_ reply: NSAppleEventDescriptor) -> Result<NSAppleEventDescriptor, AppleEventError> {
        if let errorCode = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value,
            errorCode != 0
        {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                ?? "AE err \(errorCode)"
            return .failure(mapStatus(OSStatus(errorCode), message: message))
        }
        return .success(reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null())
    }

    static func mapNSError(_ error: NSError) -> AppleEventError {
        mapStatus(OSStatus(error.code), message: error.localizedDescription)
    }

    static func mapStatus(_ status: OSStatus, message: String) -> AppleEventError {
        switch status {
        case OSStatus(errAEEventNotPermitted):
            .permissionDenied(status)
        case OSStatus(procNotFound), OSStatus(errAENoSuchObject):
            .targetUnavailable(status)
        default:
            .osError(status, message)
        }
    }

    static func enumCode(from descriptor: NSAppleEventDescriptor) -> OSType? {
        let code = descriptor.enumCodeValue
        return code != 0 ? code : nil
    }

    static func doubleValue(from descriptor: NSAppleEventDescriptor) -> Double? {
        descriptor.coerce(toDescriptorType: DescType(typeIEEE64BitFloatingPoint))?.doubleValue
    }
}
