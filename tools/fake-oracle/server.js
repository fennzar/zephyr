const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.ORACLE_PORT || '5555', 10);
const PRIVATE_KEY_PATH = path.join(__dirname, 'oracle_private.pem');

const privateKey = fs.readFileSync(PRIVATE_KEY_PATH, 'utf8');

// Default spot price: $15 per ZEPH in atomic units (COIN = 10^12)
let currentSpot = 15000000000000;

function signPricingRecord(spot, timestamp) {
  const message = JSON.stringify({ spot, timestamp });
  const sign = crypto.createSign('SHA256');
  sign.update(message);
  sign.end();
  const signature = sign.sign(privateKey);
  return signature.toString('hex');
}

const server = http.createServer((req, res) => {
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
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
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
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ spot: currentSpot, status: 'running' }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Fake oracle running on port ${PORT}`);
  console.log(`Current spot price: ${currentSpot} (${currentSpot / 1e12} ZEPH/USD)`);
  console.log(`Endpoints:`);
  console.log(`  GET  /price/?timestamp=<ts>&version=<hf>  - get pricing record`);
  console.log(`  POST /set-price  {"spot": <value>}        - change spot price`);
  console.log(`  GET  /status                              - current config`);
});
