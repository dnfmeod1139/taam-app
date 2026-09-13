// ═══════════════════════════════════════════════════════════════
// 서비스워커 앱 셸 — 같은 HTML 로는 알리지 않고, 캐시가 없어도 빈 화면은 아니다 (2026-09-13)
// ═══════════════════════════════════════════════════════════════
//   sw.js 를 가짜 self/caches/fetch 위에서 그대로 실행해 handleAppShell 을 잰다.
//   ① 캐시와 같은 ETag 의 200 → SW_HTML_UPDATED 를 보내지 않는다 ⭐
//   ② ETag 가 다르면 → 보낸다 ⭐
//   ③ 캐시 없음 + 네트워크 실패 → 빈 504 가 아니라 「다시 시도」 HTML(503) ⭐
//   ④ 캐시 없음 + 네트워크 성공 → 그 응답
//   ⑤ 캐시 있음 + 네트워크 느림 → 1초 뒤 캐시로
// 실행: node sql/_test/swshell.js
// ═══════════════════════════════════════════════════════════════
const fs = require('fs'), vm = require('vm');
let fail = 0, n = 0;
function ok(name, cond, detail){ n++; if (cond) console.log('OK  ', name); else { fail++; console.log('FAIL', name, detail ? '— ' + String(detail).slice(0, 160) : ''); } }

function mkEnv(){
  const store = new Map();      // cacheName → Map(url → Response)
  const posted = [];
  const cacheApi = (name) => {
    if (!store.has(name)) store.set(name, new Map());
    const m = store.get(name);
    return {
      match: async (req) => m.get(typeof req === 'string' ? req : req.url) || undefined,
      put: async (req, res) => { m.set(typeof req === 'string' ? req : req.url, res); },
      keys: async () => [...m.keys()],
    };
  };
  const self = {
    listeners: {},
    addEventListener(t, f){ (this.listeners[t] = this.listeners[t] || []).push(f); },
    skipWaiting(){}, location: { origin: 'https://taam-app.vercel.app' },
    clients: { matchAll: async () => [{ postMessage: (m) => posted.push(m) }], claim: async () => {} },
    registration: { showNotification: async () => {} },
  };
  const ctx = {
    self, console: { log(){}, warn(){}, error(){} }, setTimeout, clearTimeout, URL, Promise,
    caches: { open: async (name) => cacheApi(name), keys: async () => [...store.keys()], delete: async (k) => store.delete(k) },
    Response: class {
      constructor(body, init){ this.body = body; this.status = (init && init.status) || 200; this.headers = new Map(Object.entries((init && init.headers) || {}).map(([k,v]) => [k.toLowerCase(), v])); this.headers.get = Map.prototype.get; }
      clone(){ const r = new ctx.Response(this.body, { status: this.status }); r.headers = this.headers; return r; }
      get type(){ return 'basic'; }
    },
    fetch: null,
  };
  ctx.self.Response = ctx.Response;
  vm.createContext(ctx);
  const src = fs.readFileSync(__dirname + '/../../sw.js', 'utf8');
  vm.runInContext(src, ctx, { filename: 'sw.js' });
  // ⚠ 스크립트 최상위 const 는 vm 컨텍스트의 전역 속성이 아니다 — 소스에서 읽는다
  ctx.STATIC_CACHE = (src.match(/const STATIC_CACHE = '([^']+)'/) || [])[1];
  if (!ctx.STATIC_CACHE) throw new Error('STATIC_CACHE 를 못 읽음');
  return { ctx, store, posted };
}
const resp = (ctx, body, etag, status = 200) => { const r = new ctx.Response(body, { status, headers: etag ? { ETag: etag, 'Content-Length': String(body.length) } : {} }); return r; };
const req = { url: 'https://taam-app.vercel.app/', method: 'GET' };

(async () => {
  // ① 같은 ETag
  {
    const { ctx, store, posted } = mkEnv();
    const cache = await ctx.caches.open(ctx.STATIC_CACHE); await cache.put(req.url, resp(ctx, '<html>A</html>', '"v1"'));
    ctx.fetch = async () => resp(ctx, '<html>A</html>', '"v1"');
    const out = await ctx.handleAppShell(req, { waitUntil(){} });
    await new Promise(r => setTimeout(r, 50));
    ok('① 같은 ETag 의 200 → 알리지 않는다 ⭐', posted.length === 0, JSON.stringify(posted));
    ok('① 응답은 온다', out && out.status === 200);
  }
  // ② 다른 ETag
  {
    const { ctx, posted } = mkEnv();
    const cache = await ctx.caches.open(ctx.STATIC_CACHE); await cache.put(req.url, resp(ctx, '<html>A</html>', '"v1"'));
    ctx.fetch = async () => resp(ctx, '<html>B</html>', '"v2"');
    await ctx.handleAppShell(req, { waitUntil(){} });
    await new Promise(r => setTimeout(r, 50));
    ok('② ETag 가 다르면 SW_HTML_UPDATED ⭐', posted.some(m => m.type === 'SW_HTML_UPDATED'), JSON.stringify(posted));
  }
  // ③ 캐시 없음 + 네트워크 실패
  {
    const { ctx } = mkEnv();
    ctx.fetch = async () => { throw new Error('offline'); };
    const out = await ctx.handleAppShell(req, { waitUntil(){} });
    ok('③ 빈 504 대신 안내 HTML ⭐', out && out.status === 503 && /다시 시도/.test(out.body), out && (out.status + ' ' + String(out.body).slice(0, 60)));
  }
  // ④ 캐시 없음 + 네트워크 성공
  {
    const { ctx } = mkEnv();
    ctx.fetch = async () => resp(ctx, '<html>N</html>', '"v9"');
    const out = await ctx.handleAppShell(req, { waitUntil(){} });
    ok('④ 캐시 없으면 네트워크 응답', out && out.body === '<html>N</html>');
  }
  // ⑤ 캐시 있음 + 느린 네트워크
  {
    const { ctx } = mkEnv();
    const cache = await ctx.caches.open(ctx.STATIC_CACHE); await cache.put(req.url, resp(ctx, '<html>C</html>', '"v1"'));
    ctx.fetch = () => new Promise(r => setTimeout(() => r(resp(ctx, '<html>C</html>', '"v1"')), 3000));
    const t0 = Date.now();
    const out = await ctx.handleAppShell(req, { waitUntil(){} });
    ok('⑤ 1초 상한 뒤 캐시로', out && out.body === '<html>C</html>' && (Date.now() - t0) < 2500, (Date.now() - t0) + 'ms');
    await new Promise(r => setTimeout(r, 3200));
  }
  // ⑥ activate — 옛 셸이 새 캐시로 옮겨진다
  {
    const { ctx, store } = mkEnv();
    const old = await ctx.caches.open('taam-static-v0.0.1'); await old.put('/', resp(ctx, '<html>OLD</html>', '"v0"'));
    const act = ctx.self.listeners.activate[0];
    let done; act({ waitUntil(p){ done = p; } }); await done;
    const fresh = await ctx.caches.open(ctx.STATIC_CACHE);
    const moved = await fresh.match('/');
    ok('⑥ 버전 올려도 옛 셸이 폴백으로 남는다 ⭐', !!moved && moved.body === '<html>OLD</html>');
    ok('⑥ 옛 캐시는 지워진다', !store.has('taam-static-v0.0.1'));
  }
  console.log('\n' + (fail ? `=== 실패 ${fail}/${n} ===` : `=== 전부 통과 (${n}건) ===`));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
