import asyncio, sys
from playwright.async_api import async_playwright
BASE = 'http://127.0.0.1:18090/betterguac/'
user, pw = open('/w/admin_user').read().strip(), open('/w/admin_pw').read().strip()

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        pg = await b.new_page(viewport={'width': 1440, 'height': 900})
        errs = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        await pg.goto(BASE)
        await pg.fill('input[name=username]', user)
        await pg.fill('input[name=password]', pw)
        await pg.press('input[name=password]', 'Enter')
        await pg.wait_for_timeout(4000)
        nav = await pg.locator('text=Activity').count()
        print('nav Activity links:', nav)
        await pg.goto(BASE + '#/activity')
        await pg.wait_for_selector('.bg-act-row[data-action]', timeout=15000)
        await pg.wait_for_timeout(1500)
        print('rows on page:', await pg.locator('.bg-act-row[data-action]').count())
        print('summary:', (await pg.locator('.bg-act-summary').inner_text()).strip())
        await pg.screenshot(path='/w/activity.png', full_page=False)
        await pg.click('.bg-act-chip[data-cat=session]')
        await pg.wait_for_timeout(1500)
        acts = await pg.eval_on_selector_all('.bg-act-row[data-action]', 'els => els.map(e => e.dataset.action)')
        print('session filter actions:', sorted(set(acts)))
        await pg.screenshot(path='/w/activity-sessions.png')
        await pg.click('.bg-act-chip:has-text("All")')
        await pg.wait_for_timeout(800)
        await pg.click('.bg-act-settings-btn')
        await pg.wait_for_selector('.bg-act-modal .bg-modal')
        await pg.wait_for_timeout(500)
        await pg.screenshot(path='/w/activity-retention.png')
        print('page errors:', errs)
        await b.close()

asyncio.run(main())
