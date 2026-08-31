const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport:{width:390,height:844} });
  const errs=[]; p.on('pageerror', e => errs.push(String(e).slice(0,200)));
  await p.route('**', r => (r.request().url().startsWith('file:') ? r.continue() : r.abort()));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil:'domcontentloaded', timeout:60000 });
  await p.waitForTimeout(4500);
  // _tbLoad 의 필터만 떼어내 실제 데이터 모양으로 검증
  const out = await p.evaluate(() => {
    const keep = (pid, st) => {
      const _pid = String(pid||''), _st = String(st||'');
      if((_pid.indexOf('PAYH-')===0 || _pid.indexOf('INVH-')===0)
         && _st!=='active' && _st!=='completed' && _st!=='manual') return false;
      if(_st==='hold') return false;
      return true;
    };
    return {
      '9/10 PAYH+active (이창훈)':        keep('PAYH-1787212743674_1787278447062','active'),
      '9/11 INV+active':                  keep('INV-673fbf42-1780560761479','active'),
      '9/30 PAYH+cancelled (테스트 홀드)': keep('PAYH-1788137391277_1788137421534','cancelled'),
      '미결제 홀드 PAYH+hold':             keep('PAYH-999_888','hold'),
      '초대 홀드 INVH+hold':               keep('INVH-673fbf42-123','hold'),
      '일반 결제건 (숫자)+cancelled':      keep('1780077607766_1782706045560','cancelled'),
      '수동입력 MAN+manual':               keep('MAN-123','manual'),
      buildVal: TAAM_WEB_BUILD
    };
  });
  console.log(JSON.stringify(out, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
