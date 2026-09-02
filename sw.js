// ═══════════════════════════════════════════════════════════════
// TAAM Service Worker — Web Push 알림 + 기본 캐싱
// ═══════════════════════════════════════════════════════════════

const SW_VERSION = 'taam-sw-v1.73.0';  // 1.55.2 — 2026.08: 자동 새로고침 재도입(네이티브 앱에 최신 index.html 강제 반영). index.html 의 "네이티브 splash-skip 미부여" 수정과 함께라 인트로/스킵 안 사라짐.
const STATIC_CACHE = 'taam-static-v1.73.0';

self.addEventListener('install', (event) => {
  console.log('[SW] install', SW_VERSION);
  // 새 버전 install 즉시 활성화 (waiting 단계 건너뜀)
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  console.log('[SW] activate', SW_VERSION);
  // 옛 SW가 만든 모든 캐시 삭제 (현재 SW의 STATIC_CACHE 제외)
  event.waitUntil(
    (async () => {
      // 옛 SW가 만든 모든 캐시 삭제 (현재 STATIC_CACHE 제외)
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => (k === STATIC_CACHE ? null : caches.delete(k))));
      // 현재 열린 모든 탭의 SW를 즉시 새 버전으로 교체
      await self.clients.claim();
      // 🔧 2026.08-31: **강제 새로고침을 그만둔다.** 페이지에게 물어본다.
      //
      //   종전에는 여기서 열린 창을 전부 w.navigate(w.url) 로 리로드했다.
      //   그런데 배포는 하루에도 여러 번 나가고, 그때 회원이 결제 중이면
      //   **결제 시트가 통째로 날아간다.** 좌석 홀드를 잡아둔 채 리로드되면
      //   무슨 일이 일어났는지 회원은 알 수가 없다.
      //   사진 정리 도구처럼 몇십 분 도는 작업도 중간에 끊긴다.
      //
      //   이제 메시지만 보낸다. 리로드할지는 페이지가 정한다 —
      //   한가하면 즉시, 바쁘면 일이 끝난 뒤에. (index.html _onSwMessage)
      //   페이지가 옛 빌드라 이 메시지를 모르면? 그냥 아무 일도 안 일어나고
      //   다음 실행에서 최신을 받는다 — 강제로 끊는 것보다 낫다.
      try {
        const wins = await self.clients.matchAll({ type: 'window' });
        for (const w of wins) {
          try { w.postMessage({ type: 'SW_ACTIVATED', version: SW_VERSION }); } catch (e) {}
        }
      } catch (e) {}
    })()
  );
});

// 🆕 2026.08: 앱 셸 전략 상수/헬퍼
// 🔧 2026.08-31: 3000 → 1000.
//   캐시가 있는데도 네트워크를 3초까지 기다렸다. 셀룰러에서 앱 셸(압축 약 1.1MB)을
//   받는 데 2.5초가 걸리면 그 2.5초가 그대로 스플래시 시간이 됐다.
//   1초로 줄이면 회선이 괜찮을 때는 지금과 똑같이 최신을 쓰고(1초 안에 옴),
//   느릴 때만 캐시로 먼저 그린다. 네트워크 응답은 도착하는 대로 캐시에 반영되므로
//   다음 실행은 최신이다 — 「한 실행 뒤처짐」은 느린 회선에서만, 한 번만 생긴다.
const HTML_TIMEOUT_MS = 1000;   // 이 시간 안에 네트워크가 응답 못 하면 캐시로 먼저 렌더

function isAppShell(url) {
  return url.pathname === '/' || url.pathname === '/index.html';
}

async function handleAppShell(req, event) {
  const cache = await caches.open(STATIC_CACHE);

  // 네트워크 시도 — 성공하면 캐시를 갱신해 다음 실행이 최신을 쓰게 한다.
  //
  // ⚠ 2026-09-01: 여기가 옛 빌드에 갇히는 자리였다.
  //   index.html 이 4.7MB 라 1초 안에 못 받는다 → 거의 항상 캐시로 렌더된다.
  //   그건 의도한 것이다(빠른 부팅). 문제는 **배경 갱신이 안 끝난다**는 것.
  //   respondWith 가 캐시로 먼저 답하면 브라우저가 SW 를 재울 수 있고,
  //   그러면 cache.put 이 날아간다. 다음 실행도 같은 옛 캐시를 쓴다 —
  //   이렇게 며칠이고 갇힌다. 실제로 -c 에서 -e 까지 세 빌드를 못 봤다.
  //   event.waitUntil 로 그 갱신이 끝날 때까지 SW 를 붙잡는다.
  const network = fetch(req).then(async (res) => {
    if (res && res.status === 200) {
      await cache.put(req, res.clone()).catch(() => {});
      // 캐시가 바뀌었으면 열린 창에 알린다. **리로드는 앱이 정한다** —
      //   결제·편집 중이면 미룬다(_taamApplyUpdateWhenIdle).
      try {
        const ws = await self.clients.matchAll({ type: 'window' });
        ws.forEach((w) => w.postMessage({ type: 'SW_HTML_UPDATED', version: SW_VERSION }));
      } catch (e) {}
    }
    return res;
  });
  if (event && typeof event.waitUntil === 'function') {
    try { event.waitUntil(network.catch(() => {})); } catch (e) {}
  }
  // 네트워크 실패가 unhandled rejection 이 되지 않도록 흡수 (아래에서 별도 처리)
  const networkSafe = network.catch(() => null);

  const cached = await cache.match(req);

  // 캐시가 없으면(최초 실행) 네트워크를 끝까지 기다린다.
  if (!cached) {
    const res = await networkSafe;
    return res || new Response('', { status: 504 });
  }

  // 캐시가 있으면 네트워크를 상한까지만 기다리고, 늦으면 캐시로 즉시 렌더.
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), HTML_TIMEOUT_MS));
  const fresh = await Promise.race([networkSafe, timeout]);
  return fresh || cached;
}

