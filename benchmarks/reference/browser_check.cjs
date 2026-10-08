// Optional headless fallback when the native T3 preview host is unavailable.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const playwrightPath = process.env.PLAYWRIGHT_MODULE || 'playwright';
const { chromium } = require(playwrightPath);
const [app, directory, labelPath] = process.argv.slice(2);
const labels = JSON.parse(fs.readFileSync(labelPath, 'utf8'));
const base = 'http://127.0.0.1:4390';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  const report = { app, browser: browser.version(), measured: false, pageErrors: [], badResponses: [], websockets: 0 };
  function observe(target) {
    target.on('pageerror', error => report.pageErrors.push(error.message));
    target.on('response', response => {
      if (response.url().startsWith(base) && response.status() >= 400)
        report.badResponses.push({ status: response.status(), url: response.url() });
    });
    target.on('websocket', () => report.websockets++);
  }
  observe(page);
  async function signIn(target, email) {
    await target.goto(base);
    await target.locator('input[type=email]').fill(email);
    await target.locator('input[type=password]').fill(labels['passwords.all']);
    await target.locator('button[type=submit]').first().click();
    await target.locator('input[type=password]').waitFor({ state: 'hidden' });
  }
  const selector = app === 'rust' ? '[data-message-id]' : 'article.message[data-id]';
  const attribute = app === 'rust' ? 'data-message-id' : 'data-id';
  async function ids() {
    return page.locator(selector).evaluateAll((nodes, attr) => [...new Set(nodes.map(n => n.getAttribute(attr)))], attribute);
  }
  try {
    await signIn(page, labels['emails.david']);
    report.login = true;
    await page.goto(`${base}/rooms/${labels['rooms.watercooler']}`);
    await page.waitForFunction(sel => document.querySelectorAll(sel).length >= 40, selector);
    report.roomMessages = (await ids()).length;
    assert.ok(report.roomMessages >= 40);
    report.roomTitle = await page.title();
    await page.screenshot({ path: path.join(directory, 'room.png') });
    if (app === 'vampfire') {
      await page.locator('[data-action=older]').click();
      await page.waitForFunction(() => document.querySelectorAll('article.message').length > 40);
      report.messagesAfterHistory = (await ids()).length;
      const recipientContext = await browser.newContext();
      const recipient = await recipientContext.newPage();
      observe(recipient);
      const received = new Set();
      recipient.on('websocket', socket => socket.on('framereceived', ({ payload }) => {
        const event = JSON.parse(payload.toString());
        if (event.kind === 'message') received.add(event.message.plain);
      }));
      await signIn(recipient, labels['emails.jason']);
      await recipient.goto(`${base}/rooms/${labels['rooms.watercooler']}`);
      await recipient.waitForFunction(() => document.querySelector('#presence')?.textContent.includes('here now'));
      await recipient.locator('#editor').fill('Keep this unsent draft');
      await recipient.evaluate(() => { window.savedEditor = document.querySelector('#editor'); });
      const messages = [
        'Main update: short payload',
        'Main update: unicode مرحباً 👋 ' + 'x'.repeat(4096),
        'Main update: reused mailbox',
      ];
      for (const message of messages) {
        await page.locator('#editor').fill(message);
        await page.locator('#composer button[type=submit]').click();
        await recipient.locator('article.message').filter({ hasText: message }).waitFor();
        assert.ok(received.has(message), 'Recipient must receive the message over WebSocket');
      }
      report.liveMessages = messages.length;
      report.liveUnicode = true;
      assert.equal(await recipient.locator('#editor').innerText(), 'Keep this unsent draft');
      assert.ok(await recipient.evaluate(() => window.savedEditor === document.querySelector('#editor')));
      report.draftPreservedDuringRefresh = true;
      await recipientContext.close();

      // A reconnect while viewing history must preserve the visible anchor and editor.
      await page.goto(`${base}/rooms/${labels['rooms.watercooler']}?at=${labels['messages.busy_060']}`);
      await page.locator(`#message-${labels['messages.busy_060']}`).waitFor();
      await page.waitForFunction(() => document.querySelector('#presence')?.textContent.includes('here now'));
      await page.locator('#editor').fill('Reconnect draft');
      const anchor = await page.evaluate(async () => {
        const { state } = await import('/assets/ui.js');
        const { connectSocket } = await import('/assets/chat.js');
        const top = document.querySelector('#messages').getBoundingClientRect().top;
        const first = [...document.querySelectorAll('#messages .message')].find(item => item.getBoundingClientRect().bottom > top);
        window.savedEditor = document.querySelector('#editor');
        const previous = state.socket;
        connectSocket();
        // A queued callback from a replaced connection must have no effect.
        previous.dispatchEvent(new MessageEvent('message', { data: JSON.stringify({kind: 'message_deleted', message_id: Number(first.dataset.id)}) }));
        return Number(first.dataset.id);
      });
      await page.waitForFunction(async () => (await import('/assets/ui.js')).state.socket.readyState === WebSocket.OPEN);
      await page.waitForTimeout(250);
      await page.locator(`#message-${anchor}`).waitFor();
      assert.equal(await page.locator('#editor').innerText(), 'Reconnect draft');
      assert.ok(await page.evaluate(() => window.savedEditor === document.querySelector('#editor')));
      report.historyReconnectAnchor = anchor;
      report.replacedSocketIgnored = true;

      // Release an older request only after the user has switched to a different room.
      let release, started;
      const held = new Promise(resolve => { release = resolve; });
      const requested = new Promise(resolve => { started = resolve; });
      const hq = labels['rooms.hq'];
      await page.route(`**/api/rooms/${hq}/messages`, async route => {
        started();
        await held;
        await route.continue();
      });
      await page.locator(`#sidebar [data-room="${hq}"]`).first().click();
      await requested;
      await page.locator(`#sidebar [data-room="${labels['rooms.watercooler']}"]`).first().click();
      release();
      await page.waitForTimeout(250);
      assert.ok(await page.evaluate(async room => {
        const { state } = await import('/assets/ui.js');
        return state.room.id === room && state.messages.length > 0 && state.messages.every(message => message.room_id === room);
      }, labels['rooms.watercooler']));
      await page.unroute(`**/api/rooms/${hq}/messages`);
      report.roomSwitchRace = true;

      await page.locator('#editor').fill('Current pipeline preview');
      await page.locator('#file-picker').setInputFiles(path.resolve(__dirname, '../../.build/comparison/rust-source/reference/test/fixtures/files/black_hole.jpg'));
      await page.locator('.pending-file').waitFor();
      await page.locator('#composer button[type=submit]').click();
      await page.locator('article.message').filter({ hasText: 'Current pipeline preview' }).waitFor();
      const image = page.locator('article.message img.message-image[alt="black_hole.jpg"][src*="thumb=1"]').last();
      await image.waitFor();
      await image.evaluate(img => img.decode());
      report.thumbnailDecoded = await image.evaluate(img => img.naturalWidth > 0 && img.naturalHeight > 0);
      assert.ok(report.thumbnailDecoded);
      const href = await image.locator('xpath=../..').locator('a[download]').getAttribute('href');
      const download = await context.request.get(`${base}${href}`);
      assert.equal(download.status(), 200);
      assert.ok((await download.body()).equals(fs.readFileSync(path.resolve(__dirname, '../../.build/comparison/rust-source/reference/test/fixtures/files/black_hole.jpg'))));
      report.originalDownload = true;

      await page.setViewportSize({ width: 390, height: 844 });
      await page.emulateMedia({ colorScheme: 'dark' });
      await page.waitForFunction(() => document.querySelector('#sidebar').getBoundingClientRect().right <= 0);
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      await page.screenshot({ path: path.join(directory, 'mobile.png') });
      report.mobileFits = true;
      await page.setViewportSize({ width: 1440, height: 1000 });
    } else {
      // The upstream earlier-page route is a Turbo fragment; inspect it in the browser.
      await page.goto(`${base}/rooms/${labels['rooms.watercooler']}/messages?before=${labels['messages.busy_060']}`);
      report.earlierFragmentMessages = (await ids()).length;
      assert.equal(report.earlierFragmentMessages, 40);
    }
    if (app === 'rust') {
      await page.goto(`${base}/searches?q=coffee`);
    } else {
      await page.goto(`${base}/search`);
      await page.locator('#search-query').fill('coffee');
      await page.locator('#search-form button[type=submit]').click();
    }
    await page.waitForFunction(sel => document.querySelectorAll(sel).length === 13, selector);
    report.searchMatches = (await ids()).length;
    assert.equal(report.searchMatches, 13);
    await page.screenshot({ path: path.join(directory, 'search.png') });
    assert.deepEqual(report.pageErrors, []);
    assert.deepEqual(report.badResponses, []);
    report.passed = true;
  } catch (error) {
    report.passed = false;
    report.error = error.message;
    report.url = page.url();
    report.visibleText = (await page.locator('body').innerText()).slice(0, 6000);
    await page.screenshot({ path: path.join(directory, 'failure.png') });
    process.exitCode = 1;
  } finally {
    fs.writeFileSync(path.join(directory, 'browser.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report));
    await browser.close();
  }
})();
