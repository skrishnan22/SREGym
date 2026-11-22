// Forwarding proxy for OpenCode Go.
//
// Go rejects any request without an `x-opencode-session` header (MissingSessionID).
// SREGym's LiteLLM judge and the bundled mini-sre agent never send one, so they
// talk to this proxy instead, which adds the header and streams the reply back.
//
//   node scripts/harness/go-session-proxy.ts
//   JUDGE_API_BASE=http://127.0.0.1:8788
//
// A request that already carries a session header (our own agent sends one per
// attempt) keeps it. The proxy holds no credentials: the caller's Authorization
// header is forwarded unchanged. Only port 22 is open in the VM's security group,
// so the listening port is reachable from the VM and its containers, not the internet.
import http from "node:http";
import { randomUUID } from "node:crypto";

const UPSTREAM = new URL(process.env.GO_UPSTREAM ?? "https://opencode.ai/inference/go/openai/v1");
const PORT = Number(process.env.GO_PROXY_PORT ?? 8788);
const HOST = process.env.GO_PROXY_HOST ?? "0.0.0.0";
const SESSION = `ses_${randomUUID()}`;
const USER_AGENT = "sregym-harness-proxy/1.0";

// Hop-by-hop headers must not be forwarded; `host` is set from the upstream URL.
const DROP = new Set(["host", "connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection"]);

const server = http.createServer(async (req, res) => {
  const target = new URL(UPSTREAM.pathname.replace(/\/$/, "") + (req.url ?? "/"), UPSTREAM.origin);

  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined || DROP.has(name)) continue;
    headers.set(name, Array.isArray(value) ? value.join(", ") : value);
  }
  if (!headers.has("x-opencode-session")) headers.set("x-opencode-session", SESSION);
  headers.set("user-agent", USER_AGENT);

  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  try {
    const upstream = await fetch(target, {
      method: req.method,
      headers,
      body: hasBody ? (req as unknown as ReadableStream) : undefined,
      // Required by Node's fetch when the body is a stream.
      ...(hasBody ? { duplex: "half" } : {}),
    } as RequestInit);

    const out: Record<string, string> = {};
    upstream.headers.forEach((value, name) => {
      // fetch has already decoded the body, so the original encoding headers no longer apply.
      if (!DROP.has(name) && name !== "content-encoding" && name !== "content-length") out[name] = value;
    });
    res.writeHead(upstream.status, out);
    if (upstream.body) {
      for await (const chunk of upstream.body) res.write(chunk);
    }
    res.end();
    console.log(`${new Date().toISOString()} ${req.method} ${req.url} -> ${upstream.status}`);
  } catch (err) {
    console.error(`${new Date().toISOString()} ${req.method} ${req.url} -> upstream error:`, err);
    if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { type: "proxy_upstream_error", message: String(err) } }));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`go-session-proxy on ${HOST}:${PORT} -> ${UPSTREAM.href} (default session ${SESSION})`);
});
