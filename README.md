# KOReader Userpatches

A collection of [userpatches](https://github.com/koreader/koreader/wiki/User-patches) for [KOReader](https://koreader.rocks/).

## Installation

Copy the `.lua` files into your KOReader `patches/` directory and restart KOReader.

The `patches/` folder is located at the root of your KOReader installation (next to `settings/`, `plugins/`, etc.). Create it if it doesn't exist.

## Patches

### Top Bar Editor

**`2-top-bar-editor.lua`**

Customizes the File Manager top bar.

- Replace the "KOReader" title with the current folder name
- Configurable font size, bold, and italic styling for the folder name
- Remap the right button (plus) tap to any dispatcher action
- Configurable right button icon

*Menu: Settings > Top bar*

### Pagination Bar Editor

**`2-filemanager-pagination-bar-editor.lua`**

Customizes the pagination bar in file browser and reader menus.

- Text template with positional layout (buttons and text in any order)
- Configurable font size and bold
- Button style (icons or dots) and size
- Bar alignment (left, center, right)
- Adjustable spacer width between elements
- Hide the bar entirely (swipe navigation still works)
- `{space}` token for fine alignment control
- Reset everything to default

*Menu: Settings > Pagination bar*

### KOSync Sync All

**`2-kosync-sync-all.lua`**

Adds a "Sync all progress" action to the Progress Sync (KOSync) plugin.

- Push reading progress for every book in history to the server at once
- Progress indicator during sync (X / Y)
- Summary with pushed / failed / skipped counts
- Detail view listing each failure reason and skipped book
- Respects the configured checksum method (filename or partial MD5)
- Automatically skips the quickstart guide

*Menu: Progress sync > Sync all progress from this device*

## Compatibility

These patches use the KOReader userpatch API (`userpatch` module and monkey-patching). They are developed against recent stable releases; if KOReader changes its internals significantly a patch may need updating.

## License

These patches are provided as-is. Use at your own risk.
