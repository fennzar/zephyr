const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.ORACLE_PORT || '5555', 10);
const PRIVATE_KEY_PATH = path.join(__dirname, 'oracle_private.pem');

const privateKey = fs.readFileSync(PRIVATE_KEY_PATH, 'utf8');

// Default spot price in atomic units (COIN = 10^12)
// $1.50 default matches devnet-init oracle price used by bridge-orch dev-setup.
let currentSpot = parseInt(process.env.DEFAULT_SPOT || '1500000000000', 10);

// Mirror mode state
let currentMode = 'manual';
let mirrorSpot = null;
let mirrorLastFetch = null;
let mirrorInterval = null;
const MIRROR_POLL_MS = 30000;
const MAINNET_ORACLE = 'oracle.zephyrprotocol.com';

// Moving average state
// The daemon's oracle signature only covers {spot, timestamp} — MA is NOT signed,
// so we can set it independently without any C++ changes.
let currentMA = null;         // null = MA equals spot (default)
let maMode = 'spot';          // 'spot' | 'manual' | 'ema' | 'mirror'
let emaAlpha = 0.1;           // EMA smoothing factor (lower = smoother)
let mirrorMA = null;          // cached MA from mainnet oracle

// Supply sync state
const GOV_WALLET_RPC = process.env.GOV_WALLET_RPC || '';
const NODE_RPC = process.env.NODE_RPC || 'http://127.0.0.1:47767';
const EXPLORER_API = 'https://explorer.zephyrprotocol.com/api';
let supplyMode = 'off';            // 'off' | 'sync'
let supplyInterval = null;
let supplyLastSync = null;
let supplyLastDeltas = null;
let supplyInFlight = false;
const SUPPLY_POLL_MS = parseInt(process.env.SUPPLY_POLL_MS || '60000', 10);
let supplyThreshold = parseInt(process.env.SUPPLY_THRESHOLD || '1000', 10);

function signPricingRecord(spot, timestamp) {
  const message = JSON.stringify({ spot, timestamp });
  const sign = crypto.createSign('SHA256');
  sign.update(message);
  sign.end();
  const signature = sign.sign(privateKey);
  return signature.toString('hex');
}

function getEffectiveMA(spot) {
  switch (maMode) {
    case 'manual':
      return currentMA !== null ? currentMA : spot;
    case 'ema':
      if (currentMA === null) currentMA = spot;
      currentMA = Math.round(currentMA + emaAlpha * (spot - currentMA));
      return currentMA;
    case 'mirror':
      return mirrorMA !== null ? mirrorMA : spot;
    case 'spot':
    default:
      return spot;
  }
}

function fetchMainnetPrice() {
  const ts = Math.floor(Date.now() / 1000);
  const urlPath = `/price/?timestamp=${ts}&version=11`;

  return new Promise((resolve, reject) => {
    const req = https.get({
      hostname: MAINNET_ORACLE,
      port: 443,
      path: urlPath,
      timeout: 10000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (parsed.pr && parsed.pr.spot) {
            resolve(parsed.pr);
          } else {
            reject(new Error('Missing pr.spot in response'));
          }
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

async function pollMainnet() {
  try {
    const pr = await fetchMainnetPrice();
    mirrorSpot = pr.spot;
    if (pr.moving_average) {
      mirrorMA = pr.moving_average;
    }
    mirrorLastFetch = new Date().toISOString();
    if (currentMode === 'mirror') {
      currentSpot = mirrorSpot;
    }
    console.log(`[${mirrorLastFetch}] Mirror: spot=${pr.spot} ($${pr.spot / 1e12}), ma=${pr.moving_average || 'n/a'}`);
  } catch (e) {
    console.log(`[${new Date().toISOString()}] Mirror: fetch failed - ${e.message}`);
  }
}

function startMirror() {
  if (mirrorInterval) return;
  pollMainnet();
  mirrorInterval = setInterval(pollMainnet, MIRROR_POLL_MS);
  console.log(`[${new Date().toISOString()}] Mirror mode started (polling every ${MIRROR_POLL_MS / 1000}s)`);
}

function stopMirror() {
  if (mirrorInterval) {
    clearInterval(mirrorInterval);
    mirrorInterval = null;
  }
  console.log(`[${new Date().toISOString()}] Mirror mode stopped`);
}

// ─── Supply Sync ────────────────────────────────────────────────────────────

function jsonRpc(url, method, params = {}) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: '0', method, params });
    const parsed = new URL(url);
    const options = {
      hostname: parsed.hostname,
      port: parsed.port,
      path: '/json_rpc',
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 10000,
    };
    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
    req.write(body);
    req.end();
  });
}

