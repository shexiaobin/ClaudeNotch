import AppKit

enum SoundEffect: String {
    case requestArrived = "Purr"
    case allowed = "Pop"
    case denied = "Basso"
}

enum SoundPlayer {
    static func play(_ effect: SoundEffect) {
        if let sound = NSSound(named: NSSound.Name(effect.rawValue)) {
            sound.play()
        }
    }
}
