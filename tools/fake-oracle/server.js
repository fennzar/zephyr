const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.ORACLE_PORT || '5555', 10);
const PRIVATE_KEY_PATH = path.join(__dirname, 'oracle_private.pem');

const privateKey = fs.readFileSync(PRIVATE_KEY_PATH, 'utf8');

// Default spot price: $15 per ZEPH in atomic units (COIN = 10^12)
let currentSpot = 15000000000000;

// Mirror mode state
let currentMode = 'manual';
let mirrorSpot = null;
let mirrorLastFetch = null;
let mirrorInterval = null;
const MIRROR_POLL_MS = 30000;
const MAINNET_ORACLE = 'oracle.zephyrprotocol.com';

function signPricingRecord(spot, timestamp) {
  const message = JSON.stringify({ spot, timestamp });
  const sign = crypto.createSign('SHA256');
  sign.update(message);
  sign.end();
  const signature = sign.sign(privateKey);
  return signature.toString('hex');
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
            resolve(parsed.pr.spot);
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
    const spot = await fetchMainnetPrice();
    mirrorSpot = spot;
    mirrorLastFetch = new Date().toISOString();
    if (currentMode === 'mirror') {
      currentSpot = mirrorSpot;
    }
    console.log(`[${mirrorLastFetch}] Mirror: fetched spot=${spot} ($${spot / 1e12})`);
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
    const pr = {
      spot: spot,
      moving_average: spot,
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
    console.log(`[${new Date().toISOString()}] GET /price/ spot=${spot} ts=${timestamp} v=${version}`);
    return;
  }

  if (req.method === 'POST' && url.pathname === '/set-price') {
    const body = await readBody(req);
    try {
      const data = JSON.parse(body);
      if (data.spot !== undefined) {
        currentSpot = parseInt(data.spot, 10);
        console.log(`[${new Date().toISOString()}] Price set to ${currentSpot}`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'OK', spot: currentSpot }));
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

  if (req.method === 'GET' && url.pathname === '/status') {
    const status = {
      spot: currentSpot,
      status: 'running',
      mode: currentMode,
    };
    if (mirrorSpot !== null) {
      status.mirror_spot = mirrorSpot;
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
  console.log(`  POST /set-price  {"spot": <value>}        - change spot price`);
  console.log(`  POST /set-mode   {"mode": "manual"|"mirror"} - switch mode`);
  console.log(`  GET  /status                              - current config`);
});
