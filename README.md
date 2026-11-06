# Zbar

A menu bar manager for macOS 14+ (works on macOS 26): a no-subscription take on Bartender / Ice.

## Build

    ./build.sh --run

The first build creates a local signing identity (`.signing/`) so Accessibility and Screen Recording
permissions survive rebuilds.

## How it works

- Right to left: `[visible] [Zbar icon] [‹ hidden divider] [hidden] [‹ always-hidden divider] [always hidden]`.
- A divider hides everything to its left by growing to 10,000 pt, pushing those icons off screen.
- **⌘-drag** icons in the menu bar to move them between sections (Settings › Layout › Arrange mode shows every section).
- **Zbar Bar**: hidden icons in a bar below the menu bar, used automatically when they wouldn't fit (the notch).
- On macOS 26 the window server reports every menu bar icon as owned by Control Centre, so Zbar finds the
  real owner of each icon through Accessibility (`AXExtrasMenuBar`), matched by position.

## Triggers

Click the icon (⌥-click: include always hidden), click / hover / scroll on empty menu bar space,
⌃⌥B (toggle), ⌃⌥Space (search every icon), or URLs:

    open zbar://show | hide | toggle | all | bar | search | arrange | settings/layout | dump

`dump` writes the current layout to `$TMPDIR/zbar-diagnostics.txt`.

## Permissions

- Accessibility (recommended): open icons from the Zbar Bar / search, detect empty menu bar space, name icons.
- Screen Recording (optional): real icon images in the Zbar Bar and Layout; otherwise the owning app's icon.

## Licence

MIT (see `LICENSE`).
