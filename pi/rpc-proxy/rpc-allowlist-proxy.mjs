// JSON-RPC method allowlist proxy for the Pi chain host's public anvil endpoint.
//
// WHY: Tailscale Funnel makes anvil reachable from the internet so the
// CloudFront frontend can talk to it. A raw anvil exposes state-rewriting
// admin methods (anvil_setCode, anvil_impersonateAccount, evm_mine,
// evm_setNextBlockTimestamp, ...) and 5 unlocked funded accounts, so anyone
// with the URL could move the mock price feeds or rewrite chain state.
//
// This sits in front of anvil and rejects those method families while passing
// normal eth_*/net_*/web3_* traffic. chain-server and the block producer are
// ON the box and talk to anvil over loopback directly, bypassing this proxy —
// trusted local callers keep full access, the public gets the filtered view.
//
// No dependencies: plain node:http so it needs no install step on the Pi.
//
// Env:
//   LISTEN_HOST   default 127.0.0.1 (Funnel connects over loopback)
//   LISTEN_PORT   default 8546
//   UPSTREAM_URL  default http://127.0.0.1:8545
//   ALLOW_ORIGIN  default * (sandbox; CORS is already open on chain-server)
import http from 'node:http'

const LISTEN_HOST = process.env.LISTEN_HOST || '127.0.0.1'
const LISTEN_PORT = Number(process.env.LISTEN_PORT || 8546)
const UPSTREAM_URL = process.env.UPSTREAM_URL || 'http://127.0.0.1:8545'
const ALLOW_ORIGIN = process.env.ALLOW_ORIGIN || '*'
const MAX_BODY_BYTES = 1024 * 1024 // 1 MiB — anvil requests are tiny; cap abuse.

// Blocked prefixes. Anything matching is refused regardless of casing.
const BLOCKED_PREFIXES = ['anvil_', 'evm_', 'hardhat_', 'ots_', 'debug_', 'txpool_', 'personal_']
// Explicit extras that do not share a prefix with the families above.
const BLOCKED_EXACT = new Set(['eth_sendUnsignedTransaction', 'eth_signTransaction'])

const isBlocked = (method) => {
  if (typeof method !== 'string') return true // malformed — refuse rather than forward
  const m = method.toLowerCase()
  if (BLOCKED_EXACT.has(method)) return true
  return BLOCKED_PREFIXES.some((p) => m.startsWith(p))
}

const corsHeaders = {
  'access-control-allow-origin': ALLOW_ORIGIN,
  'access-control-allow-methods': 'POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
  'access-control-max-age': '86400',
}

const send = (res, status, payload) => {
  const body = JSON.stringify(payload)
  res.writeHead(status, { 'content-type': 'application/json', ...corsHeaders })
  res.end(body)
}

const rpcError = (id, message) => ({
  jsonrpc: '2.0',
  id: id ?? null,
  error: { code: -32601, message },
})

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders)
    return res.end()
  }
  if (req.method === 'GET' && req.url === '/healthz') {
    return send(res, 200, { status: 'ok', upstream: UPSTREAM_URL })
  }
  if (req.method !== 'POST') {
    return send(res, 405, rpcError(null, 'Only POST is accepted'))
  }

  let size = 0
  const chunks = []
  let aborted = false
  req.on('data', (c) => {
    size += c.length
    if (size > MAX_BODY_BYTES) {
      aborted = true
      send(res, 413, rpcError(null, 'Request body too large'))
      req.destroy()
      return
    }
    chunks.push(c)
  })

  req.on('end', () => {
    if (aborted) return
    const raw = Buffer.concat(chunks).toString('utf8')

    let parsed
    try {
      parsed = JSON.parse(raw)
    } catch {
      return send(res, 400, rpcError(null, 'Invalid JSON'))
    }

    // Batch requests must be checked element by element — a single blocked
    // call in a batch rejects the whole batch rather than being forwarded.
    const calls = Array.isArray(parsed) ? parsed : [parsed]
    if (calls.length === 0) return send(res, 400, rpcError(null, 'Empty batch'))
    const offender = calls.find((c) => isBlocked(c?.method))
    if (offender) {
      console.warn(`[rpc-proxy] blocked ${offender?.method} from ${req.socket.remoteAddress}`)
      return send(
        res,
        403,
        rpcError(
          offender?.id,
          `Method ${offender?.method} is not available on the public endpoint`,
        ),
      )
    }

    const upstream = new URL(UPSTREAM_URL)
    const proxyReq = http.request(
      {
        hostname: upstream.hostname,
        port: upstream.port,
        path: upstream.pathname,
        method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(raw) },
      },
      (proxyRes) => {
        res.writeHead(proxyRes.statusCode || 502, {
          'content-type': 'application/json',
          ...corsHeaders,
        })
        proxyRes.pipe(res)
      },
    )
    // Surface upstream failures instead of hanging the caller.
    proxyReq.on('error', (err) => {
      console.error(`[rpc-proxy] upstream error: ${err.message}`)
      send(res, 502, rpcError(null, `Upstream unreachable: ${err.message}`))
    })
    proxyReq.end(raw)
  })
})

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`[rpc-proxy] listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${UPSTREAM_URL}`)
  console.log(`[rpc-proxy] blocked prefixes: ${BLOCKED_PREFIXES.join(', ')}`)
})
