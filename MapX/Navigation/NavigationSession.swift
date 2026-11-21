import AVFoundation
import Combine
import CoreLocation
import MapKit

/// Foreground, GPS-based guidance. This is not equivalent to Apple's navigation engine.
/// There is no lane-level positioning or bridge-elevation data in this service.
@MainActor
final class NavigationSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var nextInstruction = "沿当前路线行驶"
    @Published private(set) var distanceToTurn: CLLocationDistance = 0
    @Published private(set) var remainingDistance: CLLocationDistance = 0
    @Published private(set) var needsReroute = 0
    @Published private(set) var arrived = false

    private var route: MKRoute?
    private let voice = AVSpeechSynthesizer()
    private var announced: Set<String> = []
    private var offRouteSamples = 0
    private var lastRerouteAt = Date.distantPast

    func start(_ route: MKRoute) {
        stop()
        self.route = route
        isActive = true
        arrived = false
        remainingDistance = route.distance
        nextInstruction = route.steps.first(where: { !$0.instructions.isEmpty })?.instructions ?? "沿当前路线行驶"
        speak("开始导航")
    }

    func stop() {
        voice.stopSpeaking(at: .immediate)
        isActive = false
        route = nil
        announced.removeAll()
        offRouteSamples = 0
        remainingDistance = 0
        distanceToTurn = 0
        nextInstruction = "沿当前路线行驶"
    }

    func update(_ fix: CLLocation) {
        guard isActive, let route,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65 else { return }

        let progress = RouteGeometry.progress(on: route, location: fix)
        remainingDistance = progress.remainingDistance
        distanceToTurn = progress.distanceToNextTurn

        if progress.remainingDistance < 35, progress.distanceFromRoute < 45 {
            arrived = true
            stop()
            speak("已到达目的地附近")
            return
        }

        if let stepIndex = progress.nextStepIndex {
            let text = route.steps[stepIndex].instructions
            nextInstruction = text
            if (90..<400).contains(progress.distanceToNextTurn) {
                speakOnce("approach-\(stepIndex)", text: "前方\(Int(progress.distanceToNextTurn))米，\(text)")
            }
            if progress.distanceToNextTurn < 90 {
                speakOnce("near-\(stepIndex)", text: text)
            }
        } else {
            nextInstruction = "继续行驶至目的地"
        }

        // Avoid rerouting because of one inaccurate GPS sample or minor urban-canyon noise.
        if progress.distanceFromRoute > 130 && max(0, fix.speed) > 2 {
            offRouteSamples += 1
        } else {
            offRouteSamples = 0
        }
        if offRouteSamples >= 4, Date().timeIntervalSince(lastRerouteAt) > 30 {
            lastRerouteAt = Date()
            offRouteSamples = 0
            needsReroute += 1
        }
    }

    private func speakOnce(_ key: String, text: String) {
        guard !announced.contains(key) else { return }
        announced.insert(key)
        speak(text)
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        voice.speak(utterance)
    }
}
