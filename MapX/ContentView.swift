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
    @State private var searchingPage = false
    private enum SearchPurpose { case destination, home, work }
    @State private var searchPurpose: SearchPurpose = .destination
    @State private var arrivalPlace: SavedPlace?
    @State private var satellite = false
    @State private var showRecent = true
    @AppStorage("mapx.recentQueries") private var recentQueryData = ""
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
                } else if let place = arrivalPlace {
                    Marker(item: place.mapItem).tint(.red)
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
            .mapStyle(satellite ? MapStyle.hybrid(elevation: .flat) : MapStyle.standard(elevation: .flat))
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

            VStack(spacing: 10) {
                if guidance.isActive, let route = selectedRoute {
                    guidanceHeader
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Button { guidance.setVoiceEnabled(!guidance.voiceEnabled) } label: {
                                floatingIcon(guidance.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            }
                            .accessibilityLabel(guidance.voiceEnabled ? "关闭语音导航" : "开启语音导航")
                            .accessibilityIdentifier("mapx.voiceToggle")
                            Button { followUser() } label: { floatingIcon(exploring ? "location.fill" : "location.north.line") }
                                .accessibilityLabel("恢复导航跟随")
                        }
                    }
                    guidanceFooter(route)
                } else if let place = arrivalPlace {
                    Spacer(minLength: 0)
                    arrivalPanel(place)
                } else if searchingPage {
                    searchPage
                } else if destination != nil {
                    HStack {
                        Button { stopNavigation() } label: { floatingIcon("chevron.left") }
                            .accessibilityLabel("返回地图")
                        Spacer()
                        Button { satellite.toggle() } label: { floatingIcon("square.3.layers.3d") }
                            .accessibilityLabel("切换地图类型")
                    }
                    Spacer(minLength: 0)
                    HStack { Spacer(); locateButton }
                    routePanel
                } else {
                    Button { openSearch() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            Text("搜索地点或地址").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(16)
                        .background(panelBackground, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 8) {
                        shortcut("家", symbol: "house.fill", detail: savedPlaces.home?.name ?? "设置地点") {
                            if let home = savedPlaces.home { select(home.mapItem) } else { openSearch(.home) }
                        }
                        shortcut("公司", symbol: "briefcase.fill", detail: savedPlaces.work?.name ?? "设置地点") {
                            if let work = savedPlaces.work { select(work.mapItem) } else { openSearch(.work) }
                        }
                        shortcut("最近", symbol: "clock", detail: "\(savedPlaces.recent.count) 个地点") {
                            if savedPlaces.recent.isEmpty { openSearch() } else { showRecent.toggle() }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            locateButton
                            Button { satellite.toggle() } label: { floatingIcon("square.3.layers.3d") }
                                .accessibilityLabel("切换地图类型")
                        }
                    }
                    if showRecent && !savedPlaces.recent.isEmpty { homeRecentPanel }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if isSearching || (isRouting && guidance.isActive) {
                ProgressView(isRouting ? "规划路线…" : "搜索中…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
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
                let place = destination.map { SavedPlace(item: $0) }
                stopNavigation()
                arrivalPlace = place
                if let place {
                    camera = .region(MKCoordinateRegion(center: place.mapItem.placemark.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
                }
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
        guard let fix = locationService.location, abs(fix.timestamp.timeIntervalSinceNow) < 20, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65 else {
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

    private var recentQueries: [String] { recentQueryData.split(separator: "\n").map(String.init) }

    private func openSearch(_ purpose: SearchPurpose = .destination) {
        searchPurpose = purpose
        query = ""
        searchResults = []
        showingResults = false
        searchingPage = true
        searchFocused = true
    }

    private func cancelSearch() {
        searchTask?.cancel()
        isSearching = false
        searchFocused = false
        searchingPage = false
        searchPurpose = .destination
        showingResults = false
        searchResults = []
        query = ""
    }

    private func shortcut(_ title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.bold())
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 13))
            .shadow(color: .black.opacity(0.09), radius: 4, y: 2)
        }.buttonStyle(.plain)
    }

    private var homeRecentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 32, height: 4)
                .frame(maxWidth: .infinity).padding(.bottom, 10)
            Text("最近去过").font(.headline).padding(.horizontal, 14)
            ForEach(savedPlaces.recent.prefix(2)) { place in
                savedPlaceRow(place, symbol: "clock", title: place.name)
                    .contextMenu {
                        Button("设为家") { savedPlaces.markHome(place) }
                        Button("设为公司") { savedPlaces.markWork(place) }
                        Button("删除", role: .destructive) { savedPlaces.removeRecent(place) }
                    }
            }
        }
        .padding(.vertical, 12)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var searchPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索地点或地址", text: $query)
                        .focused($searchFocused).submitLabel(.search).onSubmit(search)
                        .accessibilityIdentifier("mapx.search")
                    if !query.isEmpty {
                        Button { query = ""; searchResults = []; showingResults = false; searchTask?.cancel(); isSearching = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }.padding(12).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                Button("取消") { cancelSearch() }
            }
            if searchPurpose != .destination {
                Text(searchPurpose == .home ? "选择家的位置" : "选择公司的位置").font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(searchResults, id: \.self) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name ?? "地点").font(.subheadline.bold())
                                    Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if let fix = locationService.location {
                                    Text(formattedDistance(fix.distance(from: CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude))))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 14)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if !recentQueries.isEmpty {
                        HStack {
                            Text("最近搜索").font(.headline)
                            Spacer()
                            Button("清空") { recentQueryData = "" }.font(.caption)
                        }.padding(.vertical, 14)
                        ForEach(recentQueries, id: \.self) { term in
                            Button { query = term; search() } label: {
                                HStack {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                    Text(term).font(.subheadline)
                                    Spacer()
                                }.padding(.vertical, 13)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                    if searchResults.isEmpty { savedPlacesPanel }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func arrivalPanel(_ place: SavedPlace) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("已到达目的地附近").font(.title2.bold())
            Text(place.name).font(.headline)
            Text(place.address).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 0) {
                Button { savedPlaces.add(place.mapItem); arrivalPlace = nil } label: {
                    Label("保留到最近", systemImage: "star.fill").frame(maxWidth: .infinity, alignment: .leading).padding(13)
                }
                Divider()
                Button { savedPlaces.markHome(place); arrivalPlace = nil } label: {
                    Label("设为家", systemImage: "house.fill").frame(maxWidth: .infinity, alignment: .leading).padding(13)
                }
                Divider()
                Button { savedPlaces.markWork(place); arrivalPlace = nil } label: {
                    Label("设为公司", systemImage: "briefcase.fill").frame(maxWidth: .infinity, alignment: .leading).padding(13)
                }
            }.buttonStyle(.plain).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Button { arrivalPlace = nil } label: {
                Text("完成").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var panelBackground: Color { Color(uiColor: .systemBackground) }

    private func floatingIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.primary)
            .frame(width: 50, height: 50)
            .background(panelBackground, in: Circle())
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }

    private var guidanceHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: maneuverSymbol)
                .font(.system(size: 46, weight: .bold))
                .frame(width: 66)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(guidance.hasRouteMatch ? formattedDistance(guidance.distanceToTurn) : "定位中")
                    .font(.system(size: 32, weight: .bold)).monospacedDigit()
                Text(guidance.nextInstruction)
                    .font(.system(size: 18, weight: .semibold)).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.06, green: 0.38, blue: 0.29), in: RoundedRectangle(cornerRadius: 18))
    }

    private func guidanceFooter(_ route: MKRoute) -> some View {
        let fraction = min(1, max(0, guidance.remainingDistance / max(1, route.distance)))
        let minutes = max(1, Int(ceil(route.expectedTravelTime * fraction / 60)))
        return VStack(spacing: 12) {
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 32, height: 4)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(minutes) 分钟").font(.system(size: 23, weight: .bold)).monospacedDigit()
                    Text(formattedDistance(guidance.remainingDistance)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date.now.addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 23, weight: .bold)).monospacedDigit()
                    Text("预计到达").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { stopNavigation() } label: {
                    Text("结束").font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .foregroundStyle(.white).background(Color.red, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("结束导航")
            }
        }
        .padding(16)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 32, height: 4)
                .frame(maxWidth: .infinity)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination?.name ?? "目的地").font(.title2.bold()).lineLimit(1)
                    Text(destination?.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { stopNavigation() } label: {
                    Image(systemName: "xmark").font(.subheadline.bold()).frame(width: 36, height: 36)
                        .background(Color.secondary.opacity(0.10), in: Circle())
                }.foregroundStyle(.primary)
            }
            HStack(spacing: 10) {
                modeButton("驾车", symbol: "car.fill", value: false)
                modeButton("步行", symbol: "figure.walk", value: true)
            }
            if let route = selectedRoute {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(max(1, Int(ceil(route.expectedTravelTime / 60)))) 分钟")
                        .font(.system(size: 30, weight: .bold)).monospacedDigit()
                    Text(formattedDistance(route.distance))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if routes.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(routes.indices, id: \.self) { index in
                                Button { chooseRoute(index) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(max(1, Int(ceil(routes[index].expectedTravelTime / 60)))) 分钟").font(.headline)
                                        Text(formattedDistance(routes[index].distance)).font(.caption)
                                    }
                                    .frame(minWidth: 80, alignment: .leading)
                                    .padding(12)
                                    .background(index == selectedRouteIndex ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(index == selectedRouteIndex ? Color.blue : Color.clear))
                                    .foregroundStyle(index == selectedRouteIndex ? Color.blue : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button { startNavigation() } label: {
                    Label("开始导航", systemImage: "location.north.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRouting)
                .accessibilityIdentifier("mapx.startNavigation")
            } else if isRouting {
                ProgressView("正在规划路线")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                Button("重新规划") { planRoute() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func modeButton(_ title: String, symbol: String, value: Bool) -> some View {
        Button {
            guard walking != value else { return }
            walking = value
            routes = []
            selectedRouteIndex = 0
            planRoute()
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(walking == value ? Color.white : Color.primary)
                .background(walking == value ? Color.blue : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(walking == value ? .isSelected : [])
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
        var terms = recentQueries.filter { $0 != term }
        terms.insert(term, at: 0)
        recentQueryData = Array(terms.prefix(8)).joined(separator: "\n")
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
        if searchingPage && searchPurpose != .destination {
            let place = SavedPlace(item: item)
            if searchPurpose == .home { savedPlaces.markHome(place) } else { savedPlaces.markWork(place) }
            cancelSearch()
            searchPurpose = .destination
            return
        }
        dismissKeyboard()
        stopNavigation()
        savedPlaces.add(item)
        destination = item
        routes = []
        selectedRouteIndex = 0
        showingResults = false
        query = item.name ?? ""
        searchingPage = false
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
            request.source = .forCurrentLocation()
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
        guidance.update(fix)
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
        searchingPage = false
        arrivalPlace = nil
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
