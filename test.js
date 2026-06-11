const { sign } = require('jsonwebtoken');
const crypto = require('crypto');
const axios = require('axios');

// Your credentials
const key_name = 'organizations/eab2ac44-6881-429e-b458-4c9a0de28d4d/apiKeys/3e293fe4-d6cc-4ef1-b38a-880212a1895c';
const key_secret = `-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIPGYcxYEL+oBD7ZZt501/BsMamu6mvksmBa/Yf56DJW7oAoGCCqGSM49
AwEHoUQDQgAE7hyEAVtdpCCl2MQMlNZ97dvEQpWds/Pg5ezUJBtBBKaS6nvkpNJY
6vQiw/T9ESNMOQiFAYWVf691IHYyBk2rsA==
-----END EC PRIVATE KEY-----`;

// Request details
const request_method = 'GET';
const request_path = '/api/v2/accounts/<account_id>/transactions';
const algorithm = 'ES256';

// Construct the URI for the JWT (method + path)
const uri = `${request_method} api.coinbase.com${request_path}`;
console.log(uri)

// Generate the JWT
const token = sign(
  {
    iss: 'coinbase-cloud', // Correct issuer for Coinbase Cloud
    nbf: Math.floor(Date.now() / 1000), // Not before
    exp: Math.floor(Date.now() / 1000) + 120, // Expires in 2 minutes
    sub: key_name, // Subject (your API key name)
    aud: ['advanced-trade'], // Audience for Advanced Trade
    uri: uri // URI for the request
  },
  key_secret,
  {
    algorithm: algorithm,
    header: {
      kid: key_name, // Key ID
      nonce: crypto.randomBytes(16).toString('hex') // Random nonce
    }
  }
);

console.log('JWT:', token);

// Axios request with the JWT in the Authorization header
const config = {
  method: 'get',
  url: 'https://api.coinbase.com/api/v2/accounts/<account_id>/transactions',
  headers: {
    'Authorization': `Bearer ${token}`, // Include the JWT here
    'Content-Type': 'application/json',
    'User-Agent': 'Node.js Coinbase Client' // Optional but good practice
  },
  maxBodyLength: Infinity
};

axios.request(config)
  .then((response) => {
    //console.log('Response:', JSON.stringify(response.data, null, 2));
  })
  .catch((error) => {
    if (error.response) {
      console.log('Error Status:', error.response.status);
      console.log('Error Response:', error.response.data);
    } else {
      console.log('Error:', error.message);
    }
  });