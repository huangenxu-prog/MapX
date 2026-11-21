import AVFoundation
import Combine
import CoreLocation
import MapKit

/// Activates the playback session only while a spoken instruction is audible,
/// allowing other apps' music to return to its normal volume afterwards.
private final class VoicePromptPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var enabled = true

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // A denied or interrupted audio session should never stop GPS guidance.
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        deactivate()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { deactivate() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { deactivate() }
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// An active navigation session receives fresh GPS fixes from LocationService
/// directly (also when the phone is locked). Not a lane/elevation matching engine.
@MainActor
final class NavigationSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var nextInstruction = "沿当前路线行驶"
    @Published private(set) var distanceToTurn: CLLocationDistance = 0
    @Published private(set) var remainingDistance: CLLocationDistance = 0
    @Published private(set) var needsReroute = 0
    @Published private(set) var arrived = false
    @Published private(set) var voiceEnabled: Bool

    /// Runs immediately when GPS confirms arrival; independent of view rendering.
    var onArrival: (() -> Void)?

    private var route: MKRoute?
    private var destinationCoordinate: CLLocationCoordinate2D?
    private let voice = VoicePromptPlayer()
    private var announced: Set<String> = []
    private var offRouteSamples = 0
    private var arrivalSamples = 0
    private var lastRerouteAt = Date.distantPast

    init() {
        voiceEnabled = UserDefaults.standard.object(forKey: "mapx.voiceEnabled") as? Bool ?? true
        voice.enabled = voiceEnabled
    }

    func setVoiceEnabled(_ enabled: Bool) {
        voiceEnabled = enabled
        voice.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: "mapx.voiceEnabled")
        if !enabled { voice.stop() }
        else if isActive { voice.say("语音导航已开启") }
    }

    func start(_ newRoute: MKRoute, destination: CLLocationCoordinate2D) {
        stop()
        arrived = false
        route = newRoute
        destinationCoordinate = destination
        isActive = true
        remainingDistance = newRoute.distance
        nextInstruction = newRoute.steps.first(where: { !$0.instructions.isEmpty })?.instructions
            ?? "沿当前路线行驶"
        voice.say("开始导航")
    }

    /// Replanning is still the same trip, not a fresh start.
    func replaceRoute(_ newRoute: MKRoute, destination: CLLocationCoordinate2D) {
        guard isActive else { return }
        route = newRoute
        destinationCoordinate = destination
        announced.removeAll()
        offRouteSamples = 0
        arrivalSamples = 0
        remainingDistance = newRoute.distance
        nextInstruction = newRoute.steps.first(where: { !$0.instructions.isEmpty })?.instructions
            ?? "沿当前路线行驶"
        voice.say("路线已更新")
    }

    func stop() {
        voice.stop()
        isActive = false
        route = nil
        destinationCoordinate = nil
        announced.removeAll()
        offRouteSamples = 0
        arrivalSamples = 0
        remainingDistance = 0
        distanceToTurn = 0
        nextInstruction = "沿当前路线行驶"
    }

    func update(_ fix: CLLocation) {
        guard isActive, let route,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65,
              abs(fix.timestamp.timeIntervalSinceNow) < 20 else { return }

        let progress = RouteGeometry.progress(on: route, location: fix)
        remainingDistance = progress.remainingDistance
        distanceToTurn = progress.distanceToNextTurn

        // Avoid false arrival caused by the route passing near the destination
        // earlier, GPS jumps, or an inaccurate fix. Require two close, slow fixes.
        if let endpoint = destinationCoordinate {
            let metersToDestination = fix.distance(from:
                CLLocation(latitude: endpoint.latitude, longitude: endpoint.longitude))
            let slowEnough = fix.speed < 0 || fix.speed < 8
            if metersToDestination < 40 &&
                progress.distanceFromRoute < 55 &&
                progress.remainingDistance < 150 &&
                fix.horizontalAccuracy <= 35 && slowEnough {
                arrivalSamples += 1
            } else {
                arrivalSamples = 0
            }
            if arrivalSamples >= 2 {
                finishArrival()
                return
            }
        }

        if let stepIndex = progress.nextStepIndex {
            let instruction = route.steps[stepIndex].instructions
            nextInstruction = instruction
            if (90..<400).contains(progress.distanceToNextTurn) {
                speakOnce("approach-\(stepIndex)",
                          text: "前方\(Int(progress.distanceToNextTurn))米，\(instruction)")
            }
            if progress.distanceToNextTurn < 90 {
                speakOnce("near-\(stepIndex)", text: instruction)
            }
        } else {
            nextInstruction = "继续行驶至目的地"
        }

        if progress.distanceFromRoute > 130 && max(0, fix.speed) > 2 {
            offRouteSamples += 1
        } else {
            offRouteSamples = 0
        }
        if offRouteSamples >= 4, Date().timeIntervalSince(lastRerouteAt) > 30 {
            lastRerouteAt = Date()
            offRouteSamples = 0
            needsReroute += 1
            voice.say("偏离路线，正在重新规划")
        }
    }

    private func finishArrival() {
        // Keep the final utterance alive after isActive becomes false. The View
        // clears the map and disables background GPS without cutting off speech.
        route = nil
        destinationCoordinate = nil
        isActive = false
        arrived = true
        offRouteSamples = 0
        arrivalSamples = 0
        onArrival?()
        voice.stop()
        voice.say("已到达目的地附近，导航结束")
    }

    private func speakOnce(_ key: String, text: String) {
        guard !announced.contains(key) else { return }
        announced.insert(key)
        voice.say(text)
    }
}
