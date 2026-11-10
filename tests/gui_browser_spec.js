'use strict';
// Optional integration check: requires Playwright and Chromium, no game server.
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../ui');
const server = http.createServer((req, res) => {
  if (req.url === '/transparency-host') {
    // A contrasting parent exposes opaque NUI canvases that a normal page screenshot misses.
    res.setHeader('Content-Type', 'text/html');
    res.end('<!doctype html><html style="background:rgb(79,166,135)"><body style="margin:0"><iframe name="nui" title="Quest NUI" src="/countdown.html" style="display:block;width:100vw;height:100vh;border:0"></iframe></body></html>');
    return;
  }
  const name = path.basename(req.url.split('?')[0]);
  const filename = path.join(root, name);
  if (!fs.existsSync(filename) || !fs.statSync(filename).isFile()) { res.writeHead(404);res.end();return; }
  res.setHeader('Content-Type', name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html');
  res.end(fs.readFileSync(filename));
});
const board = {
  preferences:{crime:true,employment:false},
  rerolls:{daily:1,weekly:1},dailyReset:'tomorrow',weeklyReset:'monday',
  quests:[
    {id:'visit',period:'daily',title:'今日の街歩き',value:1,target:1,reward:'銀行 $150000 + 黒コイン × 1'},
    {id:'time',period:'daily',title:'街で過ごす30分',value:18,target:30,canReroll:true},
    {id:'food',period:'daily',title:'食事を忘れずに',value:1,target:3,canReroll:true},
    {id:'week',period:'weekly',title:'今週の常連',value:2,target:3,reward:'銀行 $500000 + 白コイン × 3'},
    {id:'pending',period:'weekly',title:'街と過ごす一週間',value:3,target:3,status:'pending'}
  ].map(q=>({status:'active',scale:1,unit:'回',description:'クエストの説明',reward:'銀行 $150,000',...q})),
  dailyBonus:{completed:1,total:3,status:'active',canClaim:false,reward:'銀行 $200,000'}
};
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH || '/usr/bin/chromium',args:['--no-sandbox']});
    // Real embedding matters: a root dark color scheme paints an opaque canvas even
    // when computed html/body backgrounds are transparent. A standalone screenshot
    // using omitBackground also misses this embedding-specific problem.
    const embedded = await browser.newPage({viewport:{width:1280,height:720}});
    const hostUrl = 'http://127.0.0.1:' + server.address().port + '/transparency-host';
    const assertBackdrop = async label => {
      const png = await embedded.screenshot({animations:'disabled',clip:{x:640,y:650,width:1,height:1}});
      const rgba = await embedded.evaluate(base64 => new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => {
          const canvas = document.createElement('canvas');
          canvas.width = canvas.height = 1;
          const context = canvas.getContext('2d');
          context.drawImage(image,0,0);
          resolve(Array.from(context.getImageData(0,0,1,1).data));
        };
        image.onerror = () => reject(new Error('Could not decode transparency sample'));
        image.src = 'data:image/png;base64,' + base64;
      }), png.toString('base64'));
      assert.deepEqual(rgba,[79,166,135,255],label);
    };
    for (const colorScheme of ['light','dark']) {
      await embedded.emulateMedia({colorScheme});
      await embedded.goto(hostUrl);
      let nui = embedded.frame({name:'nui'});
      await nui.locator('#quest-app').waitFor({state:'hidden'});
      await assertBackdrop(colorScheme + ': startup must expose the game backdrop');
      await nui.evaluate(() => window.postMessage({action:'suimag-dailyquest:countdown',visible:true,remaining:120,resetLabel:'tomorrow'},'*'));
      await nui.locator('#daily-countdown').waitFor({state:'visible'});
      await assertBackdrop(colorScheme + ': countdown must not paint the full screen');
      await nui.evaluate(data => window.postMessage({action:'suimag-dailyquest:gui',visible:true,data},'*'),board);
      await nui.locator('#quest-app').waitFor({state:'visible'});
      await nui.evaluate(() => window.postMessage({action:'suimag-dailyquest:gui',visible:false},'*'));
      await nui.locator('#quest-app').waitFor({state:'hidden'});
      await assertBackdrop(colorScheme + ': closing the board must expose the game backdrop');
      await embedded.reload();
      nui = embedded.frame({name:'nui'});
      await nui.locator('#quest-app').waitFor({state:'hidden'});
      await assertBackdrop(colorScheme + ': reloading NUI must expose the game backdrop');
    }
    await embedded.close();
    const page = await browser.newPage({viewport:{width:1440,height:960}});
    const errors = [];page.on('pageerror', e => errors.push(e.message));
    await page.addInitScript(() => {
      window.nuiCalls = [];
      window.GetParentResourceName = () => 'suimag-test';
      window.fetch = async (url, options) => {
        const data = JSON.parse(options.body);
        window.nuiCalls.push({url,data});
        if (data.action === 'close') window.postMessage({action:'suimag-dailyquest:gui',visible:false},'*');
        return {ok:true};
      };
    });
    const send = async data => page.evaluate(data => new Promise(resolve => {
      const delivered = event => {
        if (event.data.action !== data.action) return;
        window.removeEventListener('message', delivered); resolve();
      };
      window.addEventListener('message', delivered);
      window.postMessage(data,'*');
    }), data);
    const show = async (data=board,selected='daily') => {
      await send({action:'suimag-dailyquest:gui',visible:true,data,selected});
      await page.locator('#quest-app').waitFor({state:'visible'});
    };
    await page.goto(`http://127.0.0.1:${server.address().port}/countdown.html`);
    assert.equal(await page.locator('#quest-app').isVisible(),false);
    assert.deepEqual(await page.evaluate(()=>nuiCalls),[{url:'https://suimag-test/questReady',data:{}}]);
    await show();
    assert.equal(await page.locator('.quest-card').count(), 3);
    assert.match(await page.locator('#completion').textContent(), /1 \/ 3/);
    assert.equal(await page.locator('.rail-caption').textContent(),'FLECITY');
    assert.equal(await page.locator('#preferences').textContent(),'クエスト抽選設定');
    assert.equal(await page.locator('.reward').first().textContent(),'銀行 $150000 + 黒コイン × 1');
    // Settings are an actual view. Edits stay local until saved and survive refresh/errors.
    const preferenceCallsBefore = await page.evaluate(() => nuiCalls.length);
    await page.locator('#preferences').click();
    await page.locator('#preferences-view').waitFor({state:'visible'});
    assert.equal(await page.locator('#board-view').isVisible(),false);
    assert.equal(await page.locator('#exclude-crime').isChecked(),true);
    assert.equal(await page.locator('#exclude-employment').isChecked(),false);
    await page.locator('#exclude-crime').uncheck();
    await page.locator('#exclude-employment').check();
    assert.equal(await page.locator('#preferences-summary').textContent(),'一般 ／ 犯罪');
    await show(board,null);
    assert.equal(await page.locator('#exclude-crime').isChecked(),false,'auto refresh preserves draft');
    assert.equal(await page.evaluate(() => nuiCalls.length),preferenceCallsBefore,'editing sends no server request');
    await page.locator('#preferences-cancel').click();
    await page.locator('#preferences').click();
    assert.equal(await page.locator('#exclude-crime').isChecked(),true,'cancel discards unsaved edits');
    await page.locator('#exclude-crime').uncheck();
    await page.locator('#exclude-employment').check();
    await page.locator('#preferences-save').click();
    assert.deepEqual(await page.evaluate(()=>nuiCalls.at(-1).data),{action:'preferences',period:'daily',preferences:{crime:false,employment:true}});
    assert.equal(await page.locator('#preferences-save').isDisabled(),true);
    assert.equal(await page.locator('#exclude-crime').isDisabled(),true);
    await page.evaluate(() => window.postMessage({action:'suimag-dailyquest:preferencesResult',ok:false,message:'設定を保存できませんでした。'},'*'));
    await page.getByText('設定を保存できませんでした。',{exact:true}).waitFor();
    assert.equal(await page.locator('#preferences-view').isVisible(),true);
    assert.equal(await page.locator('#exclude-crime').isChecked(),false);
    await page.locator('#preferences-save').click();
    await page.evaluate(() => window.postMessage({action:'suimag-dailyquest:preferencesResult',ok:true,preferences:{crime:false,employment:true}},'*'));
    await page.locator('#board-view').waitFor({state:'visible'});
    await page.locator('#preferences').click();
    assert.equal(await page.locator('#exclude-employment').isChecked(),true,'saved settings remain current even before list refresh');
    await page.keyboard.press('Escape');
    await page.locator('#board-view').waitFor({state:'visible'});
    await page.getByRole('button',{name:'報酬を受け取る'}).click();
    assert.deepEqual(await page.evaluate(()=>nuiCalls.at(-1).data),{action:'claim',period:'daily',id:'visit'});
    board.quests[0].status='claimed';await show();
    await page.locator('.quest-card').first().getByText('受取済み',{exact:true}).waitFor();
    await page.locator('[data-period="weekly"]').click();
    assert.equal(await page.locator('.quest-card').count(), 2);
    assert.equal(await page.locator('#bonus').isVisible(), false);
    assert.match(await page.locator('#reset-copy').textContent(), /期限内/);
    assert.equal(await page.locator('.reward').first().textContent(),'銀行 $500000 + 白コイン × 3');
    assert.equal(await page.getByText('確認待ち',{exact:true}).count(), 1);
    assert.match(await page.locator('.pending-help').textContent(), /管理者へお問い合わせ/);
    await show(board,null);assert.equal(await page.locator('.quest-card').count(),2,'auto refresh preserves the tab');
    await page.evaluate(() => window.postMessage({action:'suimag-dailyquest:busy',busy:true},'*'));
    await page.locator('#refresh:disabled').waitFor();
    assert.equal(await page.locator('#close').isEnabled(), true);
    await page.keyboard.press('Escape');
    await page.locator('#quest-app').waitFor({state:'hidden'});
    // Server-configurable titles must remain text; fractional progress must stay readable.
    await show({quests:[{id:'html',period:'daily',title:'<img src=x onerror=alert(1)>',description:'<script>bad()</script>',value:567,target:1000,scale:1000,precision:1,unit:'km',status:'active',available:false,reward:'銀行 $150,000'}]});
    await page.getByText('0.5 / 1 km',{exact:true}).waitFor();
    assert.equal(await page.locator('.quest-card img, .quest-card script').count(),0);
    assert.equal(await page.getByText('連携元が未起動',{exact:true}).count(),2);
    // Lua can serialize an empty table as an object.
    await page.locator('#close').click();
    await page.locator('#quest-app').waitFor({state:'hidden'});
    await show({needsSetup:true,quests:{}});
    await page.locator('#preferences-view').waitFor({state:'visible'});
    assert.equal(await page.locator('#exclude-crime').isChecked(),true);
    assert.match(await page.locator('#preferences-save').textContent(),/この設定でクエストを始める/);
    await page.locator('#preferences-cancel').click();
    await page.locator('#quest-app').waitFor({state:'hidden'});
    await show();
    await page.evaluate(() => { window.fetch = async () => { throw new Error('offline'); }; });
    await page.locator('#refresh').click();
    await page.getByText('通信に失敗しました。少し待って再度お試しください。').waitFor();
    assert.equal(await page.locator('#refresh').isEnabled(),true);
    assert.equal(await page.locator('#refresh').evaluate(el=>el===document.activeElement),true,'failed request retains keyboard focus');

    // Keep a meaningful focus target when a refreshed card loses its claim action.
    board.quests[0].status='active';await show();
    await page.locator('.quest-card').first().getByRole('button').focus();
    await show();
    await page.waitForFunction(()=>document.activeElement.dataset.focusKey==='quest:visit:claim');
    board.quests[0].status='claimed';await show();
    await page.waitForFunction(()=>document.activeElement.dataset.focusKey==='quest:visit');
    assert.equal(await page.evaluate(()=>document.activeElement.tagName),'H3');
    const allClaimed={...board,quests:board.quests.map(q=>({...q,status:'claimed',value:q.target,canReroll:false}))};
    await show(allClaimed);
    await page.locator('.quest-card h3').last().focus();
    await page.keyboard.press('Tab');
    assert.equal(await page.locator('#preferences').evaluate(el=>el===document.activeElement),true,'Tab wraps from a completed card heading');

    // NUI transport acknowledgement and Lua/server work have independent lifetimes.
    await page.evaluate(() => {
      window.fetch = (url,options) => {
        const data=JSON.parse(options.body);nuiCalls.push({url,data});
        return new Promise(resolve=>{window.finishRequest=()=>resolve({ok:true});});
      };
    });
    board.quests[0].status='active';await show();
    await page.locator('.quest-card').first().getByRole('button').click();
    await page.getByRole('button',{name:'受取中…',exact:true}).waitFor();
    assert.match(await page.locator('#gui-status').textContent(),/クエスト報酬を受け取っています/);
    await send({action:'suimag-dailyquest:busy',busy:true,operation:'claim'});
    await page.evaluate(()=>finishRequest());
    assert.equal(await page.locator('#refresh').isEnabled(),false,'transport ACK does not end server work');
    const callsBefore=await page.evaluate(()=>nuiCalls.length);
    await page.evaluate(()=>document.querySelector('.quest-card button').click());
    assert.equal(await page.evaluate(()=>nuiCalls.length),callsBefore,'loading blocks repeat claims');
    await page.locator('[data-period="weekly"]').click();
    await send({action:'suimag-dailyquest:busy',busy:false});
    await show(board,null);
    assert.equal(await page.locator('[data-period="weekly"]').evaluate(el=>el===document.activeElement),true,'completion does not steal focus after tab change');
    assert.equal(await page.locator('#gui-status').textContent(),'');
    await send({action:'suimag-dailyquest:busy',busy:true,operation:'list'});
    await page.getByRole('button',{name:'更新中…',exact:true}).waitFor();
    assert.match(await page.locator('#gui-status').textContent(),/進捗を更新/);
    await send({action:'suimag-dailyquest:busy',busy:false});

    // A completed bonus keeps focus on its own heading; pending guidance persists on reopen.
    const bonusBoard={...board,dailyBonus:{...board.dailyBonus,completed:3,canClaim:true}};
    await show(bonusBoard);
    await page.locator('#bonus button').focus();
    bonusBoard.dailyBonus={...bonusBoard.dailyBonus,canClaim:false,status:'pending'};
    await show(bonusBoard);
    await page.waitForFunction(()=>document.activeElement.dataset.focusKey==='bonus-heading');
    assert.match(await page.locator('#bonus .pending-help').textContent(),/管理者へお問い合わせ/);

    // Delayed transport completions from a closed screen must not affect a new operation.
    await show();
    await page.locator('#refresh').click();
    await page.evaluate(()=>{window.finishOldRequest=finishRequest;window.postMessage({action:'suimag-dailyquest:gui',visible:false},'*');});
    await page.locator('#quest-app').waitFor({state:'hidden'});
    await show();
    await page.locator('#refresh').click();
    await page.evaluate(()=>finishOldRequest());
    assert.equal(await page.locator('#refresh').isEnabled(),false);
    await page.evaluate(()=>finishRequest());
    await page.locator('#refresh:enabled').waitFor();

    await show();
    for (const size of [{width:1920,height:1080},{width:1280,height:720},{width:1024,height:768},{width:390,height:844},{width:375,height:667}]) {
      await page.setViewportSize(size);
      const fits = await page.evaluate(() => {
        const workspace = document.querySelector('.workspace');
        return workspace.scrollWidth <= workspace.clientWidth;
      });
      assert.equal(fits,true,`${size.width}px horizontal overflow`);
      if (size.width===1280) {
        const overviewVisible=await page.evaluate(()=>{
          const viewport=document.querySelector('.workspace').getBoundingClientRect();
          return ['#bonus','#reset-copy'].every(selector=>{
            const r=document.querySelector(selector).getBoundingClientRect();
            return r.top>=viewport.top && r.bottom<=viewport.bottom;
          });
        });
        assert.equal(overviewVisible,true,'bonus and deadline are visible without scrolling at 720p');
      }
    }
    await page.evaluate(()=>window.postMessage({action:'suimag-dailyquest:gui',visible:false},'*'));
    await page.locator('#quest-app').waitFor({state:'hidden'});
    await show({needsSetup:true,quests:{}});
    assert.equal(await page.locator('#exclude-crime').evaluate(el=>el===document.activeElement),true,'first-time opening focuses the first preference');
    assert.equal(await page.locator('#completion').isVisible(),false);
    await page.keyboard.press('Shift+Tab');
    assert.equal(await page.locator('#close').evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Shift+Tab');
    assert.equal(await page.locator('#preferences-save').evaluate(el=>el===document.activeElement),true,'focus wraps across the native settings form');
    await page.keyboard.press('Tab');
    assert.equal(await page.locator('#close').evaluate(el=>el===document.activeElement),true);
    // The admin-only view lists the full catalog and sends explicit reset/pool operations.
    await page.evaluate(() => { window.fetch = async (url,options) => { nuiCalls.push({url,data:JSON.parse(options.body)}); return {ok:true}; }; });
    await show();
    assert.equal(await page.locator('#debug-tab').isVisible(),false,'normal users have no debug tab');
    const adminBoard={...board,canDebug:true};
    const debugBoard={enabled:true,quests:Array.from({length:48},(_,i)=>({
      id:'debug-'+i,period:i<24?'daily':'weekly',title:'検証クエスト '+i,description:'実際の行動で進捗を確認する。',
      metric:'consume',target:3,value:i%3===0?0:i%3===1?1:3,unit:'回',enabled:i!==1,available:i!==2,
      preparation:{label:'道具を準備',help:'手動で操作して結果を確認します。',available:i!==2,reason:i===2?'連携元が未起動':null}
    }))};
    await show(adminBoard);
    await page.locator('#debug-tab').click();
    assert.equal(await page.locator('#debug-view').isVisible(),true);
    assert.equal(await page.locator('#board-view').isVisible(),false);
    assert.equal(await page.locator('#debug-refresh').isEnabled(),false,'wait for the server beyond the NUI acknowledgement');
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:debugBoard});
    assert.equal(await page.locator('.debug-row').count(),48);
    assert.equal(await page.locator('.debug-state').nth(0).textContent(),'未検出');
    assert.equal(await page.locator('.debug-state').nth(1).textContent(),'進捗あり');
    assert.equal(await page.locator('.debug-state').nth(2).textContent(),'達成');
    await page.locator('#debug-reset-all').focus();
    await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(()=>document.activeElement.id),'debug-filter','filter is keyboard reachable');
    for (const [state,label,count] of [['idle','未検出',16],['moved','進捗あり',16],['done','達成',16]]) {
      await page.locator('#debug-filter').selectOption(state);
      assert.equal(await page.locator('.debug-row').count(),count);
      assert.deepEqual([...new Set(await page.locator('.debug-state').allTextContents())],[label]);
    }
    await page.locator('#debug-filter').selectOption('all');
    assert.equal(await page.locator('.debug-row').count(),48);
    await page.locator('.debug-row').first().getByRole('switch').click();
    assert.deepEqual(await page.evaluate(()=>nuiCalls.at(-1).data),{action:'debug',period:'daily',operation:'pool',id:'debug-0',enabled:false});
    debugBoard.quests[0].enabled=false;
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:debugBoard,operation:'pool'});
    assert.equal(await page.locator('.debug-row').first().getByRole('switch').isChecked(),false);
    await page.locator('#debug-filter').selectOption('moved');
    await page.locator('.debug-row[data-id="debug-1"]').getByRole('button',{name:/検証用進捗をリセット/}).click();
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.operation),'reset');
    debugBoard.quests[1].value=0;
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:debugBoard,operation:'reset'});
    assert.equal(await page.locator('#debug-filter').inputValue(),'moved','refresh keeps the filter');
    assert.equal(await page.locator('.debug-row[data-id="debug-1"]').count(),0,'reset row leaves the progress filter');
    assert.match(await page.locator('#debug-summary').textContent(),/表示 15件/);
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:{...debugBoard,quests:debugBoard.quests.map(q=>({...q,value:0}))}});
    assert.equal(await page.locator('.debug-row').count(),0);
    assert.match(await page.locator('#debug-rows .empty-state').textContent(),/この検証状態/);
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:debugBoard});
    await page.locator('#debug-filter').selectOption('all');
    await page.locator('#debug-reset-all').click();
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.id),undefined,'all-reset has no quest ID');
    await send({action:'suimag-dailyquest:debugResult',ok:false,message:'保存に失敗しました'});
    assert.match(await page.locator('#gui-error').textContent(),/保存に失敗/);
    assert.equal(await page.locator('#debug-reset-all').isEnabled(),true);
    const prepare = page.locator('.debug-row[data-id="debug-0"]').getByRole('button',{name:/検証を開始/});
    assert.equal(await prepare.isEnabled(),true);
    assert.equal(await page.locator('.debug-row[data-id="debug-2"]').getByRole('button',{name:/検証を開始/}).isEnabled(),false);
    await prepare.click();
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.operation),'prepare');
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.id),'debug-0');
    const preparing={...debugBoard,preparation:{id:'debug-0',title:'検証クエスト 0',help:'手動で操作して結果を確認します。',waypoint:true,cooldown:42}};
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:preparing,operation:'prepare'});
    assert.equal(await page.locator('#debug-preparation').isVisible(),true);
    assert.match(await page.locator('#debug-preparation-result').textContent(),/加算待ち/);
    assert.match(await page.locator('#debug-preparation-cooldown').textContent(),/42秒/);
    assert.equal(await page.locator('#debug-toggle').isEnabled(),false,'finish before stopping measurement');
    assert.equal(await page.locator('#debug-reset-all').isEnabled(),false);
    assert.equal(await prepare.isEnabled(),false,'no duplicate preparation');
    await page.locator('#debug-check').click();
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.operation),'list');
    preparing.quests=debugBoard.quests.map((q,i)=>i===0?{...q,value:1}:q);
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:preparing});
    assert.match(await page.locator('#debug-preparation-result').textContent(),/今回 \+1 回 を検出/);
    for (const size of [{width:1280,height:720},{width:375,height:667}]) {
      await page.setViewportSize(size);
      assert.equal(await page.locator('.workspace').evaluate(el=>el.scrollWidth<=el.clientWidth),true,'preparation fits '+size.width);
      if (size.width===1280 && process.env.GUI_PREPARATION_SCREENSHOT) {
        await page.locator('.workspace').evaluate(el=>{el.scrollTop=0;});
        await page.screenshot({path:process.env.GUI_PREPARATION_SCREENSHOT});
      }
    }
    const housePreparing={...preparing,
      quests:preparing.quests.map((q,i)=>i===0?{...q,value:0}:q),
      preparation:{...preparing.preparation,houseId:1,waypoint:false,
        startCheck:{allowed:false,message:'警察の人数が不足している(0/1人)'}}};
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:housePreparing});
    assert.match(await page.locator('#debug-house-status').textContent(),/警察の人数/);
    assert.equal(await page.locator('#debug-next-house').isVisible(),true);
    assert.equal(await page.locator('#debug-waypoint').isVisible(),false);
    assert.equal(await page.locator('#debug-finish').isEnabled(),true,'blocked start can still return from the doorway');
    for (const size of [{width:1280,height:720},{width:375,height:667}]) {
      await page.setViewportSize(size);
      assert.equal(await page.locator('.workspace').evaluate(el=>el.scrollWidth<=el.clientWidth),true,'house readiness fits '+size.width);
      if (size.width===1280 && process.env.GUI_HOUSE_SCREENSHOT) {
        await page.locator('.workspace').evaluate(el=>{el.scrollTop=0;});
        await page.screenshot({path:process.env.GUI_HOUSE_SCREENSHOT});
      }
    }
    await page.locator('#debug-next-house').click();
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.operation),'nextHouse');
    housePreparing.preparation.houseId=2;
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:housePreparing});
    assert.match(await page.locator('#debug-house-status').textContent(),/物件 2/);
    housePreparing.preparation.returnBlocked=true;
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:housePreparing});
    assert.match(await page.locator('#debug-house-status').textContent(),/通常の出口/);
    assert.equal(await page.locator('#debug-next-house').isEnabled(),false);
    assert.equal(await page.locator('#debug-finish').isEnabled(),false);
    assert.equal(await page.locator('#debug-check').isEnabled(),true);
    housePreparing.preparation.returnBlocked=false;
    housePreparing.preparation.startCheck={allowed:true,message:'通常の開始条件を満たしています。'};
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:housePreparing});
    assert.equal(await page.locator('#debug-finish').isEnabled(),true);
    assert.match(await page.locator('#debug-preparation-result').textContent(),/加算待ち/,'readiness does not manufacture progress');
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:preparing});
    await page.locator('#debug-waypoint').click();
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.operation),'waypoint');
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:preparing});
    await page.locator('#debug-finish').click();
    assert.equal(await page.evaluate(()=>nuiCalls.at(-1).data.operation),'finish');
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:debugBoard});
    assert.equal(await page.locator('#debug-preparation').isVisible(),false);
    assert.equal(await page.locator('#debug-toggle').isEnabled(),true);
    await send({action:'suimag-dailyquest:gui',visible:false});
    await send({action:'suimag-dailyquest:gui',visible:true,data:adminBoard,showDebug:true});
    assert.equal(await page.locator('#debug-view').isVisible(),true,'F10 resumes the debug view');
    await send({action:'suimag-dailyquest:debugResult',ok:true,data:debugBoard});
    for (const size of [{width:1920,height:1080},{width:1280,height:720},{width:375,height:667}]) {
      await page.setViewportSize(size);
      assert.equal(await page.locator('#debug-tab').isVisible(),true);
      assert.equal(await page.locator('.workspace').evaluate(el=>el.scrollWidth<=el.clientWidth),true,'debug fits '+size.width);
      if (size.width===1280 && process.env.GUI_SCREENSHOT) {
        await page.locator('.workspace').evaluate(el => { el.scrollTop=0; });
        await page.screenshot({path:process.env.GUI_SCREENSHOT});
      }
    }
    await send({action:'suimag-dailyquest:debugResult',ok:false,forbidden:true,message:'権限がありません'});
    assert.equal(await page.locator('#debug-view').isVisible(),false);
    assert.equal(await page.locator('#debug-tab').isVisible(),false);
    assert.equal(await page.locator('#board-view').isVisible(),true);
    // Lost startup notification: countdown is visible but the board message arrived
    // before the page loaded. A failed readiness callback must eventually replay it.
    const startup = await browser.newPage();
    await startup.addInitScript(data => {
      window.readyAttempts = 0;
      window.GetParentResourceName = () => 'suimag-test';
      window.fetch = async (_, options) => {
        window.readyAttempts++;
        if (window.readyAttempts === 1) return new Promise((_, reject) => {
          options.signal.addEventListener('abort', () => reject(new Error('callback timed out')));
        });
        if (window.readyAttempts === 2) return {ok:false};
        if (window.readyAttempts === 3) throw new Error('callback not registered');
        window.postMessage({action:'suimag-dailyquest:gui',visible:true,data},'*');
        return {ok:true};
      };
    }, board);
    await startup.goto(`http://127.0.0.1:${server.address().port}/countdown.html`);
    await startup.evaluate(() => window.postMessage({action:'suimag-dailyquest:countdown',visible:true,remaining:120,resetLabel:'tomorrow'},'*'));
    await startup.locator('#daily-countdown').waitFor({state:'visible'});
    assert.equal(await startup.locator('#quest-app').isVisible(),false);
    await startup.locator('#quest-app').waitFor({state:'visible',timeout:10000});
    assert.equal(await startup.evaluate(() => window.readyAttempts),4);
    assert.equal(await startup.locator('.quest-card').count(),3);
    await startup.close();
    assert.deepEqual(errors,[]);
    console.log('GUI browser: embedded transparency, rendering, actions, tabs, busy/close, setup, escaping, errors and responsive layout passed');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(error => { console.error(error);process.exitCode=1;server.close(); });
