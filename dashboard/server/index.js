const fs = require('fs');
const path = require('path');
const https = require('https');
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const session = require('express-session');
const multer = require('multer');
const mysql = require('mysql2/promise');
const bcrypt = require('bcryptjs');
const dotenv = require('dotenv');
const { stringify } = require('csv-stringify/sync');
const { parse } = require('csv-parse/sync');

dotenv.config({ path: path.join(__dirname, '.env') });

const {
  DB_HOST = 'mysql',
  DB_PORT = 3306,
  DB_USER = 'db_admin',
  DB_PASSWORD = '',
  DB_NAME = 'dbmanager',
  SESSION_SECRET = 'change-this-secret',
  SSL_CA,
  SSL_CERT,
  SSL_KEY,
  PORT = 8443,
  APP_BUILD_ID = 'dev',
  ALLOWED_ORIGINS = '',
  DASHBOARD_SUPERADMIN_USERNAME = '',
  DASHBOARD_SUPERADMIN_PASSWORD = '',
  DASHBOARD_ADMIN_USERNAME = '',
  DASHBOARD_ADMIN_PASSWORD = '',
  DASHBOARD_USER_USERNAME = '',
  DASHBOARD_USER_PASSWORD = ''
} = process.env;

const SKIP_INTERNAL_TLS = ['1', 'true', 'yes'].includes((process.env.SKIP_INTERNAL_TLS || '').toLowerCase());

if (!SKIP_INTERNAL_TLS && (!SSL_CA || !SSL_CERT || !SSL_KEY)) {
  console.error('Dashboard TLS certificates are missing. Set SSL_CA, SSL_CERT, and SSL_KEY or enable SKIP_INTERNAL_TLS.');
  process.exit(1);
}

if (!DB_PASSWORD || DB_PASSWORD.startsWith('replace-')) {
  console.error('Dashboard database credentials are missing. Set DB_PASSWORD in dashboard/.env before starting the server.');
  process.exit(1);
}

function buildDashboardUsers() {
  const configuredUsers = [
    {
      username: DASHBOARD_SUPERADMIN_USERNAME,
      password: DASHBOARD_SUPERADMIN_PASSWORD,
      role: 'superadmin'
    },
    {
      username: DASHBOARD_ADMIN_USERNAME,
      password: DASHBOARD_ADMIN_PASSWORD,
      role: 'admin'
    },
    {
      username: DASHBOARD_USER_USERNAME,
      password: DASHBOARD_USER_PASSWORD,
      role: 'user'
    }
  ];

  for (const user of configuredUsers) {
    if (
      !user.username ||
      !user.password ||
      user.username.startsWith('replace-') ||
      user.password.startsWith('replace-')
    ) {
      console.error(`Dashboard ${user.role} credentials are missing. Set them in dashboard/.env before starting the server.`);
      process.exit(1);
    }
  }

  return configuredUsers.map((user) => ({
    username: user.username,
    passwordHash: bcrypt.hashSync(user.password, 10),
    role: user.role
  }));
}

const USERS = buildDashboardUsers();
const staticRoot = path.join(__dirname, 'public');
const indexTemplate = fs.readFileSync(path.join(staticRoot, 'index.html'), 'utf8');
const renderedIndex = indexTemplate.replace(/__APP_BUILD_ID__/g, APP_BUILD_ID);
const SESSION_COOKIE_NAME = 'dbmanager.sid';

const ROLE_LEVEL = {
  user: 1,
  admin: 2,
  superadmin: 3
};

const allowedOrigins = ALLOWED_ORIGINS.split(',')
  .map((x) => x.trim())
  .filter(Boolean);

const corsOptions = {
  origin(origin, callback) {
    if (!origin || allowedOrigins.length === 0 || allowedOrigins.includes(origin)) {
      callback(null, true);
      return;
    }
    callback(new Error('Origin not allowed'));
  },
  credentials: true
};

const pool = mysql.createPool({
  host: DB_HOST,
  port: Number(DB_PORT),
  user: DB_USER,
  password: DB_PASSWORD,
  database: DB_NAME,
  waitForConnections: true,
  connectionLimit: 12,
  queueLimit: 0,
  ssl: {
    ca: fs.readFileSync(SSL_CA)
  },
  multipleStatements: false
});

const app = express();
app.set('trust proxy', 1);
app.disable('etag');
app.use(cors(corsOptions));
app.use(helmet({ contentSecurityPolicy: false }));
app.use((req, res, next) => {
  res.set('X-App-Build', APP_BUILD_ID);
  res.clearCookie('connect.sid', {
    httpOnly: true,
    secure: true,
    sameSite: 'none'
  });
  if (req.path === '/' || req.path.endsWith('.html') || req.path.startsWith('/api/')) {
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');
    if (req.path === '/' || req.path.endsWith('.html')) {
      res.set('Clear-Site-Data', '"cache"');
    }
  }
  next();
});
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false }));
app.use(
  session({
    name: SESSION_COOKIE_NAME,
    secret: SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    cookie: {
      httpOnly: true,
      secure: true,
      sameSite: 'lax',
      maxAge: 1000 * 60 * 60
    }
  })
);
app.use(
  express.static(staticRoot, {
    index: false,
    etag: false,
    lastModified: false,
    maxAge: 0,
    setHeaders(res) {
      res.set('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
      res.set('Pragma', 'no-cache');
      res.set('Expires', '0');
    }
  })
);

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 5 * 1024 * 1024 } });

function requireAuth(req, res, next) {
  if (!req.session.user) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  next();
}

function requireRole(level) {
  return (req, res, next) => {
    req.session.user = req.session.user || null;
    if (!req.session.user) {
      return res.status(401).json({ error: 'Authentication required' });
    }
    if (ROLE_LEVEL[req.session.user.role] < ROLE_LEVEL[level]) {
      return res.status(403).json({ error: 'Insufficient role' });
    }
    next();
  };
}

