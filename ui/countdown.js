'use strict';

function formatRemaining(seconds) {
  const value = Math.max(0, Math.ceil(Number.isFinite(seconds) ? seconds : 0));
  const h = Math.floor(value / 3600);
  const m = Math.floor(value % 3600 / 60);
  const s = value % 60;
  return [h, m, s].map(part => String(part).padStart(2, '0')).join(':');
}

function remainingAt(seconds, receivedAt, now) {
  return Math.max(0, seconds - Math.max(0, now - receivedAt) / 1000);
}

if (typeof module !== 'undefined') module.exports = { formatRemaining, remainingAt };

if (typeof window !== 'undefined') {
  const panel = document.getElementById('daily-countdown');
  const reset = document.getElementById('reset-label');
  const clock = document.getElementById('remaining');
  let snapshot = null;

  const render = () => {
    if (!snapshot) return;
    const remaining = remainingAt(snapshot.seconds, snapshot.at, performance.now());
    panel.dataset.expired = String(remaining <= 0);
    clock.textContent = remaining <= 0 ? '更新中…' : formatRemaining(remaining);
  };

  window.addEventListener('message', event => {
    const data = event.data;
    if (!data || data.action !== 'suimag-dailyquest:countdown') return;
    if (data.visible !== true) {
      snapshot = null;
      panel.hidden = true;
      return;
    }
    if (!Number.isFinite(data.remaining) || typeof data.resetLabel !== 'string') return;
    snapshot = { seconds: Math.max(0, Math.min(86400, data.remaining)), at: performance.now() };
    reset.textContent = '次回 ' + data.resetLabel.slice(0, 128);
    panel.hidden = false;
    render();
  });
  setInterval(render, 250);

  // Read-only handshake; this page never requests focus or sends gameplay actions.
  if (typeof GetParentResourceName === 'function') {
    fetch('https://' + GetParentResourceName() + '/countdownReady', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
    }).catch(() => {});
  }
}
