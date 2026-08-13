// ═══════════════════════════════════════════════════════════════
// TAAM Service Worker — Web Push 알림 + 기본 캐싱
// ═══════════════════════════════════════════════════════════════

const SW_VERSION = 'taam-sw-v1.56.0';  // 1.55.2 — 2026.08: 자동 새로고침 재도입(네이티브 앱에 최신 index.html 강제 반영). index.html 의 "네이티브 splash-skip 미부여" 수정과 함께라 인트로/스킵 안 사라짐.
const STATIC_CACHE = 'taam-static-v1.56.0';

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
      // 🆕 v1.55.2: 새 버전 활성화 시 열린 창 자동 새로고침 — 네이티브 앱/설치형 PWA 가
      //   재실행만으로 최신 index.html 을 받도록(하드리프레시 불가 대응).
      //   ※ v1.55.0 때 이게 splash-skip 을 유발했으나, index.html 에 "네이티브는 splash-skip 미부여"
      //     수정을 넣어서 이제 리로드해도 인트로/스킵이 사라지지 않음.
      try {
        const wins = await self.clients.matchAll({ type: 'window' });
        for (const w of wins) { try { await w.navigate(w.url); } catch (e) {} }
      } catch (e) {}
    })()
  );
});

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

  // HTML / SW / manifest / API 는 캐싱 안 함 (항상 네트워크)
  if (
    url.pathname === '/' ||
    url.pathname === '/index.html' ||
    url.pathname === '/sw.js' ||
    url.pathname === '/manifest.json' ||
    url.pathname.startsWith('/api/') ||
    url.pathname.startsWith('/supabase/')
  ) return;

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
