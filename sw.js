// ═══════════════════════════════════════════════════════════════
// TAAM Service Worker — Web Push 알림 + 기본 캐싱
// ═══════════════════════════════════════════════════════════════

const SW_VERSION = 'taam-sw-v1.0';

self.addEventListener('install', (event) => {
  console.log('[SW] install', SW_VERSION);
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  console.log('[SW] activate', SW_VERSION);
  event.waitUntil(self.clients.claim());
});

// ─── Push 이벤트 ───
// 서버(Supabase Edge Function `send-push`)에서 web-push 라이브러리로 발송된 알림 수신
self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (e) {
    payload = { title: 'TAAM', body: event.data ? event.data.text() : '' };
  }

  const title = payload.title || 'TAAM';
  const options = {
    body: payload.body || '',
    icon: payload.icon || '/icons/icon-192.png',
    badge: payload.badge || '/icons/icon-192.png',
    tag: payload.tag || ('taam-' + Date.now()),
    data: {
      url: payload.url || '/',
      category: payload.category || 'system',
      ts: Date.now(),
    },
    actions: payload.actions || [],
    requireInteraction: !!payload.requireInteraction,
    silent: !!payload.silent,
    vibrate: payload.vibrate || [200, 100, 200],
  };

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
