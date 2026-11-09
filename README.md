# Noctalia plugins

Community plugins for [Noctalia](https://github.com/noctalia-dev/noctalia), laid out like [noctalia-dev/community-plugins](https://github.com/noctalia-dev/community-plugins). These plugins are not produced, maintained, or endorsed by Noctalia.

## Plugins

| Plugin | Id | Description |
| --- | --- | --- |
| [Griphub Status](griphub-status/README.md) | `ianmustafa/griphub-status` | Griphub credits status for the Noctalia bar. |

## Layout

Each plugin is one top-level directory named after the part of its id that follows the `/`.

```
griphub-status/
  plugin.toml             # manifest: id, metadata, entries, settings
  widget.luau             # entry script
  widget_controller.luau  # widget logic
  README.md               # plugin page
  thumbnail.webp          # plugin card image
  translations/en.json    # strings referenced by the manifest
  tests/                  # offline tests
catalog.toml              # index of the plugins in this repo
docs/                     # agent and research notes
```

`catalog.toml` is maintained by hand here. `community-plugins` generates its own copy in CI, so leave it out of submission PRs.

## Use locally

Add this checkout as a `path` source, then enable the plugin:

```sh
noctalia msg plugins source add dev path /media/Vault/Projects/Ian/Noctalia/noctalia-plugins
noctalia msg plugins enable ianmustafa/griphub-status
```

`.luau` edits hot-reload; manifest changes are picked up on the next config reload.

## Tests

Run from a plugin directory. Both suites are offline and need no credentials.

```sh
cd griphub-status
lua tests/widget_controller_test.lua
python3 tests/plugin_metadata_test.py
```

## Contributing

Follow the [community-plugins guidelines](https://github.com/noctalia-dev/community-plugins#readme): one plugin per directory, `version` bumped on every change, `plugin_api` set to the oldest API level required, and every external command listed in `dependencies`.
