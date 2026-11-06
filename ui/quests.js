'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const app = $('quest-app');
  let board, period = 'daily', pending = false, busy = false;
  function updateBusy() {
    app.setAttribute('aria-busy', String(busy || pending));
    app.querySelectorAll('button:not(#close):not([data-period])').forEach(el => { el.disabled = busy || pending; });
  }
  async function action(action, extra = {}) {
    const closing = action === 'close';
    if (!closing && (pending || busy)) return;
    if (!closing) pending = true;
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
    } catch (_) { $('gui-error').textContent = '通信に失敗しました。少し待って再度お試しください。'; }
    finally { clearTimeout(timeout); if (!closing) pending = false; updateBusy(); }
  }
  function node(tag, className, text) {
    const el = document.createElement(tag); el.className = className || '';
    if (text !== undefined) el.textContent = text;
    return el;
  }
  function button(text, kind, extra, className = 'action-button') {
    const el = node('button', className, text); el.onclick = () => action(kind, extra); return el;
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
    const cards = $('quest-cards'); cards.replaceChildren();
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
      else if (q.canReroll) bottom.append(button('↻ 交換', 'reroll', { id: q.id }, 'text-button'));
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
    if (data.action !== 'suimag-dailyquest:gui') return;
    const wasHidden = app.hidden;
    app.hidden = data.visible !== true;
    document.body.classList.toggle('gui-visible', !app.hidden);
    busy = false;
    if (!app.hidden && data.data) {
      board = data.data; if (data.selected === 'weekly' || data.selected === 'daily') period = data.selected;
      render(); if (wasHidden) { $('gui-error').textContent = ''; $('close').focus(); }
    }
  });
  document.querySelectorAll('[data-period]').forEach(el => el.onclick = () => { period = el.dataset.period; render(); });
  $('close').onclick = () => action('close');
  $('refresh').onclick = () => action('refresh');
  $('preferences').onclick = () => action('preferences');
  window.addEventListener('keydown', e => {
    if (app.hidden) return;
    if (e.key === 'Escape') { e.preventDefault(); action('close'); }
    if (e.key === 'Tab') {
      const buttons = Array.from(app.querySelectorAll('button:not(:disabled)'));
      const first = buttons[0], last = buttons[buttons.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
  if (typeof GetParentResourceName === 'function') {
    fetch(`https://${GetParentResourceName()}/questReady`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
    }).catch(() => {});
  }
})();
