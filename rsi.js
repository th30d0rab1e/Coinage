const { sign } = require('jsonwebtoken');
const crypto = require('crypto');
const axios = require('axios');
const fs = require('fs');

const key_name = 'organizations/eab2ac44-6881-429e-b458-4c9a0de28d4d/apiKeys/3e293fe4-d6cc-4ef1-b38a-880212a1895c';
const key_secret = `-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIPGYcxYEL+oBD7ZZt501/BsMamu6mvksmBa/Yf56DJW7oAoGCCqGSM49
AwEHoUQDQgAE7hyEAVtdpCCl2MQMlNZ97dvEQpWds/Pg5ezUJBtBBKaS6nvkpNJY
6vQiw/T9ESNMOQiFAYWVf691IHYyBk2rsA==
-----END EC PRIVATE KEY-----`;

const getDateRange = () => {
  const endDate = new Date(); // Today, 2025-03-29, 4:41 PM CDT
  const startDate = new Date();
  startDate.setDate(endDate.getDate() - 15); // 15 days back for 14 diffs

  startDate.setUTCHours(0, 0, 0, 0);
  endDate.setUTCHours(0, 0, 0, 0);

  const start = Math.floor(startDate.getTime() / 1000); // March 14
  const end = Math.floor(endDate.getTime() / 1000);    // March 28
  return { start, end };
};

const generateJWT = (method, path) => {
  const uri = `${method} api.coinbase.com${path}`;
  return sign(
    { iss: 'coinbase-cloud', nbf: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 120, sub: key_name, aud: ['advanced-trade'], uri },
    key_secret,
    { algorithm: 'ES256', header: { kid: key_name, nonce: crypto.randomBytes(16).toString('hex') } }
  );
};

const fetchCoinbaseData = async () => {
  const { start, end } = getDateRange();
  const url = 'https://api.coinbase.com/api/v3/brokerage/products/BTC-USD/candles';
  const token = generateJWT('GET', '/api/v3/brokerage/products/BTC-USD/candles');

  const params = { granularity: 'ONE_DAY', start, end };
  console.log(`Fetching: ${start} (${new Date(start * 1000).toUTCString()}) to ${end} (${new Date(end * 1000).toUTCString()})`);

  try {
    const response = await axios.get(url, {
      params,
      headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }
    });
    const candles = response.data.candles.map(c => ({
      start: parseInt(c.start),
      close: parseFloat(c.close)
    }));
    fs.appendFileSync('/Users/theodorecross/Coinbase tedTosterone/outputLog.txt', `Candles: ${JSON.stringify(candles)}\n`);
    return candles;
  } catch (error) {
    fs.appendFileSync('/Users/theodorecross/Coinbase tedTosterone/outputLog.txt', `Error: ${error.response?.status || error.message}\n`);
    console.error(error.message);
    return null;
  }
};

const calculateRSI = (candles) => {
  const sortedCandles = candles.sort((a, b) => a.start - b.start);
  const closes = sortedCandles.map(c => c.close);
  fs.appendFileSync('/Users/theodorecross/Coinbase tedTosterone/outputLog.txt', `Closes: ${closes.join(', ')}\n`);

  const gains = [];
  const losses = [];
  for (let i = 1; i < closes.length; i++) {
    const change = closes[i] - closes[i - 1];
    gains.push(change > 0 ? change : 0);
    losses.push(change < 0 ? -change : 0);
  }
  fs.appendFileSync('/Users/theodorecross/Coinbase tedTosterone/outputLog.txt', `Gains: ${gains.join(', ')}\nLosses: ${losses.join(', ')}\n`);

  const last14Gains = gains.slice(-14);
  const last14Losses = losses.slice(-14);
  fs.appendFileSync('/Users/theodorecross/Coinbase tedTosterone/outputLog.txt', `Last 14 Gains: ${last14Gains.join(', ')}\nLast 14 Losses: ${last14Losses.join(', ')}\n`);

  const avgGain = last14Gains.reduce((sum, val) => sum + val, 0) / 14;
  const avgLoss = last14Losses.reduce((sum, val) => sum + val, 0) / 14;
  fs.appendFileSync('/Users/theodorecross/Coinbase tedTosterone/outputLog.txt', `Avg Gain: ${avgGain}, Avg Loss: ${avgLoss}\n`);

  const rs = avgLoss === 0 ? Infinity : avgGain / avgLoss;
  const rsi = rs === Infinity ? 100 : 100 - (100 / (1 + rs));
  return Number(rsi.toFixed(2));
};

const main = async () => {
  const candles = await fetchCoinbaseData();
  if (!candles || candles.length < 15) {
    console.error('Not enough data for RSI 14');
    return;
  }

  const rsi = calculateRSI(candles);
  const today = new Date().toLocaleString('en-US', { timeZone: 'America/Chicago' });
  console.log(`RSI 14 SMA for BTC/USD as of March 28: ${rsi}`);
  console.log(`Calculated at: ${today}`);

  fs.appendFileSync('/Users/theodorecross/Coinbase tedTosterone/outputLog.txt', `RSI 14 SMA: ${rsi}, Calculated at: ${today}\n`);
};

main();