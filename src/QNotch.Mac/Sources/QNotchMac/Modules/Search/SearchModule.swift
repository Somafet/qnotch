import AppKit

/// Search has no providers of its own: it queries enabled modules' in-memory sources on demand.
/// Its contributions disappear through the same lifecycle as every other native module.
final class SearchModule: NotchModule {
    func initialize(_ context: ModuleContext) {
        let registries = context.registries
        registries.tabs.register(ViewContribution(id: "search", title: "Search", order: 0, symbol: "magnifyingglass") { [weak registries] in
            SearchView { [weak registries] query in
                registries?.searchSources.items.flatMap { Array($0.find(query).prefix(5)) } ?? []
            }
        })
        context.shortcuts.add("search", title: "Open search", hint: "Opens the Search tab with the cursor in the box.",
                              gesture: "ctrl+opt+f", order: 20) { [weak shell = context.shell] in
            shell?.summonSearch()
        }
    }

    func setVisibility(panel: Bool, activeTab: String) {}
    func systemDidWake() {}
    func stop() {}
}
