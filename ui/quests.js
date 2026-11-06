'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const app = $('quest-app');
  let board, period = 'daily', pending = false, busy = false;
  let editingPreferences = false, savingPreferences = false, viewEpoch = 0;
  function updateBusy() {
    const locked = busy || pending || savingPreferences;
    app.setAttribute('aria-busy', String(locked));
    app.querySelectorAll('button:not(#close):not([data-period])').forEach(el => { el.disabled = locked; });
    $('preferences-fields').disabled = locked;
    $('preferences-save').textContent = savingPreferences ? '保存中…' : board && board.needsSetup ? 'この設定でクエストを始める' : '設定を保存';
  }
  async function action(action, extra = {}) {
    const closing = action === 'close';
    const epoch = viewEpoch;
    if (!closing && (pending || busy)) return;
    if (!closing) pending = true;
    if (action === 'preferences') savingPreferences = true;
    updateBusy();
    $('gui-error').textContent = '';
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      if (typeof GetParentResourceName !== 'function') return;
      const response = await fetch(`https://${GetParentResourceName()}/questAction`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, period, ...extra }), signal: controller.signal
      });
      if (!response.ok) throw new Error('request');
    } catch (_) {
      if (epoch === viewEpoch) {
        savingPreferences = false;
        $('gui-error').textContent = '通信に失敗しました。少し待って再度お試しください。';
      }
    } finally {
      clearTimeout(timeout);
      if (epoch === viewEpoch) { if (!closing) pending = false; updateBusy(); }
    }
  }
  function node(tag, className, text) {
    const el = document.createElement(tag); el.className = className || '';
    if (text !== undefined) el.textContent = text;
    return el;
  }
  function button(text, kind, extra, className = 'action-button') {
    const el = node('button', className, text); el.onclick = () => action(kind, extra); return el;
  }
  function updatePreferenceSummary() {
    const included = ['一般'];
    for (const [key, title] of [['crime', '犯罪'], ['employment', '職業・所属必須']]) {
      const excluded = $('exclude-' + key).checked;
      $(key + '-option').classList.toggle('is-excluded', excluded);
      $(key + '-state').textContent = excluded ? '✓ 抽選から除外する' : '抽選候補に含める';
      if (!excluded) included.push(title);
    }
    $('preferences-summary').textContent = included.join(' ／ ');
  }
  function showPreferences() {
    editingPreferences = true;
    const prefs = board.preferences || { crime: true, employment: false };
    $('exclude-crime').checked = prefs.crime === true;
    $('exclude-employment').checked = prefs.employment === true;
    $('board-view').hidden = true;
    $('preferences-view').hidden = false;
    $('preferences').hidden = true;
    $('preferences-kicker').textContent = board.needsSetup ? 'はじめに · あなたに合ったクエストを' : 'QUEST PREFERENCES';
    $('preferences-timing').textContent = board.needsSetup
      ? '保存すると、最初のデイリー・ウィークリークエストを抽選します。'
      : '次回の更新・リロールから適用します。現在のクエスト・進捗・リロール回数は変わりません。';
    $('preferences-cancel').textContent = board.needsSetup ? 'あとで設定する' : '保存せず戻る';
    $('gui-error').textContent = '';
    updatePreferenceSummary();
    updateBusy();
    $('exclude-crime').focus();
  }
  function showBoard() {
    editingPreferences = false;
    $('preferences-view').hidden = true;
    $('board-view').hidden = false;
    $('preferences').hidden = false;
    $('gui-error').textContent = '';
    $('preferences').focus();
  }
  function cancelPreferences() {
    if (busy || pending || savingPreferences) return;
    if (board.needsSetup) action('close');
    else showBoard();
  }
  function render() {
    if (!board) return;
    const daily = period === 'daily';
    const quests = (Array.isArray(board.quests) ? board.quests : []).filter(q => q.period === period);
    const completed = quests.filter(q => q.value >= q.target).length;
    document.querySelectorAll('[data-period]').forEach(el => {
      el.setAttribute('aria-pressed', String(el.dataset.period === period));
    });
    $('period-label').textContent = daily ? 'TODAY’S CHALLENGES' : 'THIS WEEK’S CHALLENGES';
    $('section-title').textContent = board.needsSetup ? 'あなたに合った挑戦を。' : daily ? '今日のチャレンジ' : '今週のチャレンジ';
    $('completion').textContent = `${completed} / ${quests.length} COMPLETE`;
    $('board-note').textContent = board.needsSetup ? '抽選設定から、犯罪・職業条件の除外を選んでスタートしましょう。' : board.drawError ? '抽選候補が不足しています。抽選設定や連携元の状態を確認してください。' : `リロール残り ${(board.rerolls || {})[period] || 0}回 · 未達成のクエストを1件交換できます。`;
    const cards = $('quest-cards'); cards.replaceChildren(); cards.dataset.count = String(quests.length);
    quests.forEach((q, index) => {
      const done = q.value >= q.target, claimable = done && q.status === 'active';
      const state = q.status === 'claimed' ? '受取済み' : q.status === 'pending' ? '確認待ち' : claimable ? '達成！' : q.available === false ? '連携元が未起動' : '進行中';
      const card = node('article', 'quest-card' + (done ? ' completed' : ''));
      const top = node('div', 'card-top');
      top.append(node('span', 'quest-number', String(index + 1).padStart(2, '0')), node('span', 'status', state));
      card.append(top, node('p', 'category', q.tags && q.tags.crime ? 'CRIME / 犯罪' : q.tags && q.tags.employment ? 'WORK / 職業・所属必須' : 'LIFESTYLE / 一般'), node('h3', '', q.title), node('p', 'description', q.description));
      const factor = 10 ** (q.precision || 0), scale = q.scale || 1;
      card.append(node('p', 'progress-copy', `${Math.floor(q.value / scale * factor) / factor} / ${q.target / scale} ${q.unit || ''}`));
      const track = node('div', 'progress-track');
      track.setAttribute('role', 'progressbar'); track.setAttribute('aria-label', q.title);
      track.setAttribute('aria-valuemin', '0'); track.setAttribute('aria-valuemax', String(q.target)); track.setAttribute('aria-valuenow', String(Math.min(q.value, q.target)));
      const fill = node('div'); fill.style.width = `${Math.max(0, Math.min(100, q.value / q.target * 100))}%`; track.append(fill);
      const bottom = node('div', 'card-bottom'); bottom.append(node('div', 'reward', q.reward));
      if (claimable) bottom.append(button('報酬を受け取る ↗', 'claim', { id: q.id }));
      else if (q.canReroll) bottom.append(button('↻ 交換', 'reroll', { id: q.id }, 'secondary-button'));
      else bottom.append(node('span', 'muted', q.status === 'claimed' ? '✓' : state));
      card.append(track, bottom); cards.append(card);
    });
    if (!quests.length) cards.append(node('div', 'empty-state', board.needsSetup ? 'さあ、最初のクエストを見つけよう。' : '現在のクエストはありません。'));
    const bonus = $('bonus'); bonus.replaceChildren();
    if (daily && board.dailyBonus && !board.needsSetup) {
      const b = board.dailyBonus;
      const copy = node('div'); copy.append(node('p', 'eyebrow', '✧ DAILY COMPLETION BONUS'), node('h3', '', 'すべての挑戦に、もうひとつのご褒美。'), node('p', 'muted', `${b.completed} / ${b.total}件クリア · 追加 ${b.reward}`));
      bonus.append(copy, b.canClaim ? button('ボーナスを受け取る ↗', 'bonus') : node('span', 'bonus-state', b.status === 'claimed' ? '✓ 受取済み' : b.status === 'pending' ? '確認待ち' : '全クリアで解放'));
    }
    bonus.hidden = !bonus.childElementCount;
    updateBusy();
    $('reset-copy').textContent = `次回更新 ${daily ? board.dailyReset || '—' : board.weeklyReset || '—'} · ${daily ? '達成済みの未受取報酬は更新時に自動受取' : '報酬は期限内に受け取ってください'}`;
  }
  window.addEventListener('message', ({ data }) => {
    if (!data) return;
    if (data.action === 'suimag-dailyquest:busy') { busy = data.busy === true; updateBusy(); return; }
    if (data.action === 'suimag-dailyquest:preferencesResult') {
      if (app.hidden) return;
      savingPreferences = false;
      if (data.ok) { board.preferences = data.preferences; board.needsSetup = false; showBoard(); }
      else $('gui-error').textContent = data.message || '設定を保存できませんでした。再度お試しください。';
      updateBusy();
      return;
    }
    if (data.action !== 'suimag-dailyquest:gui') return;
    const wasHidden = app.hidden;
    app.hidden = data.visible !== true;
    busy = false;
    if (app.hidden) { viewEpoch++; pending = savingPreferences = false; editingPreferences = false; }
    if (!app.hidden && data.data) {
      board = data.data; if (data.selected === 'weekly' || data.selected === 'daily') period = data.selected;
      render();
      if (wasHidden) {
        showBoard();
        if (board.needsSetup) showPreferences();
        else $('close').focus();
      }
    }
  });
  document.querySelectorAll('[data-period]').forEach(el => el.onclick = () => { period = el.dataset.period; render(); });
  $('close').onclick = () => action('close');
  $('refresh').onclick = () => action('refresh');
  $('preferences').onclick = showPreferences;
  $('preferences-cancel').onclick = cancelPreferences;
  $('exclude-crime').onchange = $('exclude-employment').onchange = updatePreferenceSummary;
  $('preferences-view').onsubmit = event => {
    event.preventDefault();
    if (savingPreferences) return;
    action('preferences', { preferences: { crime: $('exclude-crime').checked, employment: $('exclude-employment').checked } });
  };
  window.addEventListener('keydown', e => {
    if (app.hidden) return;
    if (e.key === 'Escape') { e.preventDefault(); if (editingPreferences) cancelPreferences(); else action('close'); }
    if (e.key === 'Tab') {
      const buttons = Array.from(app.querySelectorAll('button:not(:disabled), input:not(:disabled)')).filter(el => el.getClientRects().length > 0);
      const first = buttons[0], last = buttons[buttons.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
  // NUI can load before the client's callback is registered during a restart.
  // Keep announcing readiness until acknowledged so Lua can replay the open board.
  async function announceReady() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3000);
    try {
      const response = await fetch(`https://${GetParentResourceName()}/questReady`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
        signal: controller.signal
      });
      if (!response.ok) throw new Error('NUI not ready');
    } catch (_) {
      setTimeout(announceReady, 1000);
    } finally { clearTimeout(timeout); }
  }
  if (typeof GetParentResourceName === 'function') announceReady();
})();