function fetchExplorerSupply() {
  return new Promise((resolve, reject) => {
    https.get(`${EXPLORER_API}/supply`, { timeout: 10000 }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          resolve(parsed.data || parsed);
        } catch (e) { reject(e); }
      });
    }).on('error', reject);
  });
}

async function getDevnetSupply() {
  const res = await jsonRpc(NODE_RPC, 'get_reserve_info');
  if (!res.result) throw new Error('No result from get_reserve_info');
  const r = res.result;
  // Values are in atomic units (1e12); convert to whole units
  return {
    djed: Math.floor((parseInt(r.zr) || 0) / 1e12),
    zsd: Math.floor((parseInt(r.zs) || 0) / 1e12),
    yield: Math.floor((parseInt(r.zy) || 0) / 1e12),
  };
}

async function getGovWalletAddress() {
  const res = await jsonRpc(GOV_WALLET_RPC, 'get_address', { account_index: 0 });
  return res.result.address;
}

async function walletTransfer(fromAsset, toAsset, amount, address) {
  // Refresh wallet first
  await jsonRpc(GOV_WALLET_RPC, 'refresh', {}).catch(() => {});
  const amountAtomic = Math.floor(amount * 1e12);
  const res = await jsonRpc(GOV_WALLET_RPC, 'transfer', {
    destinations: [{ amount: amountAtomic, address }],
    source_asset: fromAsset,
    destination_asset: toAsset,
    priority: 0,
    ring_size: 2,
    get_tx_key: true,
  });
  if (res.result && res.result.tx_hash) {
    return res.result.tx_hash;
  }
  throw new Error(res.error ? res.error.message : 'Transfer failed');
}

async function pollSupplySync() {
  if (supplyInFlight || !GOV_WALLET_RPC) return;
  supplyInFlight = true;
  try {
    const [mainnet, devnet] = await Promise.all([fetchExplorerSupply(), getDevnetSupply()]);
    const govAddr = await getGovWalletAddress();

    const deltas = {
      djed: Math.floor((mainnet.djed || 0) - devnet.djed),
      zsd: Math.floor((mainnet.zsd || 0) - devnet.zsd),
      yield: Math.floor((mainnet.yield || 0) - devnet.yield),
    };
    supplyLastDeltas = deltas;
    supplyLastSync = new Date().toISOString();

    const actions = [];

    // DJED adjustment: mint/redeem ZRS
    if (Math.abs(deltas.djed) > supplyThreshold) {
      if (deltas.djed > 0) {
        // DJED too low → mint ZRS (ZPH→ZRS)
        const chunk = Math.min(deltas.djed, 100000);
        actions.push({ op: 'mint ZRS', from: 'ZPH', to: 'ZRS', amount: chunk });
      } else {
        // DJED too high → redeem ZRS (ZRS→ZPH)
        const chunk = Math.min(Math.abs(deltas.djed), 100000);
        actions.push({ op: 'redeem ZRS', from: 'ZRS', to: 'ZPH', amount: chunk });
      }
    }

    // ZSD adjustment: mint/redeem ZSD
    if (Math.abs(deltas.zsd) > supplyThreshold) {
      if (deltas.zsd > 0) {
        const chunk = Math.min(deltas.zsd, 50000);
        actions.push({ op: 'mint ZSD', from: 'ZPH', to: 'ZSD', amount: chunk });
      } else {
        const chunk = Math.min(Math.abs(deltas.zsd), 50000);
        actions.push({ op: 'redeem ZSD', from: 'ZSD', to: 'ZPH', amount: chunk });
      }
    }

    // YIELD adjustment: mint/redeem ZYS
    if (Math.abs(deltas.yield) > supplyThreshold) {
      if (deltas.yield > 0) {
        const chunk = Math.min(deltas.yield, 25000);
        actions.push({ op: 'mint ZYS', from: 'ZSD', to: 'ZYS', amount: chunk });
      } else {
        const chunk = Math.min(Math.abs(deltas.yield), 25000);
        actions.push({ op: 'redeem ZYS', from: 'ZYS', to: 'ZSD', amount: chunk });
      }
    }

    if (actions.length === 0) {
      console.log(`[${supplyLastSync}] Supply sync: within threshold (djed=${deltas.djed}, zsd=${deltas.zsd}, yield=${deltas.yield})`);
    } else {
      // Execute one action per poll to avoid conflicts
      const action = actions[0];
      console.log(`[${supplyLastSync}] Supply sync: ${action.op} ${action.amount} (${action.from}→${action.to})`);
      try {
        const txHash = await walletTransfer(action.from, action.to, action.amount, govAddr);
        console.log(`[${new Date().toISOString()}] Supply sync: TX ${txHash.substring(0, 16)}...`);
      } catch (e) {
        console.log(`[${new Date().toISOString()}] Supply sync: ${action.op} failed - ${e.message}`);
      }
    }
  } catch (e) {
    console.log(`[${new Date().toISOString()}] Supply sync: poll failed - ${e.message}`);
  } finally {
    supplyInFlight = false;
  }
}