// 🆕 2026.05.21: fetch 핸들러 — 정적 리소스만 stale-while-revalidate 전략
//   HTML/JSON/API 는 항상 네트워크 (캐시 안 함). 이미지/폰트/CSS 등은 캐시 우선 + 백그라운드 갱신.
//   첫 로딩 후 두 번째부터 매우 빨라짐.
self.addEventListener('fetch', (event) => {
  const req = event.request;

  // GET 요청만 캐싱 (POST 등은 항상 네트워크)
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // 같은 origin 만 SW 캐싱 (외부 CDN 도 추가 가능)
  const isSameOrigin = url.origin === self.location.origin;
  const isExternalCDN = (
    url.hostname === 'fonts.googleapis.com' ||
    url.hostname === 'fonts.gstatic.com' ||
    url.hostname === 'cdnjs.cloudflare.com' ||
    url.hostname === 'unpkg.com'
  );

  if (!isSameOrigin && !isExternalCDN) return;

  // SW / manifest / API 는 항상 네트워크 (캐싱 안 함)
  if (
    url.pathname === '/sw.js' ||
    url.pathname === '/manifest.json' ||
    url.pathname.startsWith('/api/') ||
    url.pathname.startsWith('/supabase/')
  ) return;

  // 🆕 2026.08: 앱 셸(index.html) — 네트워크 우선 + 타임아웃 시 캐시 폴백
  //   기존에는 HTML 을 캐싱에서 제외해 매 실행마다 약 1MB(gzip)를 새로 받았다.
  //   Wi-Fi 에서는 티가 안 나지만 셀룰러에서는 그대로 대기 시간이 된다.
  //   최신 코드 반영이라는 기존 의도는 유지하되(네트워크를 먼저 시도),
  //   느린 회선에서 무한정 기다리지 않도록 상한을 둔다.
  //   · 네트워크가 HTML_TIMEOUT_MS 안에 응답 → 그대로 사용 + 캐시 갱신 (평소 동작 그대로)
  //   · 시간 초과/실패 → 직전 캐시로 즉시 렌더, 네트워크 응답은 도착하는 대로 캐시에 반영
  //   · 캐시도 없으면(최초 실행) 네트워크를 끝까지 기다린다
  if (isAppShell(url)) {
    event.respondWith(handleAppShell(req, event));
    return;
  }

  // 정적 리소스만 캐싱 (이미지·폰트·CSS·JS·JSON 데이터)
  const isStatic = /\.(png|jpg|jpeg|gif|svg|webp|avif|ico|woff|woff2|ttf|otf|eot|css|js|json|html)$/i.test(url.pathname);
  if (!isStatic) return;

  event.respondWith(
    caches.open(STATIC_CACHE).then(async (cache) => {
      const cached = await cache.match(req);

      // 백그라운드 갱신 (stale-while-revalidate)
      const networkFetch = fetch(req).then((res) => {
        if (res && res.status === 200 && res.type !== 'opaque') {
          cache.put(req, res.clone()).catch(() => {});
        }
        return res;
      }).catch(() => null);

      // 캐시 있으면 즉시 반환, 없으면 네트워크 대기
      return cached || networkFetch || new Response('', { status: 504 });
    })
  );
});

// ─── Push 이벤트 ───
// 서버(Supabase Edge Function `send-push`)에서 발송된 알림 수신.
// iOS Web Push 호환을 위해 최소 옵션만 사용 — icon/badge/vibrate/actions 는 명시적 전달 시에만.
self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (e) {
    payload = { title: 'TAAM', body: event.data ? event.data.text() : '' };
  }

  const title = payload.title || 'TAAM';
  // 최소 필수 옵션만 (iOS 호환)
  const options = {
    body: payload.body || '',
    tag: payload.tag || ('taam-' + Date.now()),
    data: {
      url: payload.url || '/',
      category: payload.category || 'system',
      ts: Date.now(),
    },
  };
  // 명시적으로 들어온 경우에만 추가 (없으면 default — iOS 가 잘 처리)
  if (payload.icon) options.icon = payload.icon;
  if (payload.badge) options.badge = payload.badge;
  if (payload.requireInteraction) options.requireInteraction = true;
  if (payload.silent) options.silent = true;
  if (payload.actions && Array.isArray(payload.actions) && payload.actions.length > 0) {
    options.actions = payload.actions;
  }
  // vibrate 는 iOS 미지원 — 제거

  event.waitUntil(self.registration.showNotification(title, options));
});

// ─── 알림 클릭 ───
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      // 이미 열린 TAAM 탭이 있으면 포커스
      for (const client of clients) {
        if (client.url.includes(self.location.origin) && 'focus' in client) {
          if ('navigate' in client && targetUrl !== '/') {
            client.navigate(targetUrl).catch(() => {});
          }
          return client.focus();
        }
      }
      // 없으면 새 탭 오픈
      if (self.clients.openWindow) {
        return self.clients.openWindow(targetUrl);
      }
    })
  );
});

// ─── Subscription 변경 (브라우저가 만료시킴) ───
self.addEventListener('pushsubscriptionchange', (event) => {
  console.log('[SW] pushsubscriptionchange');
  // 클라이언트에 재구독 요청 — 메시지로 알림
  event.waitUntil(
    self.clients.matchAll({ type: 'window' }).then((clients) => {
      clients.forEach((client) => {
        client.postMessage({ type: 'PUSH_SUBSCRIPTION_CHANGED' });
      });
    })
  );
});

// ─── 메시지 (앱 → SW) ───
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
