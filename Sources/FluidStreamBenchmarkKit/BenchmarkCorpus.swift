/// Sample responses used as benchmark input.
public enum BenchmarkCorpus {
    /// A mixed answer that touches every parser and renderer path: thinking, headings,
    /// lists, inline styles, code fences, a tool call and non-ASCII text.
    public static let mixedAnswer = #"""
    <thinking>
    The user wants to know how to debounce a search field in SwiftUI without Combine. I should compare `task(id:)` with a manual `Task` and mention **cancellation**, since that's the part people usually get wrong.
    </thinking>
    # Debouncing search in SwiftUI

    There are two idiomatic approaches. Both rely on *structured concurrency*, so cancellation comes for free.

    ## Option 1: `task(id:)`

    SwiftUI cancels the previous task whenever `id` changes, so a short sleep at the start acts as a debounce:

    ```swift
    struct SearchView: View {
        @State private var query = ""
        @State private var results: [Item] = []

        var body: some View {
            List(results) { ItemRow(item: $0) }
                .searchable(text: $query)
                .task(id: query) {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    results = await Search.run(query)
                }
        }
    }
    ```

    ## Option 2: a model-owned task

    1. Keep a `Task` handle in your `@Observable` model.
    2. Cancel it on every keystroke.
    3. Start a new one that sleeps, then searches.

    - **Pro:** testable without a view.
    - **Con:** you own the lifecycle, so remember to cancel in `deinit`.

    <tool_call>{"name":"search_docs","input":{"query":"SwiftUI task(id:) cancellation","limit":3}}</tool_call>
    The docs confirm that the task is cancelled *before* the new one starts, so there's no overlap. For more, see [Apple's concurrency guide](https://developer.apple.com/documentation/swift/concurrency).

    > Tip: 300 ms feels responsive for typing; go lower for scanners. 🚀 Ça marche très bien.

    """#
}
