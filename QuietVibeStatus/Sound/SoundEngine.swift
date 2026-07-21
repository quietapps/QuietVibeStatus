import AVFoundation
import Foundation

/// The events that can make a sound. Each is independently assignable in Settings.
enum SoundEvent: String, CaseIterable, Identifiable {
    case sessionStart
    case taskComplete
    case taskError
    case approvalNeeded
    case taskAcknowledge
    case contextLimit
    case idleReminder
    case spamDetection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionStart: return "Session Start"
        case .taskComplete: return "Task Complete"
        case .taskError: return "Task Error"
        case .approvalNeeded: return "Approval Needed"
        case .taskAcknowledge: return "Task Acknowledge"
        case .contextLimit: return "Context Limit"
        case .idleReminder: return "Idle Reminder"
        case .spamDetection: return "Spam Detection"
        }
    }

    var subtitle: String {
        switch self {
        case .sessionStart: return "New Claude / Codex / Gemini session"
        case .taskComplete: return "AI finished its turn"
        case .taskError: return "Tool failure or API error"
        case .approvalNeeded: return "Permission or question pending"
        case .taskAcknowledge: return "You submitted a prompt"
        case .contextLimit: return "Context window almost full"
        case .idleReminder: return "AI is waiting for your input"
        case .spamDetection: return "3+ prompts in 10 seconds"
        }
    }

    /// Whether this event makes a sound by default. The chattier ones start off.
    var defaultsToOn: Bool {
        switch self {
        case .taskAcknowledge, .idleReminder, .spamDetection: return false
        default: return true
        }
    }
}

/// A short chiptune phrase: a list of notes rendered as square/triangle waves.
struct Chiptune {
    struct Note {
        var frequency: Double
        var duration: Double
        var waveform: Waveform = .square
        var volume: Double = 1.0
    }

    enum Waveform {
        case square
        case triangle
        case noise
    }

    var notes: [Note]

    // Frequencies for the notes the built-in phrases use.
    static let c5 = 523.25, d5 = 587.33, e5 = 659.25, g5 = 783.99
    static let a5 = 880.0, c6 = 1046.5, e6 = 1318.5, g4 = 392.0, e4 = 329.63, c4 = 261.63

    static let library: [String: Chiptune] = [
        "chime": Chiptune(notes: [
            .init(frequency: c5, duration: 0.06),
            .init(frequency: e5, duration: 0.06),
            .init(frequency: g5, duration: 0.10),
        ]),
        "rise": Chiptune(notes: [
            .init(frequency: g4, duration: 0.05),
            .init(frequency: c5, duration: 0.05),
            .init(frequency: e5, duration: 0.05),
            .init(frequency: c6, duration: 0.12),
        ]),
        "done": Chiptune(notes: [
            .init(frequency: e5, duration: 0.07),
            .init(frequency: g5, duration: 0.07),
            .init(frequency: c6, duration: 0.14),
        ]),
        "alert": Chiptune(notes: [
            .init(frequency: a5, duration: 0.08),
            .init(frequency: 0, duration: 0.04),
            .init(frequency: a5, duration: 0.08),
        ]),
        "error": Chiptune(notes: [
            .init(frequency: e4, duration: 0.10, waveform: .triangle),
            .init(frequency: c4, duration: 0.18, waveform: .triangle),
        ]),
        "blip": Chiptune(notes: [
            .init(frequency: d5, duration: 0.04, volume: 0.7),
        ]),
        "warn": Chiptune(notes: [
            .init(frequency: c5, duration: 0.07, waveform: .triangle),
            .init(frequency: g4, duration: 0.12, waveform: .triangle),
        ]),
    ]

    static func defaultName(for event: SoundEvent) -> String {
        switch event {
        case .sessionStart: return "rise"
        case .taskComplete: return "done"
        case .taskError: return "error"
        case .approvalNeeded: return "alert"
        case .taskAcknowledge: return "blip"
        case .contextLimit: return "warn"
        case .idleReminder: return "chime"
        case .spamDetection: return "blip"
        }
    }
}

/// Synthesizes and plays the app's 8-bit sounds.
///
/// Buffers are rendered once on first use and reused, so playing a sound never allocates on a hot
/// path. The engine is torn down when idle so the app doesn't hold the audio device open.
final class SoundEngine {
    static let shared = SoundEngine()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44100
    private var format: AVAudioFormat?
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var idleTimer: Timer?
    private let lock = NSLock()

    private var prefs: Preferences { Preferences.shared }

    private init() {}

    // MARK: - Playback

    func play(_ event: SoundEvent) {
        guard prefs.soundEnabled else { return }
        guard !QuietScenes.shared.isQuiet else { return }
        guard !isInQuietHours else { return }

        let assignment = prefs.soundAssignments[event.rawValue]
            ?? (event.defaultsToOn ? Chiptune.defaultName(for: event) : "off")
        guard assignment != "off" else { return }

        if assignment.hasPrefix("custom:") {
            playCustomFile(named: String(assignment.dropFirst("custom:".count)))
            return
        }

        playBuiltIn(named: assignment)
    }

