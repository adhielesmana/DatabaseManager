const state = {
  user: null,
  tables: [],
  activeTable: null,
  rows: [],
  queryRows: [],
  limit: 50,
  offset: 0,
  importJob: null,
  importPollTimer: null
};

const selectors = {
  loginView: '#login-view',
  dashboardView: '#dashboard-view',
  message: '#message',
  tableList: '#table-list',
  tablesPanel: '#tables-panel',
  dataPanel: '#table-data',
  tableName: '#active-table-name',
  exportBtn: '#export-table',
  importInput: '#import-file',
  importBtn: '#import-submit',
  importStatus: '#import-status',
  queryTextarea: '#custom-query',
  queryResult: '#query-result',
  refreshBtn: '#refresh-tables',
  sessionUser: '#current-user',
  sessionRole: '#current-role',
  logoutBtn: '#logout'
};

const dom = {};

function $(selector) {
  return dom[selector] || (dom[selector] = document.querySelector(selector));
}

function showMessage(text, mode = 'info') {
  const el = $(selectors.message);
  el.textContent = text;
  el.dataset.state = mode;
  if (mode === 'error') {
    el.classList.add('visible');
  } else if (text) {
    el.classList.add('visible');
  } else {
    el.classList.remove('visible');
  }
}

function clearMessage() {
  showMessage('');
}

async function requestJSON(method, path, body) {
  const headers = { Accept: 'application/json' };
  const options = { method, credentials: 'include', headers };
  if (body) {
    headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(body);
  }
  const res = await fetch(path, options);
  if (res.status === 204) {
    return null;
  }
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const message = data?.error || res.statusText || 'Request failed';
    throw new Error(message);
  }
  return data;
}

async function init() {
  try {
    const session = await requestJSON('GET', '/api/session');
    if (session && session.username) {
      state.user = session;
      showDashboard();
      await refreshImportStatus();
      await refreshTables();
    } else {
      showLogin();
    }
  } catch (err) {
    console.error(err);
    showLogin();
  }
}

function showLogin() {
  stopImportPolling();
  document.querySelector(selectors.loginView).classList.remove('hidden');
  document.querySelector(selectors.dashboardView).classList.add('hidden');
  clearMessage();
}

function showDashboard() {
  document.querySelector(selectors.loginView).classList.add('hidden');
  document.querySelector(selectors.dashboardView).classList.remove('hidden');
  $(selectors.sessionUser).textContent = state.user.username;
  $(selectors.sessionRole).textContent = state.user.role;
  clearMessage();
  updateRoleControls();
}

function updateRoleControls() {
  const isAdmin = state.user && ['admin', 'superadmin'].includes(state.user.role);
  const isSuperadmin = state.user && state.user.role === 'superadmin';
  const importLocked = !isSuperadmin || (state.importJob && state.importJob.status === 'running');
  $(selectors.exportBtn).disabled = !isAdmin;
  $(selectors.importBtn).disabled = importLocked;
  $(selectors.importInput).disabled = importLocked;
}

function stopImportPolling() {
  if (state.importPollTimer) {
    window.clearTimeout(state.importPollTimer);
    state.importPollTimer = null;
  }
}

function scheduleImportPolling(jobId) {
  stopImportPolling();
  state.importPollTimer = window.setTimeout(() => {
    refreshImportStatus(jobId).catch((error) => {
      console.error(error);
    });
  }, 1500);
}

function renderImportStatus() {
  const el = $(selectors.importStatus);
  const job = state.importJob;
  if (!el) return;
  if (!job) {
    el.textContent = 'No SQL import has been run yet.';
    updateRoleControls();
    return;
  }

  const sizeMb = job.size ? `${(job.size / (1024 * 1024)).toFixed(2)} MB` : 'unknown size';
  let text = `SQL import ${job.status}: ${job.filename} (${sizeMb}) - ${job.stage}.`;
  if (job.finishedAt) {
    text += ` Finished at ${new Date(job.finishedAt).toLocaleString()}.`;
  }
  if (job.error) {
    text += ` Error: ${job.error}`;
  }
  el.textContent = text;
  updateRoleControls();
}

async function refreshImportStatus(jobId) {
  if (!state.user || state.user.role !== 'superadmin') {
    state.importJob = null;
    renderImportStatus();
    return;
  }

  try {
    const path = jobId ? `/api/database/import/${jobId}` : '/api/database/import/latest';
    const job = await requestJSON('GET', path);
    state.importJob = job;
    renderImportStatus();
    if (job && job.status === 'running') {
      scheduleImportPolling(job.id);
    } else {
      stopImportPolling();
      if (job && job.status === 'completed') {
        await refreshTables();
        if (state.activeTable) {
          await loadTableData();
        }
      }
    }
  } catch (error) {
    if (error.message === 'Request failed') {
      state.importJob = null;
      renderImportStatus();
      return;
    }
    throw error;
  }
}

async function refreshTables() {
  if (!state.user) return;
  try {
    const tables = await requestJSON('GET', '/api/tables');
    state.tables = tables || [];
    renderTableList();
  } catch (error) {
    console.error(error);
    showMessage(error.message, 'error');
  }
}

