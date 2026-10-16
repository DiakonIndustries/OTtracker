import SwiftUI
import MapKit
import CoreLocation
import OTCore

private enum SettingsLocationSheet: Identifiable {
    case new
    case edit(WorkLocation)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let location): return location.id.uuidString
        }
    }
}

/// Work locations (geofences): list, toggle, edit, delete.
struct LocationsView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: SettingsLocationSheet?
    @State private var pendingDelete: WorkLocation?
    @State private var confirmDelete = false

    var body: some View {
        List {
            if model.store.locations.isEmpty {
                EmptyStateView(systemImage: "mappin.and.ellipse", title: "No work locations",
                               message: "Arrivals and departures are detected by a circle around each worksite. Add one so your days can be logged automatically.")
            } else {
                Section {
                    ForEach(model.store.locations) { location in
                        row(location)
                    }
                } footer: {
                    Text("Leaving the circle means leaving work, so make it cover the parking lot. Only active locations are monitored (iOS allows 20).")
                }
            }
            Section {
                SettingsLocationPermissionRow()
            } header: {
                Text("Permission")
            } footer: {
                Text("Always is required so arrivals and departures are logged while the app is closed.")
            }
        }
        .navigationTitle("Work locations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sheet = .new
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .new:
                LocationEditorView(location: nil)
            case .edit(let location):
                LocationEditorView(location: location)
            }
        }
        .confirmationDialog("Delete this location?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { model.deleteLocation(id: pendingDelete.id) }
                pendingDelete = nil
            }
        } message: {
            Text("Past arrivals and departures recorded here stay in the log but show as an unknown location.")
        }
    }

    private func row(_ location: WorkLocation) -> some View {
        HStack {
            Button {
                sheet = .edit(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.name)
                        .foregroundStyle(.primary)
                    Text("radius \(Int(location.radiusMeters)) m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("Active", isOn: activeBinding(location))
                .labelsHidden()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = location
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func activeBinding(_ location: WorkLocation) -> Binding<Bool> {
        Binding(
            get: { model.store.location(id: location.id)?.isActive ?? location.isActive },
            set: { value in
                var updated = location
                updated.isActive = value
                model.saveLocation(updated)
            }
        )
    }
}

/// Sheet content: name, map with a fixed crosshair, search, radius, active flag.
struct LocationEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let location: WorkLocation?
    private let onDone: (() -> Void)?

    @State private var name: String
    @State private var coordinate: CLLocationCoordinate2D
    @State private var radius: Double
    @State private var isActive: Bool
    @State private var position: MapCameraPosition
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var confirmDelete = false

    init(location: WorkLocation?, onDone: (() -> Void)? = nil) {
        self.location = location
        self.onDone = onDone
        let radius = location?.radiusMeters ?? 250
        let center: CLLocationCoordinate2D
        let region: MKCoordinateRegion
        if let location {
            center = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
            region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 6, longitudinalMeters: radius * 6)
        } else if let last = CLLocationManager().location?.coordinate {
            center = last
            region = MKCoordinateRegion(center: last, latitudinalMeters: 1500, longitudinalMeters: 1500)
        } else {
            center = CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35)
            region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40))
        }
        _name = State(initialValue: location?.name ?? "")
        _coordinate = State(initialValue: center)
        _radius = State(initialValue: radius)
        _isActive = State(initialValue: location?.isActive ?? true)
        _position = State(initialValue: .region(region))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                Form {
                    Section {
                        TextField("Name", text: $name)
                        HStack {
                            TextField("Search address or place", text: $searchText)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .onSubmit(runSearch)
                            if isSearching {
                                ProgressView()
                            } else {
                                Button("Search", action: runSearch)
                                    .buttonStyle(.borderless)
                                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        if searchFailed {
                            Text("Nothing found. Try a fuller address, or drag the map.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Button {
                            useMyLocation()
                        } label: {
                            Label("Use my location", systemImage: "location.fill")
                        }
                    } footer: {
                        Text("Drag the map so the crosshair sits on the worksite. \(coordinateText)")
                    }

                    Section {
                        Text("Radius: \(Int(radius)) m")
                        Slider(value: $radius, in: 100...2000, step: 25) {
                            Text("Radius")
                        }
                    } footer: {
                        Text("iOS geofences work best at 150 m or more. Cover the parking lot.")
                    }

                    Section {
                        Toggle("Active", isOn: $isActive)
                    } footer: {
                        Text("Inactive locations are kept but not monitored.")
                    }

                    if location != nil {
                        Section {
                            Button("Delete location", role: .destructive) { confirmDelete = true }
                        }
                    }
                }
            }
            .navigationTitle(location == nil ? "New location" : "Edit location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: finish)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog("Delete this location?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let location { model.deleteLocation(id: location.id) }
                    finish()
                }
            } message: {
                Text("Past arrivals and departures recorded here stay in the log but show as an unknown location.")
            }
        }
    }

    private var map: some View {
        Map(position: $position) {
            Marker(coordinate: coordinate) {
                Text(name.isEmpty ? "Work" : name)
            }
            MapCircle(center: coordinate, radius: radius)
                .foregroundStyle(.blue.opacity(0.2))
                .stroke(.blue, lineWidth: 2)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            coordinate = context.camera.centerCoordinate
        }
        .overlay {
            Image(systemName: "plus")
                .font(.title)
                .foregroundStyle(.red)
                .shadow(color: .white, radius: 2)
                .allowsHitTesting(false)
        }
        .frame(height: 280)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var coordinateText: String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    // MARK: Actions

    private func moveTo(_ center: CLLocationCoordinate2D, meters: Double) {
        coordinate = center
        position = .region(MKCoordinateRegion(center: center, latitudinalMeters: meters, longitudinalMeters: meters))
    }

    private func useMyLocation() {
        guard let last = CLLocationManager().location?.coordinate else {
            searchFailed = true
            return
        }
        searchFailed = false
        moveTo(last, meters: max(radius * 6, 1200))
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        searchFailed = false
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        let search = MKLocalSearch(request: request)
        let meters = max(radius * 6, 1200)
        Task { @MainActor in
            do {
                let response = try await search.start()
                if let item = response.mapItems.first {
                    moveTo(item.placemark.coordinate, meters: meters)
                } else {
                    searchFailed = true
                }
            } catch {
                searchFailed = true
            }
            isSearching = false
        }
    }

    private func save() {
        let saved = WorkLocation(id: location?.id ?? UUID(), name: trimmedName,
                                 latitude: coordinate.latitude, longitude: coordinate.longitude,
                                 radiusMeters: radius, isActive: isActive,
                                 createdAt: location?.createdAt ?? model.now)
        model.saveLocation(saved)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

#Preview("Locations") {
    NavigationStack {
        LocationsView()
    }
    .environment(AppModel.preview())
}

#Preview("Editor") {
    LocationEditorView(location: nil).environment(AppModel.preview())
}