function startSupplySync() {
  if (supplyInterval) return;
  if (!GOV_WALLET_RPC) {
    console.log(`[${new Date().toISOString()}] Supply sync: GOV_WALLET_RPC not set, cannot start`);
    return;
  }
  pollSupplySync();
  supplyInterval = setInterval(pollSupplySync, SUPPLY_POLL_MS);
  console.log(`[${new Date().toISOString()}] Supply sync started (polling every ${SUPPLY_POLL_MS / 1000}s, threshold=${supplyThreshold})`);
}

function stopSupplySync() {
  if (supplyInterval) {
    clearInterval(supplyInterval);
    supplyInterval = null;
  }
  console.log(`[${new Date().toISOString()}] Supply sync stopped`);
}

// ─── HTTP Helpers ───────────────────────────────────────────────────────────

function readBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => resolve(body));
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (req.method === 'GET' && url.pathname === '/price/') {
    const timestamp = parseInt(url.searchParams.get('timestamp') || '0', 10);
    const version = parseInt(url.searchParams.get('version') || '11', 10);

    const spot = currentSpot;
    const signature = signPricingRecord(spot, timestamp);

    // The daemon recalculates stable, reserve, reserve_ratio, yield_price
    // from circulating supply. We only need to provide spot + signature.
    // MA is NOT signed — we can set it independently of spot.
    const ma = getEffectiveMA(spot);
    const pr = {
      spot: spot,
      moving_average: ma,
      stable: 0,
      stable_ma: 0,
      reserve: 0,
      reserve_ma: 0,
      reserve_ratio: 0,
      reserve_ratio_ma: 0,
      yield_price: 0,
      timestamp: timestamp,
      signature: signature,
    };

    const response = JSON.stringify({ pr, status: 'OK' });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(response);
    console.log(`[${new Date().toISOString()}] GET /price/ spot=${spot} ma=${ma} ts=${timestamp} v=${version}`);
    return;
  }

  if (req.method === 'POST' && url.pathname === '/set-price') {
    const body = await readBody(req);
    try {
      const data = JSON.parse(body);
      if (data.spot !== undefined) {
        currentSpot = parseInt(data.spot, 10);
        // Inline MA override: set both spot and MA in one call
        if (data.moving_average !== undefined) {
          currentMA = data.moving_average === null ? null : parseInt(data.moving_average, 10);
          maMode = 'manual';
        }
        console.log(`[${new Date().toISOString()}] Price set to ${currentSpot}${data.moving_average !== undefined ? ` (ma=${currentMA})` : ''}`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', spot: currentSpot, moving_average: currentMA }));
      } else {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Missing "spot" field' }));
      }
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
    return;
  }

  if (req.method === 'POST' && url.pathname === '/set-mode') {
    const body = await readBody(req);
    try {
      const data = JSON.parse(body);
      if (data.mode === 'mirror') {
        currentMode = 'mirror';
        startMirror();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', mode: 'mirror' }));
      } else if (data.mode === 'manual') {
        currentMode = 'manual';
        stopMirror();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', mode: 'manual' }));
      } else {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid mode. Use "manual" or "mirror"' }));
      }
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
    return;
  }

  if (req.method === 'POST' && url.pathname === '/set-ma') {
    const body = await readBody(req);
    try {
      const data = JSON.parse(body);
      if (data.moving_average !== undefined) {
        currentMA = parseInt(data.moving_average, 10);
        maMode = 'manual';
        console.log(`[${new Date().toISOString()}] MA set to ${currentMA} (manual mode)`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', moving_average: currentMA, ma_mode: maMode }));
      } else {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Missing "moving_average" field' }));
      }
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
    return;
  }

  if (req.method === 'POST' && url.pathname === '/set-ma-mode') {
    const body = await readBody(req);
    try {
      const data = JSON.parse(body);
      const validModes = ['spot', 'manual', 'ema', 'mirror'];
      if (data.mode && validModes.includes(data.mode)) {
        maMode = data.mode;
        if (data.ema_alpha !== undefined) {
          emaAlpha = parseFloat(data.ema_alpha);
        }
        if (maMode === 'mirror') startMirror();
        if (maMode === 'spot') currentMA = null;
        console.log(`[${new Date().toISOString()}] MA mode set to ${maMode} (ema_alpha=${emaAlpha})`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', ma_mode: maMode, ema_alpha: emaAlpha }));
      } else {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: `Invalid mode. Use one of: ${validModes.join(', ')}` }));
      }
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
    return;
  }

  if (req.method === 'POST' && url.pathname === '/set-supply-mode') {
    const body = await readBody(req);
    try {
      const data = JSON.parse(body);
      if (data.mode === 'sync') {
        if (data.threshold !== undefined) {
          supplyThreshold = parseInt(data.threshold, 10);
        }
        supplyMode = 'sync';
        startSupplySync();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', supply_mode: supplyMode }));
      } else if (data.mode === 'off') {
        supplyMode = 'off';
        stopSupplySync();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', supply_mode: supplyMode }));
      } else {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid mode. Use "sync" or "off"' }));
      }
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
    return;
  }

  if (req.method === 'GET' && url.pathname === '/supply-status') {
    const result = {
      supply_mode: supplyMode,
      supply_last_sync: supplyLastSync,
      supply_last_deltas: supplyLastDeltas,
      supply_threshold: supplyThreshold,
      supply_poll_ms: SUPPLY_POLL_MS,
      gov_wallet_rpc: GOV_WALLET_RPC ? 'configured' : 'not set',
    };
    // Fetch current supply snapshot if possible
    try {
      const devnet = await getDevnetSupply();
      result.devnet_supply = devnet;
    } catch (e) {
      result.devnet_supply = null;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(result));
    return;
  }

  if (req.method === 'GET' && url.pathname === '/status') {
    const status = {
      spot: currentSpot,
      moving_average: getEffectiveMA(currentSpot),
      ma_mode: maMode,
      ema_alpha: emaAlpha,
      status: 'running',
      mode: currentMode,
      supply_mode: supplyMode,
    };
    if (mirrorSpot !== null) {
      status.mirror_spot = mirrorSpot;
      status.mirror_ma = mirrorMA;
      status.mirror_last_fetch = mirrorLastFetch;
      status.mirror_source = MAINNET_ORACLE;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(status));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Fake oracle running on port ${PORT}`);
  console.log(`Current spot price: ${currentSpot} ($${currentSpot / 1e12} ZEPH/USD)`);
  console.log(`Endpoints:`);
  console.log(`  GET  /price/?timestamp=<ts>&version=<hf>  - get pricing record`);
  console.log(`  POST /set-price    {"spot": <value>}           - change spot price`);
  console.log(`  POST /set-mode     {"mode": "manual"|"mirror"} - switch price mode`);
  console.log(`  POST /set-ma       {"moving_average": <value>} - set MA (switches to manual MA)`);
  console.log(`  POST /set-ma-mode  {"mode": "spot|manual|ema|mirror", "ema_alpha": 0.1}`);
  console.log(`  POST /set-supply-mode {"mode": "off|sync"}     - toggle supply sync`);
  console.log(`  GET  /supply-status                            - supply sync state`);
  console.log(`  GET  /status                                   - current config`);
});