    /// Used by the Settings preview buttons, which should sound even when the event is muted.
    func preview(soundNamed name: String) {
        guard name != "off" else { return }
        if name.hasPrefix("custom:") {
            playCustomFile(named: String(name.dropFirst("custom:".count)))
        } else {
            playBuiltIn(named: name)
        }
    }

    private func playBuiltIn(named name: String) {
        guard let tune = Chiptune.library[name] ?? Chiptune.library["chime"] else { return }

        lock.lock()
        let buffer: AVAudioPCMBuffer?
        if let cached = cache[name] {
            buffer = cached
        } else {
            buffer = render(tune)
            if let buffer { cache[name] = buffer }
        }
        lock.unlock()

        guard let buffer else { return }
        schedule(buffer)
    }

    private func playCustomFile(named fileName: String) {
        let url = CustomSounds.directory.appendingPathComponent(fileName)
        guard let file = try? AVAudioFile(forReading: url) else {
            Log.sound.error("cannot read custom sound \(fileName)")
            return
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else { return }
        try? file.read(into: buffer)
        schedule(buffer, format: file.processingFormat)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, format overrideFormat: AVAudioFormat? = nil) {
        do {
            try startEngineIfNeeded(format: overrideFormat ?? buffer.format)
        } catch {
            Log.sound.error("audio engine failed: \(error.localizedDescription)")
            return
        }

        player.volume = Float(prefs.soundVolume)
        player.scheduleBuffer(buffer, at: nil, options: [])
        if !player.isPlaying { player.play() }
        scheduleIdleShutdown()
    }

    // MARK: - Engine lifecycle

    private func startEngineIfNeeded(format: AVAudioFormat) throws {
        if engine.isRunning, self.format?.sampleRate == format.sampleRate {
            return
        }

        if engine.isRunning {
            engine.stop()
            engine.disconnectNodeOutput(player)
        }
        if player.engine == nil {
            engine.attach(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.format = format
        try engine.start()
    }

    /// Holding the output device open makes the Mac route all audio through us and can steal
    /// AirPods from other apps, so shut down shortly after the last sound.
    private func scheduleIdleShutdown() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self, !self.player.isPlaying else { return }
            self.engine.stop()
            self.format = nil
        }
    }

    // MARK: - Synthesis

    private func render(_ tune: Chiptune) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return nil }

        let totalFrames = tune.notes.reduce(0.0) { $0 + $1.duration } * sampleRate
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(totalFrames.rounded(.up))
            ),
            let channel = buffer.floatChannelData?[0]
        else { return nil }

        var writeIndex = 0
        var noiseState: UInt32 = 0x1234_5678

        for note in tune.notes {
            let frames = Int(note.duration * sampleRate)
            guard frames > 0 else { continue }

            for frame in 0 ..< frames {
                let t = Double(frame) / sampleRate
                var sample: Double

                if note.frequency <= 0 {
                    sample = 0
                } else {
                    switch note.waveform {
                    case .square:
                        let phase = (t * note.frequency).truncatingRemainder(dividingBy: 1)
                        sample = phase < 0.5 ? 1 : -1
                    case .triangle:
                        let phase = (t * note.frequency).truncatingRemainder(dividingBy: 1)
                        sample = 4 * abs(phase - 0.5) - 1
                    case .noise:
                        // Linear-feedback shift register, the classic 8-bit noise channel.
                        noiseState ^= noiseState << 13
                        noiseState ^= noiseState >> 17
                        noiseState ^= noiseState << 5
                        sample = Double(noiseState % 1000) / 500 - 1
                    }
                }

                // Short attack and decay ramps: square waves click badly without them, and the
                // click is what makes cheap chiptunes sound harsh on good headphones.
                let rampFrames = min(Double(frames) * 0.2, sampleRate * 0.005)
                var envelope = 1.0
                if rampFrames > 0 {
                    let position = Double(frame)
                    let remaining = Double(frames - frame)
                    envelope = min(1, min(position / rampFrames, remaining / rampFrames))
                }

                channel[writeIndex] = Float(sample * envelope * note.volume * 0.28)
                writeIndex += 1
            }
        }

        buffer.frameLength = AVAudioFrameCount(writeIndex)
        return buffer
    }

    // MARK: - Quiet hours

    private var isInQuietHours: Bool {
        guard prefs.quietHoursEnabled else { return false }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let hour = Double(now.hour ?? 0) + Double(now.minute ?? 0) / 60
        let start = prefs.quietHoursStart
        let end = prefs.quietHoursEnd
        // Ranges that cross midnight (22 -> 8) invert the comparison.
        return start <= end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
}

/// Where user-imported sound files live.
enum CustomSounds {
    static var directory: URL {
        let url = BridgeServer.supportDirectory.appendingPathComponent("custom-sounds")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func installed() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".wav") || $0.hasSuffix(".mp3") || $0.hasSuffix(".aiff") }
            .sorted() ?? []
    }

    @discardableResult
    static func importFile(at url: URL) -> String? {
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return url.lastPathComponent
        } catch {
            Log.sound.error("import failed: \(error.localizedDescription)")
            return nil
        }
    }
}
