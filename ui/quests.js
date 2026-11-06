'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const app = $('quest-app');
  let board, period = 'daily', pending = false, busy = false;
  let activeAction, busyKind, savedFocus, session = 0;
  let editingPreferences = false, savingPreferences = false;
  let debugBoard = null, debugVisible = false, debugWaiting = false;
  const pendingHelp = '報酬の確認が必要です。管理者へお問い合わせください。';
  const loadingLabels = {
    debug: ['処理中…', '検証データを更新しています…'],
    debugView: ['読込中…', '全クエストの検証データを読み込んでいます…'],
    claim: ['受取中…', 'クエスト報酬を受け取っています…'],
    bonus: ['受取中…', '全クリア報酬を受け取っています…'],
    refresh: ['更新中…', 'クエストの進捗を更新しています…'],
    preferences: ['保存中…', '抽選設定を保存しています…'],
    reroll: ['確認中…', 'クエスト交換の確認画面を開いています…']
  };
  function focusKey(el) { return el.dataset.focusKey || el.id; }
  function readFocus() {
    const el = document.activeElement;
    if (!app.contains(el) || !focusKey(el)) return null;
    const heading = el.closest('.quest-card, #bonus, .debug-row')?.querySelector('h3');
    return { key: focusKey(el), fallback: heading ? focusKey(heading) : debugVisible ? 'debug-title' : editingPreferences ? 'preferences-title' : 'section-title' };
  }
  function restoreFocus() {
    if (!savedFocus || busy || pending || savingPreferences || debugWaiting || app.hidden) return;
    const snapshot = savedFocus;
    savedFocus = null;
    // A user may have moved to another tab or Close while the request was running.
    if (app.contains(document.activeElement) && document.activeElement.getClientRects().length && !document.activeElement.matches(':disabled')) return;
    const targets = Array.from(app.querySelectorAll('button, input, select, [tabindex]'));
    const find = key => targets.find(el => focusKey(el) === key && !el.matches(':disabled') && el.getClientRects().length);
    const target = find(snapshot.key) || find(snapshot.fallback) || $(debugVisible ? 'debug-title' : editingPreferences ? 'preferences-title' : 'section-title');
    target.focus({ preventScroll: true });
    const bounds = target.getBoundingClientRect(), viewport = app.querySelector('.workspace').getBoundingClientRect();
    if (bounds.top < viewport.top + 4 || bounds.bottom > viewport.bottom - 4) target.scrollIntoView({ block: 'nearest' });
  }
  function updateBusy() {
    const loading = busy || pending || savingPreferences || debugWaiting;
    const kind = savingPreferences ? 'preferences' : busy ? busyKind : pending || debugWaiting ? activeAction?.kind : null;
    const labels = loadingLabels[kind] || loadingLabels.refresh;
    // Keep the live status outside the busy content so it can be announced immediately.
    $('quest-cards').setAttribute('aria-busy', String(loading));
    $('bonus').setAttribute('aria-busy', String(loading));
    $('debug-rows').setAttribute('aria-busy', String(loading));
    $('debug-rows').querySelectorAll('input').forEach(el => {
      if (loading && el === document.activeElement) savedFocus = readFocus();
      el.disabled = loading;
    });
    $('gui-status').textContent = loading ? labels[1] : '';
    const sourceKey = kind === 'preferences' ? 'preferences-save' : kind === activeAction?.kind ? activeAction.key : kind === 'refresh' ? 'refresh' : null;
    if (loading && document.activeElement.matches('#preferences-fields input')) savedFocus = readFocus();
    $('preferences-fields').disabled = loading;
    $('preferences-fields').setAttribute('aria-busy', String(loading));
    $('preferences-save').dataset.label = board?.needsSetup ? 'この設定でクエストを始める' : '設定を保存';
    app.querySelectorAll('button:not(#close):not([data-period]):not([data-view])').forEach(el => {
      if (loading && el === document.activeElement) savedFocus = readFocus();
      el.disabled = loading;
      if (!el.dataset.label) el.dataset.label = el.textContent;
      el.textContent = loading && focusKey(el) === sourceKey ? labels[0] : el.dataset.label;
    });
    restoreFocus();
  }
  async function action(action, extra = {}, source) {
    const closing = action === 'close';
    if (!closing && (pending || busy || savingPreferences || debugWaiting)) return;
    const epoch = session;
    if (!closing) {
      activeAction = { kind: action, key: source ? focusKey(source) : action };
      pending = true;
      if (action === 'preferences') savingPreferences = true;
      if (action === 'debug' || action === 'debugView' && extra.visible) debugWaiting = true;
    }
    updateBusy();
    $('gui-error').textContent = '';
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      if (typeof GetParentResourceName !== 'function') { debugWaiting = false; return; }
      const response = await fetch(`https://${GetParentResourceName()}/questAction`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, period, ...extra }), signal: controller.signal
      });
      if (!response.ok) throw new Error('request');
    } catch (_) {
      if (epoch === session) {
        savingPreferences = debugWaiting = false;
        $('gui-error').textContent = '通信に失敗しました。少し待って再度お試しください。';
      }
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
    el.dataset.icon = ({ claim: 'claim', bonus: 'claim', reroll: 'refresh' })[kind] || '';
    el.dataset.focusKey = extra?.id ? `quest:${extra.id}:${kind}` : kind;
    el.onclick = () => action(kind, extra, el);
    return el;
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
    if (busy || pending || savingPreferences) return;
    if (debugVisible) return;
    editingPreferences = true;
    const prefs = board.preferences || { crime: true, employment: false };
    $('exclude-crime').checked = prefs.crime === true;
    $('exclude-employment').checked = prefs.employment === true;
    $('board-view').hidden = true;
    $('preferences-view').hidden = false;
    $('preferences').hidden = true;
    $('preferences-kicker').textContent = board.needsSetup ? 'はじめに · あなたに合ったクエストを' : '遊び方に合わせて';
    $('preferences-timing').textContent = board.needsSetup
      ? '保存すると、最初のデイリー・ウィークリークエストを抽選します。'
      : '次回の更新・リロールから適用します。現在のクエスト・進捗・リロール回数は変わりません。';
    $('preferences-cancel').dataset.label = board.needsSetup ? 'あとで設定する' : '保存せず戻る';
    $('gui-error').textContent = '';
    updatePreferenceSummary();
    updateBusy();
    $('exclude-crime').focus();
  }
  function showBoard() {
    editingPreferences = false;
    $('preferences-view').hidden = true;
    $('board-view').hidden = false;
    $('preferences').hidden = debugVisible || editingPreferences || board.needsSetup === true;
    $('gui-error').textContent = '';
    savedFocus = { key: 'preferences', fallback: 'section-title' };
    updateBusy();
    if (!busy && !pending && !savingPreferences && !board.needsSetup) $('preferences').focus();
  }
  function cancelPreferences() {
    if (busy || pending || savingPreferences) return;
    if (board.needsSetup) action('close');
    else showBoard();
  }
  function switchView(showDebug) {
    if (showDebug && board?.canDebug !== true) return;
    debugVisible = showDebug;
    editingPreferences = false;
    $('preferences-view').hidden = true;
    $('board-view').hidden = showDebug;
    $('debug-view').hidden = !showDebug;
    $('preferences').hidden = showDebug || board?.needsSetup === true;
    $('board-tab').setAttribute('aria-pressed', String(!showDebug));
    $('debug-tab').setAttribute('aria-pressed', String(showDebug));
    $('gui-error').textContent = '';
    if (showDebug) { renderDebug(); $('debug-title').focus(); }
    else if (board.needsSetup) showPreferences();
    else $('section-title').focus();
    action('debugView', { visible: showDebug }, $(showDebug ? 'debug-tab' : 'board-tab'));
  }
  function debugState(quest) { return quest.value >= quest.target ? 'done' : quest.value > 0 ? 'moved' : 'idle'; }
  function renderDebug() {
    const focus = readFocus() || savedFocus;
    const quests = Array.isArray(debugBoard?.quests) ? debugBoard.quests : [];
    const filter = $('debug-filter').value;
    const visibleQuests = quests.filter(q => filter === 'all' || debugState(q) === filter);
    const running = debugBoard?.enabled === true;
    $('debug-recording').textContent = running ? '計測中' : '計測停止中';
    $('debug-recording').classList.toggle('recording', running);
    $('debug-toggle').dataset.label = running ? '計測を停止' : '計測を開始';
    $('debug-summary').textContent = `${quests.length}件中 ${quests.filter(q => q.value > 0).length}件で進捗を検出 / ${quests.filter(q => q.value >= q.target).length}件達成 / 表示 ${visibleQuests.length}件`;
    const rows = $('debug-rows'); rows.replaceChildren();
    const metrics = { attendance: '街への参加', playtime: '接続時間', consume: '飲食アイテム使用', duty: '勤務時間', distance: '移動距離', activity: '仕事・活動の完了通知' };
    visibleQuests.forEach(q => {
      const row = node('article', 'debug-row'); row.dataset.id = q.id;
      const identity = node('div', 'debug-identity'), title = node('h3', '', q.title);
      title.tabIndex = -1; title.dataset.focusKey = `debug:${q.id}`;
      identity.append(node('span', 'debug-period-label', q.period === 'daily' ? 'デイリー' : 'ウィークリー'), title,
        node('p', 'debug-description', q.description), node('p', 'debug-source', `${q.id} / ${q.source || metrics[q.metric] || q.metric}`));
      if (q.available === false) identity.append(node('p', 'debug-unavailable', '連携元が未起動'));
      const state = debugState(q);
      const status = node('span', 'debug-state', { done: '達成', moved: '進捗あり', idle: '未検出' }[state]);
      status.dataset.state = state;
      const progress = node('div', 'debug-progress');
      progress.append(node('strong', '', `${q.value} / ${q.target} ${q.unit || ''}`),
        node('span', '', q.updatedAt ? new Date(q.updatedAt * 1000).toLocaleString('ja-JP') : '検出記録なし'));
      const pool = node('label', 'debug-pool'), input = document.createElement('input');
      input.type = 'checkbox'; input.checked = q.enabled !== false; input.setAttribute('role', 'switch');
      input.dataset.focusKey = `debug:${q.id}:pool`; input.setAttribute('aria-label', `${q.title}を抽選に含める`);
      input.onchange = () => { const enabled = input.checked; input.checked = q.enabled !== false; action('debug', { operation: 'pool', id: q.id, enabled }, input); };
      pool.append(input, node('span', '', q.enabled === false ? 'OFF' : 'ON'));
      const reset = button('リセット', 'debug', { operation: 'reset', id: q.id }, 'secondary-button');
      reset.dataset.focusKey = `debug:${q.id}:reset`; reset.setAttribute('aria-label', `${q.title}の検証用進捗をリセット`);
      row.append(identity, status, progress, pool, reset); rows.append(row);
    });
    if (!visibleQuests.length) rows.append(node('p', 'empty-state', quests.length ? 'この検証状態のクエストはありません。' : '「一覧を更新」で検証データを取得できます。'));
    savedFocus = focus; updateBusy();
  }
  function render() {
    if (!board) return;
    const focus = readFocus() || savedFocus;
    const daily = period === 'daily';
    app.dataset.canDebug = String(board.canDebug === true);
    $('debug-nav').hidden = board.canDebug !== true;
    $('rail-mark').hidden = board.canDebug === true;
    if (board.canDebug !== true) { debugVisible = false; debugBoard = null; $('debug-view').hidden = true; $('board-view').hidden = editingPreferences; }
    app.dataset.activePeriod = period;
    const quests = (Array.isArray(board.quests) ? board.quests : []).filter(q => q.period === period);
    const completed = quests.filter(q => q.value >= q.target).length;
    document.querySelectorAll('[data-period]').forEach(el => {
      el.setAttribute('aria-pressed', String(el.dataset.period === period));
    });
    $('section-title').textContent = board.needsSetup ? 'あなたに合った挑戦を。' : daily ? '今日のチャレンジ' : '今週のチャレンジ';
    $('completion').textContent = `${completed} / ${quests.length}件 達成`;
    $('completion').hidden = board.needsSetup === true;
    $('preferences').hidden = debugVisible || editingPreferences || board.needsSetup === true;
    $('refresh').hidden = board.needsSetup === true;
    $('board-note').textContent = board.needsSetup ? '抽選設定から、犯罪・職業条件の除外を選んでスタートしましょう。' : board.drawError ? '抽選候補が不足しています。抽選設定や連携元の状態を確認してください。' : `リロール残り ${(board.rerolls || {})[period] || 0}回 · 未達成のクエストを1件交換できます。`;
    const cards = $('quest-cards'); cards.replaceChildren();
    cards.dataset.count = String(quests.length);
    quests.forEach(q => {
      const done = q.value >= q.target, claimable = done && q.status === 'active';
      const state = q.status === 'claimed' ? '受取済み' : q.status === 'pending' ? '確認待ち' : claimable ? '達成！' : q.available === false ? '連携元が未起動' : '進行中';
      const card = node('article', 'quest-card' + (done ? ' completed' : '') + (q.status === 'pending' ? ' awaiting-review' : ''));
      const category = q.tags?.crime ? 'crime' : q.tags?.employment ? 'employment' : 'general';
      card.dataset.category = category;
      card.classList.toggle('claimed', q.status === 'claimed');
      const heading = node('h3', '', q.title);
      heading.tabIndex = -1; heading.dataset.focusKey = `quest:${q.id}`;
      const top = node('div', 'card-top');
      const emblem = node('span', 'quest-emblem');
      emblem.setAttribute('aria-hidden', 'true');
      const identity = node('div', 'card-identity');
      identity.append(emblem, node('p', 'category', { crime: '犯罪', employment: '職業・所属必須', general: '一般' }[category]));
      top.append(identity, node('span', 'status', state));
      card.append(top, heading, node('p', 'description', q.description));
      const factor = 10 ** (q.precision || 0), scale = q.scale || 1;
      card.append(node('p', 'progress-copy', `${Math.floor(q.value / scale * factor) / factor} / ${q.target / scale} ${q.unit || ''}`));
      const track = node('div', 'progress-track');
      track.setAttribute('role', 'progressbar'); track.setAttribute('aria-label', q.title);
      track.setAttribute('aria-valuemin', '0'); track.setAttribute('aria-valuemax', String(q.target)); track.setAttribute('aria-valuenow', String(Math.min(q.value, q.target)));
      track.setAttribute('aria-valuetext', `${Math.floor(q.value / scale * factor) / factor} / ${q.target / scale} ${q.unit || ''}`);
      const fill = node('div'); fill.style.width = `${Math.max(0, Math.min(100, q.value / q.target * 100))}%`; track.append(fill);
      const bottom = node('div', 'card-bottom');
      const reward = node('div', 'reward-copy');
      reward.append(node('span', 'reward-label', 'クリア報酬'), node('div', 'reward', q.reward));
      bottom.append(reward);
      if (claimable) bottom.append(button('報酬を受け取る', 'claim', { id: q.id }));
      else if (q.canReroll) bottom.append(button('交換', 'reroll', { id: q.id }, 'secondary-button'));
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
        start.id = 'start-setup'; start.dataset.focusKey = 'start-setup'; start.onclick = showPreferences;
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
      const emblem = node('span', 'bonus-emblem');
      emblem.setAttribute('aria-hidden', 'true');
      bonus.append(emblem, copy, b.canClaim ? button('ボーナスを受け取る', 'bonus') : node('span', 'bonus-state', b.status === 'claimed' ? '✓ 受取済み' : b.status === 'pending' ? '確認待ち' : '全クリアで解放'));
    }
    bonus.hidden = !bonus.childElementCount;
    $('reset-copy').hidden = board.needsSetup === true;
    $('reset-copy').textContent = `次回更新 ${daily ? board.dailyReset || '—' : board.weeklyReset || '—'} · ${daily ? '達成済みの未受取報酬は更新時に自動受取' : '報酬は期限内に受け取ってください'}`;
    savedFocus = focus;
    updateBusy();
  }
  window.addEventListener('message', ({ data }) => {
    if (!data) return;
    if (data.action === 'suimag-dailyquest:debugResult') {
      if (app.hidden) return;
      debugWaiting = false;
      if (data.ok) {
        debugBoard = data.data;
        const messages = { start: '計測を開始しました。実際の行動で全クエストを検証できます。', stop: '計測を停止しました。結果は保存されています。', reset: '検証用進捗をリセットしました。', pool: '抽選対象を保存しました。次回抽選・リロールから反映されます。' };
        if (messages[data.operation]) $('debug-feedback').textContent = messages[data.operation];
        renderDebug();
      } else {
        if (data.forbidden) {
          board.canDebug = false; debugBoard = null; debugVisible = false;
          $('debug-view').hidden = true; $('board-view').hidden = false; render();
          $('section-title').focus();
        }
        $('gui-error').textContent = data.message || '検証データを取得できませんでした。「一覧を更新」で再試行してください。';
        updateBusy();
      }
      return;
    }
    if (data.action === 'suimag-dailyquest:busy') {
      if (app.hidden) return;
      busy = data.busy === true;
      busyKind = ({ list: 'refresh', claimBonus: 'bonus', claim: 'claim', preferences: 'preferences', reroll: 'reroll', debug: 'debug' })[data.operation] || 'refresh';
      updateBusy(); return;
    }
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
    if (app.hidden) {
      session++; pending = savingPreferences = editingPreferences = debugWaiting = debugVisible = false; debugBoard = null; activeAction = busyKind = savedFocus = null;
      updateBusy(); return;
    }
    if (!app.hidden && data.data) {
      board = data.data; if (data.selected === 'weekly' || data.selected === 'daily') period = data.selected;
      render();
      if (wasHidden) {
        $('debug-view').hidden = true;
        $('debug-feedback').textContent = '';
        $('board-tab').setAttribute('aria-pressed', 'true'); $('debug-tab').setAttribute('aria-pressed', 'false');
        showBoard();
        if (board.needsSetup) showPreferences();
        else $('close').focus();
      }
    }
  });
  app.addEventListener('focusin', () => { savedFocus = null; });
  document.querySelectorAll('[data-period]').forEach(el => {
    el.dataset.focusKey = `period:${el.dataset.period}`;
    el.onclick = () => { period = el.dataset.period; render(); };
  });
  $('board-tab').onclick = () => { if (!busy && !pending && !savingPreferences && !debugWaiting) switchView(false); };
  $('debug-tab').onclick = () => { if (!busy && !pending && !savingPreferences && !debugWaiting) switchView(true); };
  $('debug-filter').onchange = renderDebug;
  $('debug-toggle').onclick = () => action('debug', { operation: debugBoard?.enabled ? 'stop' : 'start' }, $('debug-toggle'));
  $('debug-refresh').onclick = () => action('debug', { operation: 'list' }, $('debug-refresh'));
  $('debug-reset-all').onclick = () => action('debug', { operation: 'reset' }, $('debug-reset-all'));
  $('close').onclick = () => action('close');
  $('refresh').onclick = () => action('refresh', {}, $('refresh'));
  $('preferences').onclick = showPreferences;
  $('preferences-cancel').onclick = cancelPreferences;
  $('exclude-crime').onchange = $('exclude-employment').onchange = updatePreferenceSummary;
  $('preferences-view').onsubmit = event => {
    event.preventDefault();
    if (savingPreferences) return;
    action('preferences', { preferences: { crime: $('exclude-crime').checked, employment: $('exclude-employment').checked } }, $('preferences-save'));
  };
  window.addEventListener('keydown', e => {
    if (app.hidden) return;
    if (e.key === 'Escape') { e.preventDefault(); if (editingPreferences) cancelPreferences(); else action('close'); }
    if (e.key === 'Tab') {
      const buttons = Array.from(app.querySelectorAll('button:not(:disabled), input:not(:disabled), select:not(:disabled)')).filter(el => el.getClientRects().length);
      const first = buttons[0], last = buttons[buttons.length - 1];
      const active = document.activeElement;
      const direction = e.shiftKey ? Node.DOCUMENT_POSITION_PRECEDING : Node.DOCUMENT_POSITION_FOLLOWING;
      const ordered = e.shiftKey ? buttons.slice().reverse() : buttons;
      const next = app.contains(active) && ordered.find(el => active.compareDocumentPosition(el) & direction);
      e.preventDefault();
      (next || (e.shiftKey ? last : first))?.focus();
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
