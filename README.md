# GripHub Status

`ianmustafa/griphub-status` is a community-maintained Noctalia plugin. It is
not produced, maintained, or endorsed by Noctalia, and this repository does
not claim official catalog inclusion. It is structured for review and
submission to `noctalia-dev/community-plugins`.

## Setup

1. Install the plugin from a local checkout or the community-plugin review
   workflow.
2. Open **Noctalia Settings → Plugins → GripHub Status**.
3. Enter your GripHub token in **GripHub token** and save the settings. The
   token setting is declared `secret = true`, so credential-omitted or
   credential-blanked Noctalia configuration exports do not disclose it.
4. Place the bar widget wherever you want it. An empty token keeps the widget
   neutral and shows `Token not configured`; it does not make a request or
   display a fabricated zero balance.

The plugin reads the token only through the Noctalia settings API and sends it
only as an HTTP `Authorization` header. It never puts the token in a URL,
command argument, notification, tooltip, bar text, ordinary file, or plugin
state. No live credential or service is needed for the repository's offline
acceptance tests.

## Settings

- **Refresh interval**: 1 second through 24 hours, default 30 seconds. A
  one-time warning appears when the interval is below 30 seconds because that
  setting increases API traffic. Refresh ticks never overlap an in-flight
  request, and the first fetch runs immediately at startup.
- **Decimal precision**: 0 through 4 decimal places, default 1. Values below
  1,000 use fixed-point notation; larger values use readable K/M/B/T suffixes.
  Hover always retains the exact, un-compacted balance.
- **Glyph**: the bar glyph, default `lightning`.

## Data and states

The widget tries `/api/user-usage` first and falls back to `/v1/credits` only
when the primary contract is unsupported. It remembers the first successful
contract for later refreshes. The request and response contracts are exercised
with local fixtures; GripHub Router and Noctalia are not modified or required
for verification.

Hover and bar output make state explicit:

- `Authentication failed`, `Rate limited`, `Service unavailable`, and
  `Invalid response` identify errors without showing response bodies.
- After a successful fetch, a refresh error retains the last known balance and
  marks it **stale**, including the failure class and last-success timestamp.
  Before the first success, an error remains neutral rather than showing zero.
- A suspended account is shown as **Suspended**, preserves its supplied
  balance, and includes `suspendedUntil` when the API provides one.
- Active positive credit batches appear in hover details, ordered by earliest
  expiry and formatted in local time. Expired, zero, negative, and malformed
  batches are omitted.

## Portal click

Clicking the widget opens the fixed GripHub portal:

`https://griphubrouter.web.id/portal`

The click carries no token, query string, or fragment. The only external
command used for this action is `xdg-open`, declared in `plugin.toml`.

## Development and catalog posture

Run the deterministic checks from the repository root:

```sh
lua tests/widget_controller_test.lua
python3 tests/plugin_metadata_test.py
```

Both suites use injected adapters and checked-in fixtures; they do not contact
GripHub or require credentials. The manifest keeps the required `plugin_api =
47` baseline, the `ianmustafa/griphub-status` identity, community-maintainer
attribution, and the secret token setting. The package is ready to submit for
community review; inclusion in the official Noctalia catalog has not been
claimed.
