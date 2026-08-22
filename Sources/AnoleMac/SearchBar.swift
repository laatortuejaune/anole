import SwiftUI
import MapKit
import AnoleCore
import AnoleServices

/// Search bar laid over the map: address, city, known place, raw coordinates
/// or a link copied from another application.
struct SearchBar: View {
    @ObservedObject var search: PlaceSearchModel
    /// Called with the chosen place; the parent view drops the location and recenters.
    var onPick: (Coordinate) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if isFocused, !search.suggestions.isEmpty {
                Divider()
                results
            }
            if let message = search.message {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .frame(maxWidth: 380)
        .padding(12)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Address, city, place or coordinates", text: $search.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    Task {
                        if let coordinate = await search.searchDirectly() {
                            pick(coordinate)
                        }
                    }
                }

            if search.isResolving {
                ProgressView().controlSize(.small)
            } else if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(search.suggestions) { suggestion in
                Button {
                    Task {
                        if let coordinate = await search.resolve(suggestion) {
                            pick(coordinate)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        // A recognized coordinate is immediate; a suggestion
                        // will require a request to the map service.
                        Image(systemName: suggestion.isDirect ? "scope" : "mappin.circle")
                            .foregroundStyle(suggestion.isDirect ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title)
                                .lineLimit(1)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func pick(_ coordinate: Coordinate) {
        onPick(coordinate)
        search.query = ""
        isFocused = false
    }
}
