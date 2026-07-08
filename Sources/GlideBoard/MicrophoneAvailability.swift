import Foundation

enum MicrophoneAvailabilityError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "No hay ningún micrófono disponible"
    }
}

func requireMicrophoneInput(deviceCount: Int) throws {
    guard deviceCount > 0 else { throw MicrophoneAvailabilityError.unavailable }
}
