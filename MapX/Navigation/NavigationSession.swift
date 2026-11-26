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
    @Published private(set) var hasRouteMatch = false
    @Published private(set) var diagnostic = "尚未收到定位"
    private var diagnosticHistory: [String] = []
    var diagnosticReport: String { diagnosticHistory.joined(separator: "\n") }
    private func record(_ message: String) {
        diagnostic = message
        diagnosticHistory.append(message)
        if diagnosticHistory.count > 40 { diagnosticHistory.removeFirst() }
    }
    func compareMapLocation(_ native: CLLocation, raw: CLLocation?) {
        guard isActive, let route, let raw,
              abs(native.timestamp.timeIntervalSinceNow) < 20,
              abs(native.timestamp.timeIntervalSince(raw.timestamp)) < 5,
              native.horizontalAccuracy >= 0 else { return }
        let rawProgress = RouteGeometry.progress(on: route, location: raw)
        let mapProgress = RouteGeometry.progress(on: route, location: native)
        record(String(format: "地图对照 | 两定位相差 %.1fm | 原始偏距 %.1fm | 地图偏距 %.1fm", native.distance(from: raw), rawProgress.distanceFromRoute, mapProgress.distanceFromRoute))
    }

    func recordRoutingSource(_ source: CLLocation?, responseSource: CLLocation?, newRoute: MKRoute) {
        guard isActive, let source, newRoute.polyline.pointCount > 0 else { return }
        let gap = MKMapPoint(source.coordinate).distance(to: newRoute.polyline.points()[0])
        let responseGap = responseSource.map { source.distance(from: $0) } ?? -1
        record(String(format: "重规划 | 请求起点至路线 %.1fm | 响应起点偏差 %.1fm", gap, responseGap))
    }

    @Published private(set) var remainingDistance: CLLocationDistance = 0
    @Published private(set) var needsReroute = 0
    @Published private(set) var arrived = false
    @Published private(set) var displayCoordinate: CLLocationCoordinate2D?
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
    private var lastFix: CLLocation?
    private var matchedDistance: CLLocationDistance?
    private var matchedAt: Date?
    private var firstFixAt: Date?
    private var walking = false

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

    func start(_ newRoute: MKRoute, destination: CLLocationCoordinate2D, walking: Bool = false) {
        stop()
        arrived = false
        diagnosticHistory.removeAll()
        record("导航启动 · 路线点数 \(newRoute.polyline.pointCount) · 距离 \(Int(newRoute.distance))m")
        self.walking = walking
        lastRerouteAt = .distantPast
        route = newRoute
        destinationCoordinate = destination
        isActive = true
        remainingDistance = newRoute.distance
        nextInstruction = newRoute.steps.first(where: { !$0.instructions.isEmpty && $0.distance > 0 })?.instructions
            ?? (walking ? "沿当前路线步行" : "沿当前路线行驶")
        distanceToTurn = newRoute.steps.first(where: { $0.distance > 0 })?.distance ?? newRoute.distance
        voice.say("开始导航")
    }

    /// Replanning is still the same trip, not a fresh start.
    func replaceRoute(_ newRoute: MKRoute, destination: CLLocationCoordinate2D) {
        guard isActive else { return }
        route = newRoute
        destinationCoordinate = destination
        lastFix = nil
        matchedDistance = nil
        hasRouteMatch = false
        displayCoordinate = nil
        matchedAt = nil
        firstFixAt = nil
        distanceToTurn = newRoute.steps.first(where: { $0.distance > 0 })?.distance ?? newRoute.distance
        announced.removeAll()
        offRouteSamples = 0
        arrivalSamples = 0
        remainingDistance = newRoute.distance
        nextInstruction = newRoute.steps.first(where: { !$0.instructions.isEmpty && $0.distance > 0 })?.instructions
            ?? "沿当前路线行驶"
        voice.say("路线已更新")
    }

    func stop() {
        voice.stop()
        isActive = false
        route = nil
        destinationCoordinate = nil
        lastFix = nil
        matchedDistance = nil
        hasRouteMatch = false
        displayCoordinate = nil
        matchedAt = nil
        firstFixAt = nil
        announced.removeAll()
        offRouteSamples = 0
        arrivalSamples = 0
        remainingDistance = 0
        distanceToTurn = 0
        nextInstruction = "沿当前路线行驶"
    }

    func update(_ fix: CLLocation) {
        guard isActive, let route else { return }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65,
              abs(fix.timestamp.timeIntervalSinceNow) < 20 else {
            record(String(format: "拒绝 GPS：精度 %.1fm，时间差 %.1fs", fix.horizontalAccuracy, abs(fix.timestamp.timeIntervalSinceNow)))
            return
        }

        guard lastFix.map({ fix.timestamp > $0.timestamp }) ?? true else { return }
        lastFix = fix
        if firstFixAt == nil { firstFixAt = fix.timestamp }
        let elapsed = max(1, fix.timestamp.timeIntervalSince(matchedAt ?? firstFixAt ?? fix.timestamp))
        let speedLimit = walking ? 4.0 : 55.0
        let measuredSpeed = fix.speed >= 0 ? min(speedLimit, fix.speed) : (walking ? 2.0 : 12.0)
        let advance = max(35, min(800, elapsed * max(walking ? 2 : 8, measuredSpeed) * 1.8 + fix.horizontalAccuracy * 2))
        var progress = RouteGeometry.progress(on: route, location: fix,
                                              previousDistance: matchedDistance,
                                              maximumAdvance: advance)
        let matchTolerance = walking ? max(25, fix.horizontalAccuracy * 1.5) : max(45, fix.horizontalAccuracy * 1.5)
        if progress.distanceFromRoute > matchTolerance, matchedDistance != nil {
            let candidate = RouteGeometry.progress(on: route, location: fix)
            if candidate.distanceFromRoute <= matchTolerance,
               abs(candidate.distanceAlongRoute - (matchedDistance ?? 0)) <= max(advance, 150) {
                progress = candidate
            }
        }
        let matched = progress.distanceFromRoute.isFinite && progress.distanceFromRoute <= matchTolerance
        // Display-only snap: keep raw GPS for arrival and off-route decisions.
        let displayTolerance = min(walking ? 18.0 : 30.0, max(8, fix.horizontalAccuracy * 1.5))
        displayCoordinate = matched && progress.distanceFromRoute <= displayTolerance ? progress.matchedCoordinate : nil
        hasRouteMatch = matched
        let points = route.polyline.points()
        let startGap = route.polyline.pointCount > 0 ? MKMapPoint(fix.coordinate).distance(to: points[0]) : -1
        record(String(format: "%@ | GPS精度 %.1fm | 路线偏距 %.1fm | 起点距离 %.1fm | 已行 %.1fm | 点数 %d", matched ? "匹配成功" : "匹配失败", fix.horizontalAccuracy, progress.distanceFromRoute, startGap, progress.distanceAlongRoute, route.polyline.pointCount))
        if matched {
            matchedDistance = progress.distanceAlongRoute
            matchedAt = fix.timestamp
            remainingDistance = progress.remainingDistance
            distanceToTurn = progress.distanceToNextTurn
        }

        // Avoid false arrival caused by the route passing near the destination
        // earlier, GPS jumps, or an inaccurate fix. Require two close, slow fixes.
        if let endpoint = destinationCoordinate {
            let metersToDestination = fix.distance(from:
                CLLocation(latitude: endpoint.latitude, longitude: endpoint.longitude))
            let slowEnough = fix.speed >= 0 && fix.speed < (walking ? 3 : 8)
            if matched && metersToDestination < (walking ? 25 : 40) &&
                progress.distanceFromRoute < 55 &&
                progress.remainingDistance < (walking ? 50 : 100) &&
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

        if matched, let stepIndex = progress.nextStepIndex {
            let instruction = route.steps[stepIndex].instructions
            nextInstruction = instruction
            if progress.distanceToNextTurn >= (walking ? 20 : 90) && progress.distanceToNextTurn < (walking ? 100 : 400) {
                speakOnce("approach-\(stepIndex)",
                          text: "前方\(Int(progress.distanceToNextTurn))米，\(instruction)")
            }
            if progress.distanceToNextTurn < (walking ? 20 : 90) {
                speakOnce("near-\(stepIndex)", text: instruction)
            }
        } else if matched {
            nextInstruction = walking ? "继续步行至目的地" : "继续行驶至目的地"
        }

        if !matched {
            offRouteSamples += 1
            nextInstruction = "正在确认当前位置与路线"
        } else {
            offRouteSamples = 0
        }
        if offRouteSamples >= (matchedDistance == nil ? 1 : 3), Date().timeIntervalSince(lastRerouteAt) > (walking ? 20 : 30) {
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
        displayCoordinate = nil
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
