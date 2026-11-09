# GripHub Status

`ianmustafa/griphub-status` is a community-maintained Noctalia plugin. It is not
produced, maintained, or endorsed by Noctalia.
The bar widget provides the secure shell for the GripHub status plugin. It reads
the token from Noctalia Settings → Plugins, requests data through the injected
host HTTP surface, and keeps the credential out of ordinary widget output. The
token is a secret setting and is omitted or blanked by credential-redacted
configuration exports. It is sent only as an HTTP `Authorization` header. When
no token is configured, the widget stays neutral and says `Token not configured`.
Clicking the widget opens the fixed GripHub portal:
`https://griphubrouter.web.id/portal`.

The plugin needs Noctalia plugin API 47 and `xdg-open` for the portal action.
