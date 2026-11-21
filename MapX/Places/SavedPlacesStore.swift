import Combine
import CoreLocation
import Foundation
import MapKit

struct SavedPlace: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let lastSelected: Date

    init(item: MKMapItem) {
        id = UUID()
        name = item.name ?? item.placemark.title ?? "目的地"
        address = item.placemark.title ?? ""
        latitude = item.placemark.coordinate.latitude
        longitude = item.placemark.coordinate.longitude
        lastSelected = Date()
    }

    var mapItem: MKMapItem {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }

    func refersToSameLocation(as other: SavedPlace) -> Bool {
        guard name == other.name else { return false }
        let a = CLLocation(latitude: latitude, longitude: longitude)
        let b = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return a.distance(from: b) < 60
    }
}

/// Only explicitly selected destinations are saved. No account, cloud sync,
/// route traces, or automatic recording of the user's continuous GPS movement.
@MainActor
final class SavedPlacesStore: ObservableObject {
    @Published private(set) var recent: [SavedPlace] = []
    @Published private(set) var home: SavedPlace?
    @Published private(set) var work: SavedPlace?

    private struct StoredData: Codable {
        var recent: [SavedPlace]
        var home: SavedPlace?
        var work: SavedPlace?
    }

    private let key = "mapx.savedDestinations.v1"
    private let maximumRecent = 12

    init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredData.self, from: data) else {
            return
        }
        recent = Array(stored.recent.prefix(maximumRecent))
        home = stored.home
        work = stored.work
    }

    func add(_ item: MKMapItem) {
        let place = SavedPlace(item: item)
        recent.removeAll { $0.refersToSameLocation(as: place) }
        recent.insert(place, at: 0)
        if recent.count > maximumRecent {
            recent = Array(recent.prefix(maximumRecent))
        }
        persist()
    }

    func markHome(_ place: SavedPlace) {
        home = place
        persist()
    }

    func markWork(_ place: SavedPlace) {
        work = place
        persist()
    }

    func removeRecent(_ place: SavedPlace) {
        recent.removeAll { $0.id == place.id }
        persist()
    }

    func clearRecent() {
        recent.removeAll()
        persist()
    }

    private func persist() {
        let payload = StoredData(recent: recent, home: home, work: work)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
