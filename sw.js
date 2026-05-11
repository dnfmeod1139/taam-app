// ═══════════════════════════════════════════════════════════════
// TAAM Service Worker — Web Push 알림 + 기본 캐싱
// ═══════════════════════════════════════════════════════════════

const SW_VERSION = 'taam-sw-v1.1';   // 1.1 — iOS 호환 (icon/vibrate 제거)

self.addEventListener('install', (event) => {
  console.log('[SW] install', SW_VERSION);
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  console.log('[SW] activate', SW_VERSION);
  event.waitUntil(self.clients.claim());
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
