import AppKit

enum SoundEffect: String {
    case requestArrived = "Purr"
    case allowed = "Pop"
    case denied = "Basso"
}

enum SoundPlayer {
    private static var currentSound: NSSound?

    static func play(_ effect: SoundEffect) {
        currentSound?.stop()
        if let sound = NSSound(named: NSSound.Name(effect.rawValue)) {
            currentSound = sound
            sound.play()
        }
    }
}