function renderTableList() {
  const container = $(selectors.tableList);
  container.innerHTML = '';
  if (!state.tables.length) {
    container.innerHTML = '<p class="muted">No tables found.</p>';
    return;
  }
  state.tables.forEach((table) => {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'table-row';
    row.textContent = `${table.TABLE_NAME} (${table.ENGINE || 'n/a'})`;
    if (table.TABLE_NAME === state.activeTable) {
      row.classList.add('active');
    }
    row.addEventListener('click', () => setActiveTable(table.TABLE_NAME));
    container.appendChild(row);
  });
}

function setActiveTable(name) {
  if (!name) return;
  state.activeTable = name;
  state.offset = 0;
  $(selectors.tableName).textContent = name;
  loadTableData();
}

async function loadTableData() {
  if (!state.activeTable) return;
  try {
    const result = await requestJSON('GET', `/api/table/${state.activeTable}/data?limit=${state.limit}&offset=${state.offset}`);
    state.rows = result.rows || [];
    renderRows(state.rows);
  } catch (error) {
    console.error(error);
    showMessage(error.message, 'error');
  }
}

function renderRows(rows) {
  const container = $(selectors.dataPanel);
  container.innerHTML = '';
  if (!rows.length) {
    container.innerHTML = '<p class="muted">No rows to display.</p>';
    return;
  }
  const table = document.createElement('table');
  const header = document.createElement('thead');
  const headerRow = document.createElement('tr');
  Object.keys(rows[0]).forEach((col) => {
    const th = document.createElement('th');
    th.textContent = col;
    headerRow.appendChild(th);
  });
  header.appendChild(headerRow);
  const body = document.createElement('tbody');
  rows.forEach((row) => {
    const tr = document.createElement('tr');
    Object.values(row).forEach((value) => {
      const td = document.createElement('td');
      td.textContent = value === null ? 'NULL' : value.toString();
      tr.appendChild(td);
    });
    body.appendChild(tr);
  });
  table.appendChild(header);
  table.appendChild(body);
  container.appendChild(table);
}

async function handleLogin(event) {
  event.preventDefault();
  const username = document.getElementById('username').value.trim();
  const password = document.getElementById('password').value;
  try {
    const user = await requestJSON('POST', '/api/login', { username, password });
    state.user = user;
    showDashboard();
    await refreshImportStatus();
    await refreshTables();
  } catch (error) {
    showMessage(error.message, 'error');
  }
}

async function handleLogout() {
  try {
    await requestJSON('POST', '/api/logout');
  } finally {
    state.user = null;
    state.activeTable = null;
    state.importJob = null;
    document.getElementById('login-form').reset();
    showLogin();
  }
}

async function handleQuery() {
  const sql = $(selectors.queryTextarea).value.trim();
  if (!sql) {
    showMessage('Write a SELECT query first', 'error');
    return;
  }
  try {
    const { rows } = await requestJSON('POST', '/api/query', { sql });
    renderQueryResult(rows || []);
  } catch (error) {
    showMessage(error.message, 'error');
  }
}

function renderQueryResult(rows) {
  const container = $(selectors.queryResult);
  container.innerHTML = '';
  if (!rows.length) {
    container.innerHTML = '<p class="muted">Query returned no rows.</p>';
    return;
  }
  const table = document.createElement('table');
  const header = document.createElement('thead');
  const headerRow = document.createElement('tr');
  Object.keys(rows[0]).forEach((col) => {
    const th = document.createElement('th');
    th.textContent = col;
    headerRow.appendChild(th);
  });
  header.appendChild(headerRow);
  const body = document.createElement('tbody');
  rows.forEach((row) => {
    const tr = document.createElement('tr');
    Object.values(row).forEach((value) => {
      const td = document.createElement('td');
      td.textContent = value === null ? 'NULL' : value.toString();
      tr.appendChild(td);
    });
    body.appendChild(tr);
  });
  table.appendChild(header);
  table.appendChild(body);
  container.appendChild(table);
}

async function handleExport() {
  if (!state.activeTable) return;
  window.location.href = `/api/table/${state.activeTable}/export`;
}

async function handleImport() {
  const fileInput = $(selectors.importInput);
  if (!fileInput.files.length) {
    showMessage('Attach a SQL file first', 'error');
    return;
  }
  const formData = new FormData();
  formData.append('payload', fileInput.files[0]);
  try {
    const res = await fetch('/api/database/import', {
      method: 'POST',
      body: formData,
      credentials: 'include'
    });
    const data = await res.json().catch(() => null);
    if (!res.ok) {
      throw new Error(data?.error || 'SQL import failed');
    }
    state.importJob = data;
    renderImportStatus();
    showMessage('SQL import started', 'info');
    scheduleImportPolling(data.id);
    fileInput.value = '';
  } catch (error) {
    showMessage(error.message, 'error');
  }
}

document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('login-form').addEventListener('submit', handleLogin);
  document.getElementById('refresh-tables').addEventListener('click', refreshTables);
  document.getElementById('run-query').addEventListener('click', handleQuery);
  document.getElementById('logout').addEventListener('click', handleLogout);
  document.getElementById('export-table').addEventListener('click', handleExport);
  document.getElementById('import-submit').addEventListener('click', handleImport);
  init();
});
