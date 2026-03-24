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
  message: '#message',
  tableList: '#table-list',
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
  sidebarUser: '.sidebar-user',
  sidebarRole: '.sidebar-role',
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
    if (!session || !session.username) {
      window.location.href = '/';
      return;
    }
    state.user = session;
    syncSessionBadges();
    updateRoleControls();
    await refreshImportStatus();
    await refreshTables();
  } catch (error) {
    window.location.href = '/';
  }
}

function syncSessionBadges() {
  const usernameEls = document.querySelectorAll(`${selectors.sessionUser}, ${selectors.sidebarUser}`);
  const roleEls = document.querySelectorAll(`${selectors.sessionRole}, ${selectors.sidebarRole}`);
  const usernameText = state.user ? state.user.username : '';
  const roleText = state.user ? state.user.role : '';
  usernameEls.forEach((el) => {
    el.textContent = usernameText;
  });
  roleEls.forEach((el) => {
    el.textContent = roleText;
  });
}

function updateRoleControls() {
  const isAdmin = state.user && ['admin', 'superadmin'].includes(state.user.role);
  const isSuperadmin = state.user && state.user.role === 'superadmin';
  const importLocked = !isSuperadmin || (state.importJob && ['uploading', 'queued', 'running'].includes(state.importJob.status));
  $(selectors.exportBtn).disabled = !isAdmin;
  $(selectors.importBtn).disabled = importLocked;
  $(selectors.importInput).disabled = importLocked;
}

function uploadSqlFile(formData, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/database/import');
    xhr.withCredentials = true;
    xhr.upload.addEventListener('progress', (event) => {
      if (typeof onProgress === 'function') {
        onProgress(event);
      }
    });
    xhr.onerror = () => reject(new Error('SQL upload failed'));
    xhr.onabort = () => reject(new Error('SQL upload was cancelled'));
    xhr.onload = () => {
      let data = null;
      try {
        data = xhr.responseText ? JSON.parse(xhr.responseText) : null;
      } catch (error) {
        reject(new Error('Invalid response from SQL import endpoint'));
        return;
      }
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(data);
        return;
      }
      reject(new Error(data?.error || `SQL import failed (${xhr.status})`));
    };
    xhr.send(formData);
  });
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
    refreshImportStatus(jobId).catch((error) => console.error(error));
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
  if (job.status === 'uploading') {
    const percent = typeof job.progress === 'number' ? ` - ${job.progress}% uploaded` : '';
    text = `SQL upload in progress: ${job.filename} (${sizeMb})${percent}.`;
  }
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
    if (job && ['queued', 'running'].includes(job.status)) {
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
  const file = fileInput.files[0];
  const formData = new FormData();
  formData.append('payload', file);
  try {
    state.importJob = {
      id: null,
      filename: file.name,
      size: file.size,
      status: 'uploading',
      stage: 'Uploading SQL file',
      progress: 0,
      startedAt: new Date().toISOString(),
      finishedAt: null,
      error: null
    };
    renderImportStatus();
    showMessage('Uploading SQL file...', 'info');

    const data = await uploadSqlFile(formData, (event) => {
      const progress = event.lengthComputable ? Math.round((event.loaded / event.total) * 100) : null;
      state.importJob = {
        ...state.importJob,
        progress,
        stage: progress === null ? 'Uploading SQL file' : `Uploading SQL file (${progress}%)`
      };
      renderImportStatus();
    });

    state.importJob = { ...data, progress: null };
    renderImportStatus();
    showMessage('SQL import queued', 'info');
    scheduleImportPolling(data.id);
    fileInput.value = '';
  } catch (error) {
    state.importJob = {
      ...(state.importJob || {
        id: null,
        filename: file.name,
        size: file.size,
        startedAt: new Date().toISOString()
      }),
      status: 'failed',
      stage: 'Upload failed',
      finishedAt: new Date().toISOString(),
      error: error.message
    };
    renderImportStatus();
    showMessage(error.message, 'error');
  }
}

async function handleLogout() {
  try {
    await requestJSON('POST', '/api/logout');
  } finally {
    window.location.href = '/';
  }
}

document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('refresh-tables').addEventListener('click', refreshTables);
  document.getElementById('run-query').addEventListener('click', handleQuery);
  document.getElementById('logout').addEventListener('click', handleLogout);
  document.getElementById('export-table').addEventListener('click', handleExport);
  document.getElementById('import-submit').addEventListener('click', handleImport);
  init();
});