function tableNameSafe(name) {
  return /^[a-zA-Z0-9_]+$/.test(name);
}

app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) {
    return res.status(400).json({ error: 'Username and password are required' });
  }
  const user = USERS.find((u) => u.username === username);
  if (!user || !bcrypt.compareSync(password, user.passwordHash)) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  req.session.user = { username: user.username, role: user.role };
  res.json({ username: user.username, role: user.role });
});

app.post('/api/logout', requireAuth, (req, res) => {
  req.session.destroy(() => res.json({ status: 'signed out' }));
});

app.get('/api/session', (req, res) => {
  if (!req.session.user) {
    return res.status(204).end();
  }
  res.json(req.session.user);
});

app.get('/api/tables', requireAuth, async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT TABLE_NAME, TABLE_ROWS, ENGINE, TABLE_COLLATION FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME',
      [DB_NAME]
    );
    res.json(rows);
  } catch (error) {
    console.error('tables', error);
    res.status(500).json({ error: 'Unable to list tables' });
  }
});

app.get('/api/table/:table/columns', requireAuth, async (req, res) => {
  const { table } = req.params;
  if (!tableNameSafe(table)) {
    return res.status(400).json({ error: 'Invalid table name' });
  }
  try {
    const [columns] = await pool.query(
      'SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION',
      [DB_NAME, table]
    );
    res.json(columns);
  } catch (error) {
    console.error('columns', error);
    res.status(500).json({ error: 'Unable to describe table' });
  }
});

app.get('/api/table/:table/data', requireAuth, async (req, res) => {
  const { table } = req.params;
  const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 50, 1), 200);
  const offset = Math.max(parseInt(req.query.offset, 10) || 0, 0);
  if (!tableNameSafe(table)) {
    return res.status(400).json({ error: 'Invalid table name' });
  }
  try {
    const [rows] = await pool.query('SELECT * FROM ?? LIMIT ? OFFSET ?', [table, limit, offset]);
    res.json({ rows, limit, offset });
  } catch (error) {
    console.error('table-data', error);
    res.status(500).json({ error: 'Unable to read table' });
  }
});

app.post('/api/query', requireAuth, async (req, res) => {
  const { sql } = req.body || {};
  if (!sql) {
    return res.status(400).json({ error: 'SQL is required' });
  }
  const normalized = sql.trim().toLowerCase();
  if (!normalized.startsWith('select') || normalized.includes(';')) {
    return res.status(400).json({ error: 'Only single SELECT statements are allowed' });
  }
  try {
    const [rows] = await pool.query(sql);
    res.json({ rows });
  } catch (error) {
    console.error('query', error);
    res.status(500).json({ error: 'Query failed', detail: error.message });
  }
});

app.get('/api/table/:table/export', requireRole('admin'), async (req, res) => {
  const { table } = req.params;
  if (!tableNameSafe(table)) {
    return res.status(400).json({ error: 'Invalid table name' });
  }
  try {
    const [rows] = await pool.query('SELECT * FROM ??', [table]);
    const csv = stringify(rows, { header: true });
    res.set('Content-Type', 'text/csv');
    res.set('Content-Disposition', `attachment; filename="${table}.csv"`);
    res.send(csv);
  } catch (error) {
    console.error('export', error);
    res.status(500).json({ error: 'Export failed' });
  }
});

app.post('/api/table/:table/import', requireRole('admin'), upload.single('payload'), async (req, res) => {
  const { table } = req.params;
  if (!tableNameSafe(table)) {
    return res.status(400).json({ error: 'Invalid table name' });
  }
  if (!req.file) {
    return res.status(400).json({ error: 'CSV file is required' });
  }
  try {
    const records = parse(req.file.buffer, { columns: true, skip_empty_lines: true });
    if (!records.length) {
      return res.status(400).json({ error: 'CSV did not contain any rows' });
    }
    const columns = Object.keys(records[0]);
    if (!columns.every((col) => /^[a-zA-Z0-9_]+$/.test(col))) {
      return res.status(400).json({ error: 'Column names must be alphanumeric or underscores' });
    }
    const queryColumns = columns.map(() => '??').join(', ');
    const placeholders = columns.map(() => '?').join(', ');
    const values = records.map((row) => columns.map((col) => row[col]));
    const insertTemplate = `INSERT INTO ?? (${queryColumns}) VALUES (${placeholders})`;
    const conn = await pool.getConnection();
    await conn.beginTransaction();
    try {
      for (const rowValues of values) {
        await conn.query(insertTemplate, [table, ...columns, ...rowValues]);
      }
      await conn.commit();
    } catch (innerError) {
      await conn.rollback();
      throw innerError;
    } finally {
      conn.release();
    }
    res.json({ rows: records.length });
  } catch (error) {
    console.error('import', error);
    res.status(500).json({ error: 'Import failed', detail: error.message });
  }
});

app.get('/api/status', (req, res) => {
  res.json({ uptime: process.uptime(), ready: true });
});

app.get('*', (req, res) => {
  res.type('html').send(renderedIndex);
});

if (SKIP_INTERNAL_TLS) {
  app.listen(PORT, () => {
    console.log(`Dashboard listening on http://0.0.0.0:${PORT} (TLS handled by the reverse proxy)`);
  });
} else {
  const credentials = {
    cert: fs.readFileSync(SSL_CERT),
    key: fs.readFileSync(SSL_KEY)
  };
  https.createServer(credentials, app).listen(PORT, () => {
    console.log(`Dashboard listening on https://0.0.0.0:${PORT}`);
  });
}
