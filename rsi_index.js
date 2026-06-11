const { Pool } = require('pg');

// Configure the connection
const pool = new Pool({
  user: 'theodorecross', // Homebrew default: your macOS username (run `whoami`)
  host: 'localhost',
  database: 'postgres',      // Default database, or use one you created (e.g., 'mydb')
  password: '',              // Homebrew default: blank; EDB: your set password
  port: 5432,                // Default PostgreSQL port
});

// Test the connection
async function testConnection() {
  try {
    const client = await pool.connect();
    console.log('Connected to PostgreSQL!');
    
    // Run a simple query
    const res = await client.query('SELECT NOW()');
    console.log('Current time from database:', res.rows[0]);
    
    // Release the client back to the pool
    client.release();
  } catch (err) {
    console.error('Connection error:', err.stack);
  } finally {
    await pool.end(); // Close the pool
  }
}

testConnection();