import SwiftUI
import PonduCore

/// 함께 탭의 루트. 피드가 첫 화면이고 친구·크루는 위쪽 버튼으로 들어간다.
@MainActor
public struct TogetherRootView: View {
    private let deps: AppDependencies
    @State private var feed: FeedModel
    @State private var friends: FriendsModel
    @State private var crews: CrewsModel
    @State private var path: [Destination] = []

    private enum Destination: Hashable { case friends, crews }

    public init(deps: AppDependencies) {
        self.deps = deps
        let feed = FeedModel(backend: deps.backend)
        let sessions = deps.sessions
        feed.onJoin = { request in sessions.presentStart(request) }
        _feed = State(initialValue: feed)
        _friends = State(initialValue: FriendsModel(backend: deps.backend))
        _crews = State(initialValue: CrewsModel(backend: deps.backend))
    }

    public var body: some View {
        NavigationStack(path: $path) {
            FeedView(deps: deps, model: feed, onFindFriends: { path.append(.friends) })
                .navigationTitle("함께")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { path.append(.crews) } label: { Image(systemName: "person.3") }
                            .accessibilityLabel("크루")
                        Button { path.append(.friends) } label: { Image(systemName: "person.badge.plus") }
                            .accessibilityLabel("친구")
                    }
                }
                .navigationDestination(for: Destination.self) { dest in
                    switch dest {
                    case .friends:
                        FriendsView(model: friends)
                    case .crews:
                        CrewsView(deps: deps, model: crews, onChanged: { Task { await feed.reload() } })
                    }
                }
        }
    }
}
