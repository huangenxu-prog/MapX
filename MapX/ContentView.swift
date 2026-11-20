import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var destination: MKMapItem?
    @State private var route: MKRoute?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var showingResults = false
    @State private var locationManager = CLLocationManager()

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                UserAnnotation()
                if let destination {
                    Marker(item: destination)
                        .tint(.red)
                }
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(.blue, lineWidth: 6)
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .mapStyle(.standard(elevation: .flat))
            .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索地点或地址", text: $query)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                            showingResults = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)

                if showingResults {
                    VStack(spacing: 0) {
                        ForEach(results, id: \.self) { item in
                            Button {
                                select(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? "未命名地点")
                                        .font(.headline)
                                    Text(item.placemark.title ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                Spacer()

                HStack(alignment: .bottom) {
                    if let route {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(destination?.name ?? "目的地")
                                .font(.headline)
                            Text("\(Int(route.expectedTravelTime / 60)) 分钟 · \(String(format: "%.1f", route.distance / 1000)) 公里")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("路线预览 · 暂不提供实时语音导航")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("结束路线") {
                                self.route = nil
                                destination = nil
                            }
                            .font(.subheadline)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                    Spacer()
                    Button {
                        locationManager.requestWhenInUseAuthorization()
                        camera = .userLocation(fallback: .automatic)
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.title3)
                            .frame(width: 54, height: 54)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("定位到当前位置")
                }
            }
            .padding()
        }
        .tint(.blue)
        .overlay {
            if loading {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            loading = true
            defer { loading = false }
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = term
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                results = Array(response.mapItems.prefix(8))
                showingResults = true
                if results.isEmpty { errorMessage = "没有找到相关地点" }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "搜索失败：\(error.localizedDescription)"
            }
        }
    }

    private func select(_ item: MKMapItem) {
        destination = item
        route = nil
        showingResults = false
        query = item.name ?? ""
        camera = .region(MKCoordinateRegion(center: item.placemark.coordinate,
                                             latitudinalMeters: 5000,
                                             longitudinalMeters: 5000))
        Task {
            loading = true
            defer { loading = false }
            let request = MKDirections.Request()
            request.source = .forCurrentLocation()
            request.destination = item
            request.transportType = .automobile
            do {
                let response = try await MKDirections(request: request).calculate()
                guard destination == item else { return }
                route = response.routes.first
                if let route {
                    camera = .rect(route.polyline.boundingMapRect)
                } else {
                    errorMessage = "未找到驾车路线"
                }
            } catch {
                errorMessage = "路线规划失败：\(error.localizedDescription)"
            }
        }
    }
}
