# Noctalia plugin credential storage

Research for [wayfinding ticket #5](https://github.com/ianmustafa/noctalia-griphub-status/issues/5), checked against current Noctalia, official-plugin, and community-plugin sources. No real credential was accessed.

## Findings

- Noctalia has an internal C++ `security::SecretStore` with lookup/store/erase and unavailable/locked statuses, but it is not exposed to third-party Luau plugins: [secret_store.h](https://github.com/noctalia-dev/noctalia/blob/274edea3af2015899ea57df22eed6dd282a91b61/src/security/secret_store.h#L16-L133), [plugin bindings](https://github.com/noctalia-dev/noctalia/blob/274edea3af2015899ea57df22eed6dd282a91b61/src/scripting/luau_host.cpp#L2238-L2268).
- A plugin can declare a `string`, `string_list`, or `string_map` setting with `secret = true`; this requires `plugin_api >= 47`: [manifest docs](https://github.com/noctalia-dev/noctalia/blob/274edea3af2015899ea57df22eed6dd282a91b61/docs/user/plugins/development/manifest.mdx#L166-L185), [manifest validation](https://github.com/noctalia-dev/noctalia/blob/274edea3af2015899ea57df22eed6dd282a91b61/src/scripting/plugin_manifest.cpp#L367-L382).
- `secret = true` redacts the setting from configuration exports (`--credentials omit` removes it; `--credentials blank` blanks it). The sources do **not** promise Secret Service/keyring encryption or expose a locked/unavailable status: [config export docs](https://github.com/noctalia-dev/noctalia/blob/274edea3af2015899ea57df22eed6dd282a91b61/docs/user/configuration/index.mdx#L131-L177).
- Plugins read declared settings with `noctalia.getConfig(key)`. There is no documented plugin setter, updater, or clear binding: [runtime API](https://github.com/noctalia-dev/noctalia/blob/274edea3af2015899ea57df22eed6dd282a91b61/docs/user/plugins/development/runtime-api.mdx#L16-L29).
- `noctalia.state` is per-plugin in-memory JSON state, not durable credential storage: [runtime state API](https://github.com/noctalia-dev/noctalia/blob/274edea3af2015899ea57df22eed6dd282a91b61/docs/user/plugins/development/runtime-api.mdx#L512-L524).
- `ui.input({ password = true })` masks input visually but does not provide storage. Official Bitwarden demonstrates transient input/validation/clear behavior: [login panel](https://github.com/noctalia-dev/official-plugins/blob/23b87da24de5bc019639e957d367ca4dee9b45aa/bitwarden/login.luau#L1-L83).
- Community Binance uses an external Python helper and `secret-tool` for actual Secret Service CRUD, keeping secrets out of argv/stdout/logs/files: [helper](https://github.com/noctalia-dev/community-plugins/blob/e6453e8f016270aa92e913202d96546683bcd20b/binance/binance_helper.py#L141-L218).

## Decision impact

The current choices are:

1. Use a `secret = true` plugin setting and host Settings for entry/edit/clear. This is the supported host UX and protects exports, but its at-rest encryption is unspecified.
2. Use an external Secret Service helper such as the Binance pattern. This gives keyring storage but adds a runtime dependency and helper lifecycle/security surface.
3. Do not persist the token; require user-managed per-session injection.
4. Add or wait for a Noctalia host credential binding; outside this plugin repository.

Treat an absent/empty `noctalia.getConfig("token")` as unconfigured. Never log, notify, IPC-share, place in URLs/argv, or persist a token through ordinary files or `noctalia.state`.

## Chosen path

Use a `secret = true` string setting in `plugin.toml` with `plugin_api >= 47`. The user manages the token through Noctalia Settings → Plugins; plugin code reads it with `noctalia.getConfig("token")`. The plugin will treat empty or missing values as unconfigured and will not claim that this setting is Secret Service-backed.
