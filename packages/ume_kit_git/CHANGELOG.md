## Unreleased

- Exclude the current build commit from the five previous commits and clarify the history section label.

- Bound asynchronous Git capture, preserve current revision on history errors, replace IDE metadata atomically, support leading global flags and SDK selection, and render history as time / subject / hash and author.

- Capture up to five commits at the host app build revision; preserve Unicode and multiline messages in compiler definitions.
- Add collapsible history and copying of complete commit details.
- Continue Flutter on capture failure; IDE generation replaces stale JSON with an empty object and exits successfully.
- Embed icon bytes through `MemoryImage` to support dev-dependency consumers without bundled assets.
- Cover CLI forwarding, failure behavior, history, UI interaction and icon decoding with tests.
- Provide matching English/Chinese setup and troubleshooting guides.

## 1.0.0

- Add a standalone Git Info panel with copyable host app build metadata.
- Include Git capture, Flutter command wrapper and IDE metadata generator.
