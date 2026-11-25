import UIKit
import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationService = LocationService()
    @StateObject private var guidance = NavigationSession()
    @StateObject private var savedPlaces = SavedPlacesStore()

    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var showingResults = false
    @State private var destination: MKMapItem?
    @State private var routes: [MKRoute] = []
    @State private var selectedRouteIndex = 0
    @State private var walking = false
    @State private var searchTask: Task<Void, Never>?
    @State private var routeTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var isRouting = false
    @State private var errorMessage: String?
    @State private var hasCenteredOnUser = false
    @State private var visibleMapDistance: CLLocationDistance = 8_000
    @State private var repeatedLocateDistance: CLLocationDistance?
    @State private var pendingLocate = false
    @State private var exploring = false
    @State private var followRecoveryTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var selectedRoute: MKRoute? {
        routes.indices.contains(selectedRouteIndex) ? routes[selectedRouteIndex] : nil
    }

    private var mapCameraBounds: MapCameraBounds? {
        if let limit = repeatedLocateDistance {
            return MapCameraBounds(minimumDistance: 25, maximumDistance: limit)
        }
        return nil
    }

    var body: some View {
        ZStack {
            if guidance.isActive, let route = selectedRoute {
                DrivingMap(route: route, destination: destination, fix: locationService.location,
                           displayCoordinate: guidance.displayCoordinate, walking: walking,
                           exploring: exploring, onExplore: {
                    exploring = true
                    scheduleFollowRecovery()
                })
                .ignoresSafeArea()
            } else {
            Map(position: $camera, bounds: mapCameraBounds) {
                UserAnnotation()
                if let destination {
                    Marker(item: destination).tint(.red)
                }
                ForEach(routes.indices, id: \.self) { index in
                    MapPolyline(routes[index].polyline)
                        .stroke(index == selectedRouteIndex ? Color.blue : Color.gray.opacity(0.5),
                                lineWidth: index == selectedRouteIndex ? 7 : 4)
                }
            }
            .simultaneousGesture(MagnifyGesture().onChanged { _ in
                repeatedLocateDistance = nil
            })
            .mapStyle(.standard(elevation: .flat))
            .onMapCameraChange(frequency: .onEnd) { context in
                let distance = context.camera.distance
                if distance.isFinite && distance > 0 {
                    visibleMapDistance = distance
                }

            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                if guidance.isActive, let route = selectedRoute {
                    HStack(spacing: 16) {
                        Image(systemName: maneuverSymbol)
                            .font(.system(size: 35, weight: .bold))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(formattedDistance(guidance.distanceToTurn))
                                .font(.title.bold()).monospacedDigit()
                            Text(guidance.nextInstruction)
                                .font(.headline).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        Button {
                            guidance.setVoiceEnabled(!guidance.voiceEnabled)
                        } label: {
                            Image(systemName: guidance.voiceEnabled
                                  ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .accessibilityLabel(guidance.voiceEnabled ? "关闭语音导航" : "开启语音导航")
                        .accessibilityIdentifier("mapx.voiceToggle")
                    }
                    .padding(16)
                    .foregroundStyle(.white)
                    .background(Color(red: 0.07, green: 0.10, blue: 0.17).opacity(0.96),
                                in: RoundedRectangle(cornerRadius: 24))
                    Spacer()
                    if exploring {
                        Button { followUser() } label: {
                            Image(systemName: "location.fill")
                                .frame(width: 46, height: 46)
                                .background(.regularMaterial, in: Circle())
                        }
                        .accessibilityLabel("恢复导航跟随")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let fraction = min(1, guidance.remainingDistance / max(1, route.distance))
                    let minutes = max(1, Int(ceil(route.expectedTravelTime * fraction / 60)))
                    HStack(spacing: 4) {
                        metric(Date.now.addingTimeInterval(Double(minutes) * 60)
                            .formatted(date: .omitted, time: .shortened), "到达")
                        metric(String(minutes), "分钟")
                        metric(guidance.remainingDistance < 1000 ? String(Int(guidance.remainingDistance.rounded())) : String(format: "%.1f", guidance.remainingDistance / 1000), guidance.remainingDistance < 1000 ? "米" : "公里")
                        Button { stopNavigation() } label: {
                            Image(systemName: "xmark").font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .accessibilityLabel("结束导航")
                    }
                    .padding(12)
                    .foregroundStyle(.white)
                    .background(Color(red: 0.07, green: 0.10, blue: 0.17).opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
                } else {
                    searchBar
                    if showingResults { searchResultsView }
                    else if searchFocused && query.isEmpty { savedPlacesPanel }
                    if destination != nil && !showingResults {
                        Picker("出行方式", selection: $walking) {
                            Label("驾车", systemImage: "car.fill").tag(false)
                            Label("步行", systemImage: "figure.walk").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .onChange(of: walking) { _, _ in
                            routes = []
                            selectedRouteIndex = 0
                            planRoute()
                        }
                    }
                    Spacer(minLength: 12)
                    HStack(alignment: .bottom, spacing: 12) {
                        if let selectedRoute { routePanel(selectedRoute) }
                        else { Spacer(minLength: 0) }
                        locateButton
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)

            if isSearching || isRouting {
                ProgressView(isRouting ? "规划路线…" : "搜索中…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .preferredColorScheme(guidance.isActive ? .dark : nil)
        .tint(.blue)
        .onAppear {
            let session = guidance
            locationService.onNavigationLocationUpdate = { [weak session] fix in
                Task { @MainActor in session?.update(fix) }
            }
            let gpsService = locationService
            guidance.onArrival = { [weak gpsService] in
                // The background GPS must stop even if SwiftUI doesn't render
                // the arrival view until the screen is unlocked.
                gpsService?.setNavigating(false)
            }
            locationService.setAppForeground(scenePhase == .active)
            locationService.requestLocation()
        }
        .onChange(of: scenePhase) { _, phase in
            locationService.setAppForeground(phase == .active)
            if phase == .active && guidance.isActive {
                followUser()
            }
        }
        .onReceive(locationService.$location.compactMap { $0 }) { fix in
            if pendingLocate {
                pendingLocate = false
                hasCenteredOnUser = true
                zoomToMapKitUserLocation()
            } else if !hasCenteredOnUser {
                hasCenteredOnUser = true
                camera = .userLocation(followsHeading: false, fallback: .automatic)
            }
        }
        .onChange(of: camera.positionedByUser) { _, movedByUser in
            if movedByUser {
                repeatedLocateDistance = nil

            }
        }
        .onChange(of: guidance.needsReroute) { _, _ in
            guard guidance.isActive, !isRouting, let fix = locationService.location else { return }
            planRoute(from: fix, continueNavigation: true)
        }
        .onChange(of: locationService.authorizationStatus) { _, status in
            if guidance.isActive && (status == .denied || status == .restricted) {
                stopNavigation()
                errorMessage = "定位权限已关闭，导航已结束。"
            }
        }
        .onChange(of: guidance.arrived) { _, arrived in
            if arrived {
                stopNavigation()
                errorMessage = "已到达目的地附近，导航已自动结束。"
            }
        }
        .alert("提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var maneuverSymbol: String {
        let instruction = guidance.nextInstruction.lowercased()
        if instruction.contains("掉头") || instruction.contains("调头") || instruction.contains("u-turn") { return "arrow.uturn.backward" }
        if instruction.contains("左转") || instruction.contains("turn left") { return "arrow.turn.up.left" }
        if instruction.contains("右转") || instruction.contains("turn right") { return "arrow.turn.up.right" }
        if instruction.contains("直行") || instruction.contains("straight") { return "arrow.up" }
        return "signpost.right.fill"
    }

    private func followUser() {
        followRecoveryTask?.cancel()
        exploring = false
    }

    private func scheduleFollowRecovery() {
        followRecoveryTask?.cancel()
        guard guidance.isActive else { return }
        followRecoveryTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(9))
            } catch {
                return
            }
            guard guidance.isActive, exploring else { return }
            followUser()
        }
    }

    private func locateAndZoom() {
        guard locationService.isAuthorized else {
            if locationService.authorizationStatus == .notDetermined {
                pendingLocate = true
                locationService.requestLocation()
            } else {
                errorMessage = "请在系统设置中允许 MapX 使用定位。"
            }
            return
        }
        guard locationService.location != nil else {
            pendingLocate = true
            locationService.requestLocation()
            return
        }
        zoomToMapKitUserLocation()
    }

    private func zoomToMapKitUserLocation() {
        // Keep the limit until a gesture or a route selection takes over the camera.
        let distance = min(repeatedLocateDistance ?? visibleMapDistance, visibleMapDistance)
        let nextDistance = min(distance, max(35, min(distance, 12_000) * 0.65))
        if repeatedLocateDistance == nil {
            camera = .userLocation(followsHeading: false, fallback: .automatic)
        }
        repeatedLocateDistance = nextDistance
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索地点或地址", text: $query)
                .focused($searchFocused)
                .onChange(of: query) { _, value in
                    if value.isEmpty && (destination != nil || isSearching || showingResults) { stopNavigation() }
                }
                .submitLabel(.search)
                .onSubmit(search)
                .accessibilityIdentifier("mapx.search")
            if !query.isEmpty {
                Button {
                    stopNavigation()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.09), radius: 8, y: 3)
    }

    private var searchResultsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(searchResults, id: \.self) { item in
                    Button {
                        select(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? "未命名地点")
                                .font(.subheadline.weight(.semibold))
                            Text(item.placemark.title ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 14)
                }
            }
        }
        .frame(maxHeight: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var savedPlacesPanel: some View {
        if savedPlaces.home != nil || savedPlaces.work != nil || !savedPlaces.recent.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let home = savedPlaces.home {
                        savedPlaceRow(home, symbol: "house.fill", title: "家")
                    }
                    if let work = savedPlaces.work {
                        savedPlaceRow(work, symbol: "building.2.fill", title: "公司")
                    }
                    if !savedPlaces.recent.isEmpty {
                        HStack {
                            Text("最近目的地")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("清空") { savedPlaces.clearRecent() }
                                .font(.caption)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                        ForEach(savedPlaces.recent.prefix(6)) { place in
                            savedPlaceRow(place, symbol: "clock.arrow.circlepath", title: place.name)
                                .contextMenu {
                                    Button("设为家") { savedPlaces.markHome(place) }
                                    Button("设为公司") { savedPlaces.markWork(place) }
                                    Button("删除此记录", role: .destructive) {
                                        savedPlaces.removeRecent(place)
                                    }
                                }
                        }
                        Text("长按最近目的地可设为家或公司")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func savedPlaceRow(_ place: SavedPlace, symbol: String, title: String) -> some View {
        Button {
            select(place.mapItem)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(place.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var locateButton: some View {
        Button(action: locateAndZoom) {
            Image(systemName: "location.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.09), radius: 8, y: 3)
        }
        .accessibilityLabel("定位并放大")
    }

    private func routePanel(_ route: MKRoute) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                Text(destination?.name ?? "目的地")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(Int((route.expectedTravelTime / 60).rounded())) 分钟 · \(formattedDistance(route.distance))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            if routes.count > 1 {
                HStack(spacing: 8) {
                    ForEach(routes.indices, id: \.self) { index in
                        Button("路线 \(index + 1)") {
                            chooseRoute(index)
                        }
                        .font(.caption.weight(index == selectedRouteIndex ? .bold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(index == selectedRouteIndex ? Color.white : Color.primary)
                        .background(index == selectedRouteIndex ? Color.blue : Color.gray.opacity(0.12),
                                    in: Capsule())
                    }
                }
            }

                Button {
                    startNavigation()
                } label: {
                    Text("开始导航")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRouting)
                .accessibilityIdentifier("mapx.startNavigation")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
    }

    private func formattedDistance(_ meters: CLLocationDistance) -> String {
        if meters >= 1000 { return String(format: "%.1f 公里", meters / 1000) }
        return "\(Int(max(0, meters).rounded())) 米"
    }

    private func dismissKeyboard() {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func search() {
        dismissKeyboard()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            defer { if !Task.isCancelled { isSearching = false } }
            do {
                let request = MKLocalSearch.Request()
                if let mapRegion = camera.region {
                    request.region = mapRegion
                }
                request.naturalLanguageQuery = term
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                searchResults = Array(response.mapItems.prefix(8))
                showingResults = true
                if searchResults.isEmpty {
                    errorMessage = "没有找到相关地点"
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "搜索失败：\(error.localizedDescription)"
            }
        }
    }

    private func select(_ item: MKMapItem) {
        dismissKeyboard()
        stopNavigation()
        savedPlaces.add(item)
        destination = item
        routes = []
        selectedRouteIndex = 0
        showingResults = false
        query = item.name ?? ""
        camera = .region(MKCoordinateRegion(center: item.placemark.coordinate,
                                             latitudinalMeters: 5000,
                                             longitudinalMeters: 5000))
        planRoute()
    }

    private func planRoute(from fix: CLLocation? = nil, continueNavigation: Bool = false) {
        guard let destination else { return }
        routeTask?.cancel()
        let requestedWalking = walking
        isRouting = true
        routeTask = Task {
            defer { if !Task.isCancelled { isRouting = false } }
            let request = MKDirections.Request()
            request.source = (fix ?? locationService.location).map { MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate)) } ?? .forCurrentLocation()
            request.destination = destination
            request.transportType = requestedWalking ? .walking : .automobile
            request.requestsAlternateRoutes = true

            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled, requestedWalking == walking,
                      self.destination === destination,
                      !continueNavigation || guidance.isActive else { return }
                guard !response.routes.isEmpty else {
                    errorMessage = requestedWalking ? "未找到步行路线" : "未找到驾车路线"
                    return
                }
                routes = response.routes
                selectedRouteIndex = 0
                if continueNavigation {
                    guard guidance.isActive else { return }
                    guidance.replaceRoute(response.routes[0],
                                          destination: destination.placemark.coordinate)
                    if let fix = locationService.location { guidance.update(fix) }
                } else {
                    repeatedLocateDistance = nil
                    camera = .rect(response.routes[0].polyline.boundingMapRect)
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "路线规划失败：\(error.localizedDescription)"
            }
        }
    }

    private func chooseRoute(_ index: Int) {
        repeatedLocateDistance = nil
        guard routes.indices.contains(index) else { return }
        selectedRouteIndex = index
        camera = .rect(routes[index].polyline.boundingMapRect)
        if guidance.isActive {
            if let destination {
                guidance.replaceRoute(routes[index],
                                      destination: destination.placemark.coordinate)
            }
        }
    }

    private func startNavigation() {
        guard !isRouting, let selectedRoute, let destination else { return }
        guard locationService.isAuthorized else {
            locationService.requestLocation()
            errorMessage = "请允许定位后再开始导航。"
            return
        }
        guard locationService.location != nil else {
            errorMessage = "尚未获得 GPS 位置，请稍后重试。"
            return
        }
        dismissKeyboard()
        showingResults = false
        followUser()
        guidance.start(selectedRoute, destination: destination.placemark.coordinate, walking: walking)
        locationService.setNavigating(true, walking: walking)
        if let fix = locationService.location {
            guidance.update(fix)
        }
    }

    private func stopNavigation() {
        followRecoveryTask?.cancel()
        pendingLocate = false
        repeatedLocateDistance = nil
        routeTask?.cancel()
        isRouting = false
        searchTask?.cancel()
        isSearching = false
        if guidance.isActive { guidance.stop() }
        destination = nil
        routes = []
        selectedRouteIndex = 0
        query = ""
        searchResults = []
        showingResults = false
        errorMessage = nil
        camera = .userLocation(fallback: .automatic)
        locationService.setNavigating(false)
    }
}
