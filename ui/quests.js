'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const app = $('quest-app');
  let board, period = 'daily', pending = false, busy = false;
  let activeAction, busyKind, savedFocus, session = 0;
  const pendingHelp = '報酬の確認が必要です。管理者へお問い合わせください。';
  const loadingLabels = {
    claim: ['受取中…', 'クエスト報酬を受け取っています…'],
    bonus: ['受取中…', '全クリア報酬を受け取っています…'],
    refresh: ['更新中…', 'クエストの進捗を更新しています…'],
    preferences: ['設定を開いています…', '抽選設定を開いています…'],
    reroll: ['確認中…', 'クエスト交換の確認画面を開いています…']
  };
  function focusKey(el) { return el.dataset.focusKey || el.id; }
  function readFocus() {
    const el = document.activeElement;
    if (!app.contains(el) || !focusKey(el)) return null;
    const heading = el.closest('.quest-card, #bonus')?.querySelector('h3');
    return { key: focusKey(el), fallback: heading ? focusKey(heading) : 'section-title' };
  }
  function restoreFocus() {
    if (!savedFocus || busy || pending || app.hidden) return;
    const snapshot = savedFocus;
    savedFocus = null;
    // A user may have moved to another tab or Close while the request was running.
    if (app.contains(document.activeElement)) return;
    const targets = Array.from(app.querySelectorAll('button, [tabindex]'));
    const find = key => targets.find(el => focusKey(el) === key && !el.disabled && el.getClientRects().length);
    const target = find(snapshot.key) || find(snapshot.fallback) || $('section-title');
    target.focus({ preventScroll: true });
    const bounds = target.getBoundingClientRect(), viewport = app.querySelector('.workspace').getBoundingClientRect();
    if (bounds.top < viewport.top + 4 || bounds.bottom > viewport.bottom - 4) target.scrollIntoView({ block: 'nearest' });
  }
  function updateBusy() {
    const loading = busy || pending;
    const kind = busy ? busyKind : pending ? activeAction?.kind : null;
    const labels = loadingLabels[kind] || loadingLabels.refresh;
    // Keep the live status outside the busy content so it can be announced immediately.
    $('quest-cards').setAttribute('aria-busy', String(loading));
    $('bonus').setAttribute('aria-busy', String(loading));
    $('gui-status').textContent = loading ? labels[1] : '';
    const sourceKey = kind === activeAction?.kind ? activeAction.key : kind === 'refresh' ? 'refresh' : null;
    app.querySelectorAll('button:not(#close):not([data-period])').forEach(el => {
      if (loading && el === document.activeElement) savedFocus = readFocus();
      el.disabled = loading;
      if (!el.dataset.label) el.dataset.label = el.textContent;
      el.textContent = loading && focusKey(el) === sourceKey ? labels[0] : el.dataset.label;
    });
    restoreFocus();
  }
  async function action(action, extra = {}, source) {
    const closing = action === 'close';
    if (!closing && (pending || busy)) return;
    const epoch = session;
    if (!closing) {
      activeAction = { kind: action, key: source ? focusKey(source) : action };
      pending = true;
    }
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
      if (epoch === session) $('gui-error').textContent = '通信に失敗しました。少し待って再度お試しください。';
    } finally {
      clearTimeout(timeout);
      if (epoch === session) { if (!closing) pending = false; updateBusy(); }
    }
  }
  function node(tag, className, text) {
    const el = document.createElement(tag); el.className = className || '';
    if (text !== undefined) el.textContent = text;
    return el;
  }
  function button(text, kind, extra, className = 'action-button') {
    const el = node('button', className, text);
    el.dataset.focusKey = extra?.id ? `quest:${extra.id}:${kind}` : kind;
    el.onclick = () => action(kind, extra, el);
    return el;
  }
  function render() {
    if (!board) return;
    const focus = readFocus() || savedFocus;
    const daily = period === 'daily';
    const quests = (Array.isArray(board.quests) ? board.quests : []).filter(q => q.period === period);
    const completed = quests.filter(q => q.value >= q.target).length;
    document.querySelectorAll('[data-period]').forEach(el => {
      el.setAttribute('aria-pressed', String(el.dataset.period === period));
    });
    $('section-title').textContent = board.needsSetup ? 'あなたに合った挑戦を。' : daily ? '今日のチャレンジ' : '今週のチャレンジ';
    $('completion').textContent = `${completed} / ${quests.length}件 達成`;
    $('completion').hidden = board.needsSetup === true;
    $('preferences').hidden = board.needsSetup === true;
    $('refresh').hidden = board.needsSetup === true;
    $('board-note').textContent = board.needsSetup ? '抽選設定から、犯罪・職業条件の除外を選んでスタートしましょう。' : board.drawError ? '抽選候補が不足しています。抽選設定や連携元の状態を確認してください。' : `リロール残り ${(board.rerolls || {})[period] || 0}回 · 未達成のクエストを1件交換できます。`;
    const cards = $('quest-cards'); cards.replaceChildren();
    cards.classList.toggle('weekly', !daily);
    quests.forEach((q, index) => {
      const done = q.value >= q.target, claimable = done && q.status === 'active';
      const state = q.status === 'claimed' ? '受取済み' : q.status === 'pending' ? '確認待ち' : claimable ? '達成！' : q.available === false ? '連携元が未起動' : '進行中';
      const card = node('article', 'quest-card' + (done ? ' completed' : '') + (q.status === 'pending' ? ' awaiting-review' : ''));
      const heading = node('h3', '', q.title);
      heading.tabIndex = -1; heading.dataset.focusKey = `quest:${q.id}`;
      const top = node('div', 'card-top');
      top.append(node('span', 'quest-number', String(index + 1).padStart(2, '0')), node('span', 'status', state));
      card.append(top, node('p', 'category', q.tags && q.tags.crime ? '犯罪' : q.tags && q.tags.employment ? '職業・所属必須' : '一般'), heading, node('p', 'description', q.description));
      const factor = 10 ** (q.precision || 0), scale = q.scale || 1;
      card.append(node('p', 'progress-copy', `${Math.floor(q.value / scale * factor) / factor} / ${q.target / scale} ${q.unit || ''}`));
      const track = node('div', 'progress-track');
      track.setAttribute('role', 'progressbar'); track.setAttribute('aria-label', q.title);
      track.setAttribute('aria-valuemin', '0'); track.setAttribute('aria-valuemax', String(q.target)); track.setAttribute('aria-valuenow', String(Math.min(q.value, q.target)));
      track.setAttribute('aria-valuetext', `${Math.floor(q.value / scale * factor) / factor} / ${q.target / scale} ${q.unit || ''}`);
      const fill = node('div'); fill.style.width = `${Math.max(0, Math.min(100, q.value / q.target * 100))}%`; track.append(fill);
      const bottom = node('div', 'card-bottom'); bottom.append(node('div', 'reward', q.reward));
      if (claimable) bottom.append(button('報酬を受け取る ↗', 'claim', { id: q.id }));
      else if (q.canReroll) bottom.append(button('↻ 交換', 'reroll', { id: q.id }, 'text-button'));
      else if (q.status !== 'pending') bottom.append(node('span', 'muted', q.status === 'claimed' ? '✓' : state));
      card.append(track, bottom);
      if (q.status === 'pending') card.append(node('p', 'pending-help', pendingHelp));
      cards.append(card);
    });
    if (!quests.length) {
      const empty = node('div', 'empty-state');
      empty.append(node('p', '', board.needsSetup ? 'さあ、最初のクエストを見つけよう。' : '現在のクエストはありません。'));
      if (board.needsSetup) {
        const start = button('抽選設定をして始める', 'preferences');
        start.id = 'start-setup'; start.dataset.focusKey = 'start-setup';
        empty.append(start);
      }
      cards.append(empty);
    }
    const bonus = $('bonus'); bonus.replaceChildren();
    bonus.classList.remove('awaiting-review');
    if (daily && board.dailyBonus && !board.needsSetup) {
      const b = board.dailyBonus;
      const copy = node('div', 'bonus-copy'), heading = node('h3', '', `全クリア報酬 · ${b.completed} / ${b.total}件 達成`);
      heading.tabIndex = -1; heading.dataset.focusKey = 'bonus-heading';
      copy.append(heading, node('p', 'bonus-reward', `追加 ${b.reward}`));
      if (b.status === 'pending') {
        bonus.classList.add('awaiting-review');
        copy.append(node('p', 'pending-help', pendingHelp));
      }
      bonus.append(copy, b.canClaim ? button('ボーナスを受け取る ↗', 'bonus') : node('span', 'bonus-state', b.status === 'claimed' ? '✓ 受取済み' : b.status === 'pending' ? '確認待ち' : '全クリアで解放'));
    }
    bonus.hidden = !bonus.childElementCount;
    $('reset-copy').hidden = board.needsSetup === true;
    $('reset-copy').textContent = `次回更新 ${daily ? board.dailyReset || '—' : board.weeklyReset || '—'} · ${daily ? '達成済みの未受取報酬は更新時に自動受取' : '報酬は期限内に受け取ってください'}`;
    savedFocus = focus;
    updateBusy();
  }
  window.addEventListener('message', ({ data }) => {
    if (!data) return;
    if (data.action === 'suimag-dailyquest:busy') {
      if (app.hidden) return;
      busy = data.busy === true;
      busyKind = ({ list: 'refresh', claimBonus: 'bonus', claim: 'claim', preferences: 'preferences', reroll: 'reroll' })[data.operation] || 'refresh';
      updateBusy(); return;
    }
    if (data.action !== 'suimag-dailyquest:gui') return;
    const wasHidden = app.hidden;
    app.hidden = data.visible !== true;
    busy = false;
    if (app.hidden) {
      session++; pending = false; activeAction = busyKind = savedFocus = null;
      updateBusy(); return;
    }
    if (!app.hidden && data.data) {
      board = data.data; if (data.selected === 'weekly' || data.selected === 'daily') period = data.selected;
      render(); if (wasHidden) { $('gui-error').textContent = ''; ($('start-setup') || $('close')).focus(); }
    }
  });
  app.addEventListener('focusin', () => { savedFocus = null; });
  document.querySelectorAll('[data-period]').forEach(el => {
    el.dataset.focusKey = `period:${el.dataset.period}`;
    el.onclick = () => { period = el.dataset.period; render(); };
  });
  $('close').onclick = () => action('close');
  $('refresh').onclick = () => action('refresh', {}, $('refresh'));
  $('preferences').onclick = () => action('preferences', {}, $('preferences'));
  window.addEventListener('keydown', e => {
    if (app.hidden) return;
    if (e.key === 'Escape') { e.preventDefault(); action('close'); }
    if (e.key === 'Tab') {
      const buttons = Array.from(app.querySelectorAll('button:not(:disabled)')).filter(el => el.getClientRects().length);
      const first = buttons[0], last = buttons[buttons.length - 1];
      const active = document.activeElement;
      const direction = e.shiftKey ? Node.DOCUMENT_POSITION_PRECEDING : Node.DOCUMENT_POSITION_FOLLOWING;
      const ordered = e.shiftKey ? buttons.slice().reverse() : buttons;
      const next = app.contains(active) && ordered.find(el => active.compareDocumentPosition(el) & direction);
      e.preventDefault();
      (next || (e.shiftKey ? last : first))?.focus();
    }
  });
  if (typeof GetParentResourceName === 'function') {
    fetch(`https://${GetParentResourceName()}/questReady`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
    }).catch(() => {});
  }
})();
