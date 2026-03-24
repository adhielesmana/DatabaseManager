const fs = require('fs');
const path = require('path');
const https = require('https');
const { spawn } = require('child_process');
const crypto = require('crypto');
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
  DB_SSL_CA = '',
  DB_SSL_VERIFY = 'false',
  SESSION_SECRET = 'change-this-secret',
  SSL_CA,
  SSL_CERT,
  SSL_KEY,
  PORT = 8443,
  APP_BUILD_ID = 'dev',
  ALLOWED_ORIGINS = '',
  DASHBOARD_SUPERADMIN_USERNAME = '',
  DASHBOARD_SUPERADMIN_PASSWORD = '',
  DASHBOARD_SUPERADMIN_USERNAME_HASH = '',
  DASHBOARD_SUPERADMIN_PASSWORD_HASH = '',
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

if (!DB_SSL_CA || DB_SSL_CA.startsWith('replace-')) {
  console.error('Dashboard database TLS CA is missing. Set DB_SSL_CA in dashboard/.env before starting the server.');
  process.exit(1);
}

function buildDashboardUsers() {
  const configuredUsers = [
    {
      username: DASHBOARD_SUPERADMIN_USERNAME,
      password: DASHBOARD_SUPERADMIN_PASSWORD,
      usernameHash: DASHBOARD_SUPERADMIN_USERNAME_HASH,
      passwordHash: DASHBOARD_SUPERADMIN_PASSWORD_HASH,
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
      ((!user.username || user.username.startsWith('replace-')) &&
        (!user.usernameHash || user.usernameHash.startsWith('replace-'))) ||
      ((!user.password || user.password.startsWith('replace-')) &&
        (!user.passwordHash || user.passwordHash.startsWith('replace-')))
    ) {
      console.error(`Dashboard ${user.role} credentials are missing. Set them in dashboard/.env before starting the server.`);
      process.exit(1);
    }
  }

  return configuredUsers.map((user) => ({
    username: user.username && !user.username.startsWith('replace-') ? user.username : '',
    usernameHash:
      user.usernameHash && !user.usernameHash.startsWith('replace-')
        ? user.usernameHash
        : bcrypt.hashSync(user.username, 10),
    passwordHash:
      user.passwordHash && !user.passwordHash.startsWith('replace-')
        ? user.passwordHash
        : bcrypt.hashSync(user.password, 10),
    role: user.role
  }));
}

const USERS = buildDashboardUsers();
const staticRoot = path.join(__dirname, 'public');
const loginTemplate = fs.readFileSync(path.join(staticRoot, 'login.html'), 'utf8');
const dashboardTemplate = fs.readFileSync(path.join(staticRoot, 'dashboard.html'), 'utf8');
const renderedLogin = loginTemplate.replace(/__APP_BUILD_ID__/g, APP_BUILD_ID);
const renderedDashboard = dashboardTemplate.replace(/__APP_BUILD_ID__/g, APP_BUILD_ID);
const SESSION_COOKIE_NAME = 'dbmanager.sid';
const DB_TLS_VERIFY = !['0', 'false', 'no'].includes(String(DB_SSL_VERIFY).toLowerCase());
const importJobs = new Map();
let latestImportJobId = null;

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
    ca: fs.readFileSync(DB_SSL_CA),
    rejectUnauthorized: DB_TLS_VERIFY
  },
  multipleStatements: false
});

function runMysqlImport(sqlText) {
  return new Promise((resolve, reject) => {
    const args = [
      `--host=${DB_HOST}`,
      `--port=${Number(DB_PORT)}`,
      `--user=${DB_USER}`,
      `--password=${DB_PASSWORD}`,
      '--default-character-set=utf8mb4',
      `--ssl-mode=${DB_TLS_VERIFY ? 'VERIFY_CA' : 'REQUIRED'}`,
      `--ssl-ca=${DB_SSL_CA}`,
      DB_NAME
    ];

    const child = spawn('mysql', args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stderr = '';

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    child.on('error', (error) => {
      reject(error);
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(stderr.trim() || `mysql exited with code ${code}`));
    });

    child.stdin.end(sqlText);
  });
}

function serializeImportJob(job) {
  if (!job) {
    return null;
  }
  return {
    id: job.id,
    filename: job.filename,
    size: job.size,
    status: job.status,
    stage: job.stage,
    startedAt: job.startedAt,
    finishedAt: job.finishedAt,
    error: job.error || null
  };
}

function markImportJob(jobId, patch) {
  const current = importJobs.get(jobId);
  if (!current) {
    return null;
  }
  const updated = { ...current, ...patch };
  importJobs.set(jobId, updated);
  latestImportJobId = jobId;
  return updated;
}

function createImportJob(file) {
  const job = {
    id: crypto.randomUUID(),
    filename: file.originalname || 'database.sql',
    size: file.size || 0,
    status: 'queued',
    stage: 'Queued for import',
    startedAt: new Date().toISOString(),
    finishedAt: null,
    error: null
  };
  importJobs.set(job.id, job);
  latestImportJobId = job.id;
  return job;
}

async function runImportJob(jobId, sqlText) {
  markImportJob(jobId, {
    status: 'running',
    stage: 'Importing SQL into MySQL'
  });

  try {
    await runMysqlImport(sqlText);
    markImportJob(jobId, {
      status: 'completed',
      stage: 'Import completed successfully',
      finishedAt: new Date().toISOString(),
      error: null
    });
  } catch (error) {
    console.error('sql-import', error);
    markImportJob(jobId, {
      status: 'failed',
      stage: 'Import failed',
      finishedAt: new Date().toISOString(),
      error: error.message
    });
  }
}

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

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 100 * 1024 * 1024 } });

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
  const user = USERS.find((u) => {
    if (u.username) {
      return u.username === username;
    }
    return bcrypt.compareSync(username, u.usernameHash);
  });
  if (!user || !bcrypt.compareSync(password, user.passwordHash)) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  req.session.user = { username, role: user.role };
  res.json({ username, role: user.role });
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

app.post('/api/database/import', requireRole('superadmin'), upload.single('payload'), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'SQL file is required' });
  }

  const sqlText = req.file.buffer.toString('utf8').trim();
  if (!sqlText) {
    return res.status(400).json({ error: 'SQL file was empty' });
  }

  if (!/\.sql$/i.test(req.file.originalname || '')) {
    return res.status(400).json({ error: 'Only .sql files are allowed' });
  }

  const job = createImportJob(req.file);
  res.status(202).json(serializeImportJob(job));

  runImportJob(job.id, sqlText).catch((error) => {
    console.error('sql-import-unhandled', error);
    markImportJob(job.id, {
      status: 'failed',
      stage: 'Import failed',
      finishedAt: new Date().toISOString(),
      error: error.message
    });
  });
});

app.get('/api/database/import/latest', requireRole('superadmin'), (req, res) => {
  if (!latestImportJobId) {
    return res.status(204).end();
  }
  res.json(serializeImportJob(importJobs.get(latestImportJobId)));
});

app.get('/api/database/import/:jobId', requireRole('superadmin'), (req, res) => {
  const job = importJobs.get(req.params.jobId);
  if (!job) {
    return res.status(404).json({ error: 'Import job not found' });
  }
  res.json(serializeImportJob(job));
});

app.get('/api/status', (req, res) => {
  res.json({ uptime: process.uptime(), ready: true });
});

app.get('/', (req, res) => {
  res.type('html').send(renderedLogin);
});

app.get('/dashboard', requireAuth, (req, res) => {
  res.type('html').send(renderedDashboard);
});

app.get('*', (req, res) => {
  res.redirect('/');
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
