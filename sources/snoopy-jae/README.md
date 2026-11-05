<!-- cspell:ignore searxng -->
<!-- markdownlint-disable MD013 -->
# SearXNG MCP server

MCP server [jae-jae/searxng-mul-mcp](https://github.com/jae-jae/searxng-mul-mcp) providing the `search` tool over a SearXNG instance. Upstream is pinned to `a3881c7` in `vars.sh`; patches from `patches/` are applied in filename order and the image is built by the upstream `Dockerfile`. The image entrypoint runs the Streamable HTTP transport on `0.0.0.0:3000` with the MCP endpoint `/mcp` and the health check `/health`.

## Environment variables

- `SEARXNG_URL` – SearXNG instance URL, required.
- `USERNAME` and `PASSWORD` – Basic Auth credentials for SearXNG, optional, set both or none.
- `DEBUG` – `true` enables debug logging, default `false`.
- `SEARXNG_CONCURRENCY` – maximum number of concurrent requests to SearXNG within one `search` tool call, default `3`. Only digits with a value of at least `1` are accepted; any other non-empty value fails the startup with an error message. An unset or empty value selects the default.

`TRANSPORT`, `HOST` and `PORT` do not change the transport or the listening address in the image: the entrypoint passes `--transport=http --host=0.0.0.0 --port=3000`, which override them. With `TRANSPORT=http` set, an invalid `PORT` still fails the startup.

## Patches

- `000-update-node-24.patch` – build and runtime on `node:24-alpine`; `engines` and `@types/node` follow Node 24.
- `001-fix-debug-env-and-verbose-logging.patch` – `DEBUG=true` enables debug logging without changing the entrypoint; SearXNG requests and failed responses are logged in detail.
- `002-per-session-mcp-server.patch` – every HTTP session gets its own MCP server instance, so concurrent clients receive only their own responses and closing one session does not affect others; a `DELETE` rejected by the SDK keeps the session. Regression test: `node --test test/http-session.test.mjs` after the build.
- `003-limit-searxng-concurrency.patch` – requests of one `search` call run with at most `SEARXNG_CONCURRENCY` in flight; results keep the order of `queries`.
- `004-migrate-to-mcp-sdk-v2.patch` – MCP SDK v2: `@modelcontextprotocol/server` and `@modelcontextprotocol/node` replace `@modelcontextprotocol/sdk`, the `search` tool is registered with `McpServer.registerTool` and a strict zod schema; invalid or unknown arguments, search exceptions and calls where every query failed return a tool result with `isError: true`, while a `tools/call` whose `arguments` is not an object (`[]`, `null`, a string) violates the MCP schema and stays a JSON-RPC `-32602` error. Every `search` call that reaches the schema check is logged as `Executing tool` with its arguments and a call rejected by the schema also as `Tool execution failed` with the validation issues; a call whose `arguments` is not an object and a call of an unknown tool are rejected by the SDK with a JSON-RPC `-32602` error before the server code and are not logged. Regression tests: `node --test test/search-validation.test.mjs test/tool-call-logging.test.mjs` after the build.
