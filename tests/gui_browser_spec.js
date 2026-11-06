'use strict';
// Optional integration check: requires Playwright and Chromium, no game server.
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../ui');
const server = http.createServer((req, res) => {
  const name = path.basename(req.url.split('?')[0]);
  const filename = path.join(root, name);
  if (!fs.existsSync(filename) || !fs.statSync(filename).isFile()) { res.writeHead(404);res.end();return; }
  res.setHeader('Content-Type', name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html');
  res.end(fs.readFileSync(filename));
});
const board = {
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
    const show = async (data=board,selected='daily') => {
      await page.evaluate(({data,selected}) => window.postMessage({action:'suimag-dailyquest:gui',visible:true,data,selected},'*'),{data,selected});
      await page.locator('#quest-app').waitFor({state:'visible'});
    };
    await page.goto(`http://127.0.0.1:${server.address().port}/countdown.html`);
    assert.equal(await page.locator('#quest-app').isVisible(),false);
    assert.deepEqual(await page.evaluate(()=>nuiCalls),[{url:'https://suimag-test/questReady',data:{}}]);
    await show();
    assert.equal(await page.locator('.quest-card').count(), 3);
    assert.match(await page.locator('#completion').textContent(), /1 \/ 3/);
    assert.equal(await page.locator('.rail-caption').textContent(),'FLECITY');
    assert.equal(await page.locator('#preferences').textContent(),'⚙ クエスト抽選設定');
    assert.equal(await page.locator('.reward').first().textContent(),'銀行 $150000 + 黒コイン × 1');
    await page.getByRole('button',{name:'報酬を受け取る ↗'}).click();
    assert.deepEqual(await page.evaluate(()=>nuiCalls.at(-1).data),{action:'claim',period:'daily',id:'visit'});
    board.quests[0].status='claimed';await show();
    await page.locator('.quest-card').first().getByText('受取済み',{exact:true}).waitFor();
    await page.locator('[data-period="weekly"]').click();
    assert.equal(await page.locator('.quest-card').count(), 2);
    assert.equal(await page.locator('#bonus').isVisible(), false);
    assert.match(await page.locator('#reset-copy').textContent(), /期限内/);
    assert.equal(await page.locator('.reward').first().textContent(),'銀行 $500000 + 白コイン × 3');
    assert.equal(await page.getByText('確認待ち',{exact:true}).count(), 2);
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
    await show({needsSetup:true,quests:{}});
    await page.locator('.empty-state').waitFor();
    assert.match(await page.locator('#section-title').textContent(),/あなたに合った/);
    await page.evaluate(() => { window.fetch = async () => { throw new Error('offline'); }; });
    await page.locator('#refresh').click();
    await page.getByText('通信に失敗しました。少し待って再度お試しください。').waitFor();
    assert.equal(await page.locator('#refresh').isEnabled(),true);
    await show();
    for (const size of [{width:1280,height:720},{width:390,height:844}]) {
      await page.setViewportSize(size);
      const fits = await page.evaluate(() => {
        const workspace = document.querySelector('.workspace');
        return workspace.scrollWidth <= workspace.clientWidth;
      });
      assert.equal(fits,true,`${size.width}px horizontal overflow`);
    }
    assert.deepEqual(errors,[]);
    console.log('GUI browser: rendering, actions, tabs, busy/close, setup, escaping, errors and responsive layout passed');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(error => { console.error(error);process.exitCode=1;server.close(); });
