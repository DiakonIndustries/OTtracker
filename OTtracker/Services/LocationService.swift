import Foundation
import CoreLocation
import OTCore

/// CLLocationManager region monitoring. Created once at launch so a background relaunch
/// for a region event finds a delegate ready.
@MainActor
final class LocationService: NSObject, LocationServicing, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var knownIDs: Set<UUID> = []

    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onCrossing: ((RegionCrossing) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        knownIDs = Set(manager.monitoredRegions.compactMap { UUID(uuidString: $0.identifier) })
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }

    func requestAlways() { manager.requestAlwaysAuthorization() }

    func syncRegions(_ locations: [WorkLocation]) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let wanted = Array(locations.filter { $0.isActive }.prefix(20))
        let wantedIDs = Set(wanted.map { $0.id })
        // Decide per region here instead of re-reading `monitoredRegions` after `stopMonitoring`
        // (it is not updated synchronously), and compare with a tolerance so a round-tripped
        // coordinate or radius does not re-register an unchanged region.
        var kept: Set<UUID> = []
        for region in manager.monitoredRegions {
            guard let id = UUID(uuidString: region.identifier), let loc = wanted.first(where: { $0.id == id }),
                  let circ = region as? CLCircularRegion,
                  abs(circ.center.latitude - loc.latitude) < 1e-7, abs(circ.center.longitude - loc.longitude) < 1e-7,
                  abs(circ.radius - clampRadius(loc.radiusMeters)) < 0.5 else {
                manager.stopMonitoring(for: region)
                continue
            }
            kept.insert(id)
        }
        for loc in wanted where !kept.contains(loc.id) {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude),
                                          radius: clampRadius(loc.radiusMeters), identifier: loc.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
        knownIDs = wantedIDs
    }

    private func clampRadius(_ r: Double) -> CLLocationDistance {
        min(max(r, 100), manager.maximumRegionMonitoringDistance > 0 ? manager.maximumRegionMonitoringDistance : 10_000)
    }

    func refreshCurrentState() {
        for region in manager.monitoredRegions { manager.requestState(for: region) }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.onAuthorizationChange?(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier) else { return }
        let crossing = RegionCrossing(locationID: id, kind: .enter, at: Date(), inferredFromState: false)
        Task { @MainActor in self.onCrossing?(crossing) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier) else { return }
        let crossing = RegionCrossing(locationID: id, kind: .exit, at: Date(), inferredFromState: false)
        Task { @MainActor in self.onCrossing?(crossing) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier), state != .unknown else { return }
        let crossing = RegionCrossing(locationID: id, kind: state == .inside ? .enter : .exit, at: Date(), inferredFromState: true)
        Task { @MainActor in self.onCrossing?(crossing) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Logged only; the Inbox surfaces missing data as no-shows.
        NSLog("Region monitoring failed for \(region?.identifier ?? "?"): \(error.localizedDescription)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("Location error: \(error.localizedDescription)")
    }
}

/// Does nothing; for previews.
@MainActor
final class NoopLocationService: LocationServicing {
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onCrossing: ((RegionCrossing) -> Void)?
    func requestWhenInUse() {}
    func requestAlways() {}
    func syncRegions(_ locations: [WorkLocation]) {}
    func refreshCurrentState() {}
}
