'use strict';
// Optional integration check: requires Playwright and a Chromium binary.
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
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH || '/usr/bin/chromium',args:['--no-sandbox']});
    const page = await browser.newPage({viewport:{width:1440,height:960}});
    const errors = [];page.on('pageerror', e => errors.push(e.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/preview.html`);
    const frame = page.frameLocator('iframe');
    await frame.locator('#quest-app').waitFor({state:'visible'});
    assert.equal(await frame.locator('.quest-card').count(), 3);
    assert.match(await frame.locator('#completion').textContent(), /1 \/ 3/);
    await frame.getByRole('button',{name:'報酬を受け取る ↗'}).click();
    await frame.locator('.quest-card').first().getByText('受取済み',{exact:true}).waitFor();
    await frame.locator('[data-period="weekly"]').click();
    assert.equal(await frame.locator('.quest-card').count(), 2);
    assert.equal(await frame.locator('#bonus').isVisible(), false);
    assert.match(await frame.locator('#reset-copy').textContent(), /期限内/);
    assert.equal(await frame.getByText('確認待ち',{exact:true}).count(), 2);
    const inner = page.frames()[1];
    await inner.evaluate(() => window.postMessage({action:'suimag-dailyquest:busy',busy:true},'*'));
    await frame.locator('#refresh:disabled').waitFor();
    assert.equal(await frame.locator('#close').isEnabled(), true);
    await inner.press('body', 'Escape');
    await frame.locator('#quest-app').waitFor({state:'hidden'});
    await page.locator('#reopen').click();await frame.locator('#quest-app').waitFor({state:'visible'});
    // Text must remain text, even when supplied by server-configurable titles.
    await inner.evaluate(() => window.postMessage({action:'suimag-dailyquest:gui',visible:true,data:{
      quests:[{id:'html',period:'daily',title:'<img src=x onerror=alert(1)>',description:'<script>bad()</script>',value:567,target:1000,scale:1000,precision:1,unit:'km',status:'active',available:false,reward:'銀行 $150,000'}]
    }},'*'));
    await frame.getByText('0.5 / 1 km',{exact:true}).waitFor();
    assert.equal(await frame.locator('.quest-card img, .quest-card script').count(),0);
    assert.equal(await frame.getByText('連携元が未起動',{exact:true}).count(),2);
    // Lua may serialize an empty table as an object instead of an array.
    await inner.evaluate(() => window.postMessage({action:'suimag-dailyquest:gui',visible:true,data:{needsSetup:true,quests:{}}},'*'));
    await frame.locator('.empty-state').waitFor();
    assert.match(await frame.locator('#section-title').textContent(),/あなたに合った/);
    // A failed callback remains recoverable and explains the problem.
    await inner.evaluate(() => { window.fetch = async () => { throw new Error('offline'); }; });
    await frame.locator('#refresh').click();
    await frame.getByText('通信に失敗しました。少し待って再度お試しください。').waitFor();
    assert.equal(await frame.locator('#refresh').isEnabled(),true);
    // Narrow displays scroll vertically and do not clip content horizontally.
    await page.locator('#reopen').click();
    for (const size of [{width:1280,height:720},{width:390,height:844}]) {
      await page.setViewportSize(size);
      const fits = await inner.evaluate(() => {
        const workspace = document.querySelector('.workspace');
        return workspace.scrollWidth <= workspace.clientWidth;
      });
      assert.equal(fits,true,`${size.width}px horizontal overflow`);
    }
    assert.deepEqual(errors,[]);
    console.log('GUI browser: rendering, claim, tabs, busy/close, setup, escaping, error recovery and responsive layout passed');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(error => { console.error(error);process.exitCode=1;server.close(); });
