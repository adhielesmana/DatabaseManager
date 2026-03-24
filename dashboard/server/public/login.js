const messageEl = document.getElementById('message');
const loginForm = document.getElementById('login-form');
const loginButton = loginForm.querySelector('button[type="submit"]');
const showMessage = (text, mode = 'info') => {
  messageEl.textContent = text;
  messageEl.dataset.state = mode;
  messageEl.classList.add('visible');
};
const clearMessage = () => {
  messageEl.textContent = '';
  messageEl.classList.remove('visible');
};

async function checkSession() {
  try {
    const res = await fetch('/api/session', { credentials: 'include' });
    if (res.ok) {
      const data = await res.json();
      if (data && data.username) {
        window.location.href = '/dashboard';
      }
    }
  } catch (err) {
    console.error(err);
  }
}

loginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  clearMessage();
  loginButton.disabled = true;
  const payload = {
    username: document.getElementById('username').value.trim(),
    password: document.getElementById('password').value
  };
  try {
    const res = await fetch('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify(payload)
    });
    if (!res.ok) {
      const data = await res.json().catch(() => null);
      throw new Error(data?.error || 'Login failed');
    }
    window.location.href = '/dashboard';
  } catch (error) {
    showMessage(error.message, 'error');
  } finally {
    loginButton.disabled = false;
  }
});

document.addEventListener('DOMContentLoaded', () => checkSession());
