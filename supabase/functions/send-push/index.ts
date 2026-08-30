// ═══════════════════════════════════════════════════════════════
// TAAM — Web Push 발송 Edge Function (v2 — Deno-native 구현)
// 함수명: send-push
//
// v1 (web-push@3.6.7 npm) 폐기 — Node.js 의존성이 Supabase Edge Runtime 의
// Deno v2.1.4 환경에서 깨짐 (Deno.core.runMicrotasks() 미지원).
// v2 는 Deno Web Crypto API 만으로 RFC 8030 + RFC 8291 직접 구현.
//
// 호출 방식 (POST):
//   {
//     to:        "user" | "all" | "role:admin" | "topic:ticket" | "uid:<UUID>",
//     payload:   { title, body, icon?, url?, category?, tag? },
//     dedupe?:   true,
//     exclude_user_id?: <UUID>
//   }
//
// 환경변수:
//   VAPID_PUBLIC_KEY   — 65-byte uncompressed P-256 public, base64url
//   VAPID_PRIVATE_KEY  — 32-byte P-256 private, base64url
//   VAPID_SUBJECT      — mailto: 또는 https:// URL
// ═══════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") || "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@taam-app.vercel.app";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// ─────────────────────────────────────────────────────
// Base64URL helpers
// ─────────────────────────────────────────────────────
function b64urlEncode(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function b64urlDecode(str: string): Uint8Array {
  const padded = str.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((str.length + 3) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function concatBytes(...arrs: Uint8Array[]): Uint8Array {
  const total = arrs.reduce((s, a) => s + a.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrs) { out.set(a, off); off += a.length; }
  return out;
}

// ─────────────────────────────────────────────────────
// VAPID JWT (ES256)
// ─────────────────────────────────────────────────────
async function importVapidPrivateKey(privateKeyB64Url: string): Promise<CryptoKey> {
  // 32 bytes raw → JWK 변환 (Web Crypto 는 raw 형식의 EC private key 직접 import 못함)
  const d = b64urlEncode(b64urlDecode(privateKeyB64Url));
  // public key 도 필요 — 별도로 derive 하기 복잡하니까 VAPID_PUBLIC_KEY 의 X,Y 사용
  const pubRaw = b64urlDecode(VAPID_PUBLIC); // 65 bytes: 0x04 || X(32) || Y(32)
  if (pubRaw.length !== 65 || pubRaw[0] !== 0x04) {
    throw new Error("Invalid VAPID public key length/format");
  }
  const x = b64urlEncode(pubRaw.slice(1, 33));
  const y = b64urlEncode(pubRaw.slice(33, 65));
  const jwk = {
    kty: "EC",
    crv: "P-256",
    d, x, y,
    key_ops: ["sign"],
    ext: true,
  };
  return await crypto.subtle.importKey(
    "jwk", jwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false, ["sign"]
  );
}

async function signVapidJwt(audience: string): Promise<string> {
  const header = { typ: "JWT", alg: "ES256" };
  const payload = {
    aud: audience,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: VAPID_SUBJECT,
  };
  const headerB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const payloadB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const data = new TextEncoder().encode(headerB64 + "." + payloadB64);
  const privKey = await importVapidPrivateKey(VAPID_PRIVATE);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: { name: "SHA-256" } },
    privKey, data
  );
  return headerB64 + "." + payloadB64 + "." + b64urlEncode(sig);
}

// ─────────────────────────────────────────────────────
// HKDF (RFC 5869) — Web Crypto deriveBits with HKDF
// ─────────────────────────────────────────────────────
async function hkdfExtract(ikm: Uint8Array, salt: Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw", salt, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const prk = await crypto.subtle.sign("HMAC", key, ikm);
  return new Uint8Array(prk);
}
async function hkdfExpand(prk: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw", prk, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const out: Uint8Array[] = [];
  let prev = new Uint8Array(0);
  let counter = 1;
  let totalLen = 0;
  while (totalLen < length) {
    const data = concatBytes(prev, info, new Uint8Array([counter]));
    const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
    out.push(sig);
    totalLen += sig.length;
    prev = sig;
    counter++;
  }
  return concatBytes(...out).slice(0, length);
}

// ─────────────────────────────────────────────────────
// AES128GCM 페이로드 암호화 (RFC 8291)
// ─────────────────────────────────────────────────────
async function encryptPayloadAes128Gcm(
  payload: Uint8Array,
  uaPublicKey: Uint8Array,   // 65 bytes uncompressed
  uaAuthSecret: Uint8Array,  // 16 bytes
): Promise<Uint8Array> {
  // 1. 임시 ECDH 키 쌍 생성
  const asKeys = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]
  );
  const asPubRaw = new Uint8Array(await crypto.subtle.exportKey("raw", asKeys.publicKey));

  // 2. ECDH shared secret
  const uaPubKey = await crypto.subtle.importKey(
    "raw", uaPublicKey, { name: "ECDH", namedCurve: "P-256" }, false, []
  );
  const sharedSecret = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "ECDH", public: uaPubKey },
      asKeys.privateKey,
      256
    )
  );

  // 3. salt 16 bytes 랜덤
  const salt = crypto.getRandomValues(new Uint8Array(16));

  // 4. IKM = HKDF-Expand(HKDF-Extract(auth_secret, ECDH_output), "WebPush: info\x00||UA_public||AS_public", 32)
  //    🔧 BUG FIX: hkdfExpand 내부에서 counter 0x01 을 자동 append 하므로 info 에 0x01 추가 X
  const prkKey = await hkdfExtract(sharedSecret, uaAuthSecret);
  const keyInfo = concatBytes(
    new TextEncoder().encode("WebPush: info\x00"),
    uaPublicKey,
    asPubRaw,
  );
  const ikm = await hkdfExpand(prkKey, keyInfo, 32);

  // 5. CEK = HKDF-Expand(HKDF-Extract(salt, IKM), "Content-Encoding: aes128gcm\x00", 16)
  const prk = await hkdfExtract(ikm, salt);
  const cekInfo = new TextEncoder().encode("Content-Encoding: aes128gcm\x00");
  const cek = await hkdfExpand(prk, cekInfo, 16);

  // 6. Nonce = HKDF-Expand(prk, "Content-Encoding: nonce\x00", 12)
  const nonceInfo = new TextEncoder().encode("Content-Encoding: nonce\x00");
  const nonce = await hkdfExpand(prk, nonceInfo, 12);

  // 7. AES-GCM encrypt (payload + 0x02 delimiter — single record)
  const cekKey = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const plainWithPad = concatBytes(payload, new Uint8Array([0x02]));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, cekKey, plainWithPad)
  );

  // 8. aes128gcm 헤더 구성:
  //    salt(16) | record_size(4 BE) | key_id_len(1) | key_id(0..255) | ciphertext
  //    key_id = AS public key (65 bytes)
  const recordSize = new Uint8Array(4);
  // record size = 4096 (충분히 큼 — 단일 record)
  new DataView(recordSize.buffer).setUint32(0, 4096, false);

  return concatBytes(
    salt,                            // 16
    recordSize,                      // 4
    new Uint8Array([asPubRaw.length]), // 1 (=65)
    asPubRaw,                        // 65
    ciphertext,                      // payload + tag
  );
}

// ─────────────────────────────────────────────────────
// Web Push 발송
// ─────────────────────────────────────────────────────
async function sendWebPush(
  endpoint: string,
  p256dh: string,
  auth: string,
  payload: string,
  ttl = 86400,
): Promise<{ status: number; body: string }> {
  const aud = new URL(endpoint).origin;
  const jwt = await signVapidJwt(aud);

  const uaPub = b64urlDecode(p256dh);
  const uaAuth = b64urlDecode(auth);
  const payloadBytes = new TextEncoder().encode(payload);
  const encrypted = await encryptPayloadAes128Gcm(payloadBytes, uaPub, uaAuth);

  const headers: Record<string, string> = {
    "TTL": String(ttl),
    "Content-Encoding": "aes128gcm",
    "Content-Type": "application/octet-stream",
    "Content-Length": String(encrypted.length),
    "Authorization": `vapid t=${jwt}, k=${VAPID_PUBLIC}`,
  };

  const res = await fetch(endpoint, {
    method: "POST",
    headers,
    body: encrypted,
  });
  const body = await res.text();
  return { status: res.status, body };
}

// ─────────────────────────────────────────────────────
// FCM v1 API — OAuth2 + JWT (RS256) for Firebase Cloud Messaging
//   Legacy Server Key (fcm.googleapis.com/fcm/send) 가 2024-06 폐기되어
//   Service Account JSON 기반 OAuth2 토큰 + HTTP v1 API 로 마이그레이션.
//
//   환경변수: FIREBASE_SERVICE_ACCOUNT
//     = Firebase Console > 프로젝트 설정 > 서비스 계정 > 새 비공개 키 생성
//       으로 받은 JSON 파일 내용 전체 (string)
// ─────────────────────────────────────────────────────
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get("FIREBASE_SERVICE_ACCOUNT") || "";

// ════════════════════════════════════════════════════════════
// 🆕 2026-08: APNs 직접 발송 (iOS 네이티브)
//
//   왜 필요한가
//     @capacitor/push-notifications 는 iOS 에서 APNs 기기토큰을 준다.
//     그런데 여기서는 그 토큰을 FCM v1 의 message.token 으로 보내고 있었다.
//     FCM 은 자기가 발급한 등록토큰만 받으므로 APNs 토큰은 무조건 거부된다 —
//     Firebase 를 붙이지 않는 한 iOS 알림은 한 통도 나갈 수 없는 구조였다.
//     APNs 로 곧장 보내면 Firebase 없이 iOS 가 열린다.
//
//   필요한 시크릿 (Supabase Dashboard → Edge Functions → Secrets)
//     APNS_KEY_ID      — Apple Developer → Keys 에서 만든 APNs 키의 Key ID (10자)
//     APNS_TEAM_ID     — Apple Developer 팀 ID (10자)
//     APNS_PRIVATE_KEY — 그 키의 .p8 파일 내용 전체 (-----BEGIN PRIVATE KEY----- 포함)
//     APNS_BUNDLE_ID   — com.playtaam.app  (없으면 이 값으로 기본 동작)
//     APNS_HOST        — 기본 api.push.apple.com (개발 빌드 검증 시 api.sandbox.push.apple.com)
//   ⚠ 셋 중 하나라도 없으면 APNs 를 건너뛰고 기존 FCM 경로로 폴백한다.
// ════════════════════════════════════════════════════════════
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") || "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") || "";
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY") || "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") || "com.playtaam.app";
const APNS_HOST = Deno.env.get("APNS_HOST") || "api.push.apple.com";
const APNS_READY = !!(APNS_KEY_ID && APNS_TEAM_ID && APNS_PRIVATE_KEY);

// APNs 토큰(JWT ES256)은 최대 1시간 유효 — 55분마다 새로 만든다
let _apnsJwt: string | null = null;
let _apnsJwtAt = 0;

async function _apnsImportKey(pem: string): Promise<CryptoKey> {
  const b64 = pem.replace(/-----BEGIN PRIVATE KEY-----/g, "")
                 .replace(/-----END PRIVATE KEY-----/g, "")
                 .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
}

function _b64url(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function getApnsJwt(): Promise<string> {
  const now = Date.now();
  if (_apnsJwt && (now - _apnsJwtAt) < 55 * 60 * 1000) return _apnsJwt;
  const header = { alg: "ES256", kid: APNS_KEY_ID };
  const claims = { iss: APNS_TEAM_ID, iat: Math.floor(now / 1000) };
  const enc = new TextEncoder();
  const signingInput = _b64url(enc.encode(JSON.stringify(header))) + "." +
                       _b64url(enc.encode(JSON.stringify(claims)));
  const key = await _apnsImportKey(APNS_PRIVATE_KEY);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, enc.encode(signingInput),
  );
  _apnsJwt = signingInput + "." + _b64url(sig);
  _apnsJwtAt = now;
  return _apnsJwt;
}

// 🆕 2026.08: 배지(아이콘의 빨간 숫자) 제어
//   payload.badge  — 숫자를 그대로 쓴다. 0 이면 배지를 지운다. 없으면 1 (종전 동작).
//   payload.silent — 알림을 띄우지 않고 배지만 바꾼다 (background push).
//     배지는 알림센터와 별개라, 알림을 다 읽어도 아이콘의 숫자는 남는다.
//     앱이 열릴 때 0 으로 돌리는 게 정공법이지만(AppDelegate), 그건 새 빌드가
//     스토어에 올라가야 적용된다. 이미 「1」이 박힌 기기를 지금 정리하려면
//     서버가 badge:0 을 한 번 보내주는 길이 있어야 한다.
function _apsBadge(payload: any): number {
  return (typeof payload?.badge === "number" && payload.badge >= 0) ? payload.badge : 1;
}

async function sendApnsPush(deviceToken: string, payload: any) {
  try {
    const jwt = await getApnsJwt();
    const silent = payload?.silent === true;
    const body = silent
      ? {
          // 배지만 갱신 — alert/sound 를 넣지 않으면 화면에는 아무것도 뜨지 않는다.
          //
          // ⚠ content-available(=백그라운드 푸시)로 보내면 안 된다.
          //   그건 앱을 깨우는 푸시라 Info.plist 의 UIBackgroundModes 에
          //   remote-notification 이 있어야 하고, 없으면 iOS 가 조용히 버린다.
          //   Capacitor 기본 Info.plist 에는 없다 — 그래서 배지가 그대로였다.
          //   Apple 문서상 '배지만 바꾸는 알림' 의 push-type 은 alert 다.
          aps: { badge: _apsBadge(payload) },
        }
      : {
          aps: {
            alert: {
              title: String(payload?.title || "TAAM"),
              body: String(payload?.body || ""),
            },
            sound: "default",
            badge: _apsBadge(payload),
          },
          url: String(payload?.url || "/"),
          category: String(payload?.category || "system"),
          tag: String(payload?.tag || ("taam-" + Date.now())),
        };
    const res = await fetch(`https://${APNS_HOST}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        "authorization": "bearer " + jwt,
        "apns-topic": APNS_BUNDLE_ID,
        // 배지만 바꾸는 알림도 push-type 은 alert 다 (background 는 앱을 깨우는 푸시라 별개)
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    if (res.status >= 200 && res.status < 300) {
      return { ok: true, status: res.status };
    }
    const text = await res.text().catch(() => "");
    // 410 Unregistered / 400 BadDeviceToken = 죽은 토큰 — 지워야 다음부터 안 두들긴다
    const dead = res.status === 410 ||
      (res.status === 400 && /BadDeviceToken|DeviceTokenNotForTopic/i.test(text));
    return { ok: false, status: res.status, error: text.substring(0, 200), dead };
  } catch (e: any) {
    return { ok: false, status: 500, error: (e?.message || String(e)).substring(0, 200) };
  }
}

// access_token 1시간 유효 — 모듈 전역에 캐싱해서 재호출마다 토큰 발급 안 함
let _fcmAccessToken: string | null = null;
let _fcmAccessTokenExpiry = 0;
let _fcmProjectId: string | null = null;
let _fcmClientEmail: string | null = null;

function pemToArrayBuffer(pem: string): ArrayBuffer {
  // -----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY----- 형식 → bytes
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

async function signRs256Jwt(claims: Record<string, unknown>, privateKeyPem: string): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const headerB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const payloadB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify(claims)));
  const data = new TextEncoder().encode(headerB64 + "." + payloadB64);

  const keyData = pemToArrayBuffer(privateKeyPem);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, data);
  return headerB64 + "." + payloadB64 + "." + b64urlEncode(sig);
}

async function getFcmAccessToken(): Promise<string> {
  // 캐시된 토큰 재사용 (만료 60초 전까지)
  if (_fcmAccessToken && _fcmAccessTokenExpiry > Date.now()) {
    return _fcmAccessToken;
  }
  if (!FIREBASE_SERVICE_ACCOUNT_JSON) {
    throw new Error("FIREBASE_SERVICE_ACCOUNT 환경변수 미설정");
  }

  let sa: { client_email: string; private_key: string; project_id: string };
  try {
    sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
  } catch (e) {
    throw new Error("FIREBASE_SERVICE_ACCOUNT JSON 파싱 실패: " + (e as Error).message);
  }
  if (!sa.client_email || !sa.private_key || !sa.project_id) {
    throw new Error("Service Account JSON 필수 필드(client_email/private_key/project_id) 누락");
  }

  _fcmProjectId = sa.project_id;
  _fcmClientEmail = sa.client_email;

  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    exp: now + 3600,
    iat: now,
  };

  const jwt = await signRs256Jwt(claims, sa.private_key);

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error("Google OAuth2 토큰 요청 실패 (" + res.status + "): " + errText);
  }

  const data = await res.json();
  _fcmAccessToken = data.access_token as string;
  // expires_in 은 보통 3600초 — 60초 여유 두고 만료 설정
  _fcmAccessTokenExpiry = Date.now() + ((data.expires_in || 3600) - 60) * 1000;
  return _fcmAccessToken;
}

// ─────────────────────────────────────────────────────
// 메인 핸들러
// ─────────────────────────────────────────────────────
interface SendRequest {
  to: string;
  payload: Record<string, unknown>;
  dedupe?: boolean;
  exclude_user_id?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
    return json({ error: "VAPID keys not configured" }, 500);
  }

  try {
    const body: SendRequest = await req.json();
    if (!body || !body.to || !body.payload) {
      return json({ error: "Required: { to, payload }" }, 400);
    }

    // 호출자 user_id 추출
    let callerUserId: string | null = null;
    const authHeader = req.headers.get("Authorization") || "";
    if (authHeader.startsWith("Bearer ")) {
      try {
        const token = authHeader.substring(7);
        const userClient = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY") || "");
        const { data } = await userClient.auth.getUser(token);
        callerUserId = data?.user?.id || null;
      } catch (_) {}
    }

    // 대상 쿼리
    // 🆕 2026.08-30: lang — 이 기기가 쓰는 언어. 없으면 ko 로 본다
    const SEL = "id,endpoint,p256dh,auth,user_id,topics,role,lang";
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);
    const [scope, scopeValue] = body.to.includes(":") ? body.to.split(":") : [body.to, ""];

    let subs: any[] | null = null;
    let qErr: any = null;
    const pick: Record<string, unknown> = { scope, scopeValue };

    if (scope === "role" && scopeValue) {
      // 🔧 2026-08-27: 역할은 profiles(서버 진실)로 판정한다.
      //   push_subscriptions.role 은 구독을 저장한 '그 시점의 클라이언트 메모리'
      //   에서 온다 — 부팅 직후엔 아직 'user' 라 슈퍼어드민 기기가 'user' 로 덮이고,
      //   그 뒤 role: 푸시에서 조용히 빠진다. profiles 로도 잡으면 그래도 닿는다.
      //   앱 내부 문자열('superadmin')과 DB 값('super_admin') 차이도 흡수한다.
      //
      //   ⚠ 이걸 .or(`role.eq.X,user_id.in.("a","b")`) 한 방으로 짰다가 되돌렸다.
      //     PostgREST 의 or + in + 따옴표 조합은 파싱이 까다로워, 실패하면 쿼리
      //     전체가 500 으로 죽는다 — 그러면 이력만 남고 푸시는 통째로 안 나간다.
      //     두 번 나눠 조회해 코드에서 합친다. 느려도 깨지지 않는 쪽을 택한다.
      const roleAliases = (scopeValue === "superadmin" || scopeValue === "super_admin")
        ? ["superadmin", "super_admin"]
        : [scopeValue];

      const byRole = await sb.from("push_subscriptions").select(SEL).in("role", roleAliases);
      if (byRole.error) qErr = byRole.error;
      const merged = new Map<string, any>();
      for (const s of (byRole.data || [])) merged.set(s.id, s);
      pick.byRole = (byRole.data || []).length;

      let uids: string[] = [];
      try {
        const profs = await sb.from("profiles").select("id").in("role", roleAliases);
        uids = (profs.data || []).map((p: any) => p.id).filter(Boolean);
      } catch (_) { /* profiles 를 못 읽어도 role 필터 결과로는 보낸다 */ }
      pick.profileUsers = uids.length;

      if (uids.length) {
        const byUser = await sb.from("push_subscriptions").select(SEL).in("user_id", uids);
        if (byUser.error && !qErr) qErr = byUser.error;
        for (const s of (byUser.data || [])) merged.set(s.id, s);
        pick.byUser = (byUser.data || []).length;
      }
      subs = [...merged.values()];
      // 한쪽이라도 결과가 있으면 그것으로 보낸다 — 부분 실패로 전부 못 보내는 게 최악이다
      if (subs.length) qErr = null;
    } else {
      let query = sb.from("push_subscriptions").select(SEL);
      if (scope === "all") {
        // no filter
      } else if (scope === "uid" && scopeValue) {
        query = query.eq("user_id", scopeValue);
      } else if (scope === "topic" && scopeValue) {
        query = query.contains("topics", [scopeValue]);
      } else if (scope === "user" && callerUserId) {
        query = query.eq("user_id", callerUserId);
      } else {
        return json({ error: "Invalid 'to'", to: body.to }, 400);
      }
      const r = await query;
      subs = r.data; qErr = r.error;
    }

    if (qErr) return json({ error: "Query failed", detail: qErr.message, pick }, 500);

    let targets = subs || [];
    pick.matched = targets.length;

    // 제외 / dedupe
    const excludeUid = body.exclude_user_id || callerUserId;
    if ((scope === "all" || scope === "role" || scope === "topic") && excludeUid) {
      targets = targets.filter((s: any) => s.user_id !== excludeUid);
    }
    if (body.dedupe !== false) {
      const seen = new Set<string>();
      targets = targets.filter((s: any) => {
        if (seen.has(s.endpoint)) return false;
        seen.add(s.endpoint); return true;
      });
    }

    // 🆕 2026-08-27: 회원 알림 설정(profiles.notif_prefs)을 실제로 존중한다.
    //
    //   종전엔 이 설정이 기기 IDB 에만 있었고 서버는 보지 않았다 — 회원이 껐는데도
    //   푸시는 그대로 갔다(화면 토스트만 막혔다). 설정이 설정 노릇을 못 했다.
    //
    //   ⚠ 개인 알림(uid/user)에만 적용한다.
    //     role:/all:/topic: 은 운영·공지 경로다. 알림 설정 화면에 있는 항목들은
    //     전부 회원 대상 문구("찜한 레스토랑…", "티켓 구매 완료를…")라,
    //     그 토글로 슈퍼어드민의 운영 알림까지 끊으면 운영이 눈을 잃는다.
    //   ⚠ 표에 없는 카테고리는 보낸다. 설정은 '명시적으로 끈 것' 만 막는다.
    const PREF_KEY: Record<string, string> = {
      ticket_open: "fav",             // 찜한 레스토랑 티켓 오픈
      ticket: "ticket",
      ticket_purchased: "ticket",
      ticket_cancelled: "ticket",
      ticket_time_changed: "ticket",
      reservation_invite: "ticket",
      invite_paid: "ticket",
      charge: "charge",
      deposit_charged: "charge",
      deposit_grant: "charge",        // 예치금이 들어오는 건 = 충전 계열
      use: "use",
      refund: "refund",
      capacity_refund: "refund",
      card_refund_done: "refund",
      deposit_unreturned: "refund",
      remind7: "remind7",
      remind3: "remind3",
      remind1: "remind1",
    };
    const _cat = String((body.payload as any)?.category || "system");
    const _prefKey = PREF_KEY[_cat];
    if ((scope === "uid" || scope === "user") && _prefKey && targets.length) {
      try {
        const uids = [...new Set(targets.map((s: any) => s.user_id).filter(Boolean))];
        const { data: profs } = await sb
          .from("profiles").select("id,notif_prefs").in("id", uids);
        const blocked = new Set<string>();
        for (const p of (profs || []) as any[]) {
          const pref = p.notif_prefs || {};
          // 기본은 켜짐 — false 로 '명시적으로 끈' 경우에만 막는다
          if (pref.all === false || pref[_prefKey] === false) blocked.add(p.id);
        }
        if (blocked.size) {
          targets = targets.filter((s: any) => !blocked.has(s.user_id));
        }
      } catch (_) { /* 조회 실패 시엔 보낸다 — 못 받는 것보다 낫다 */ }
    }

    // ═══════════════════════════════════════════════════════════════
    // 🆕 2026.08-30: 받는 사람의 언어로 보낸다
    // ═══════════════════════════════════════════════════════════════
    //   종전에는 앱이 보낸 title/body 를 그대로 전달만 했다. 한 번의 호출이
    //   여러 기기로 가는데 문구가 하나뿐이라, 일본에 계신 회원도 한국어를 받았다.
    //   ⚠ 핸드폰의 OS 언어 설정으로는 바뀌지 않는다 — OS 언어는 OS 가 만든
    //     알림에만 적용된다. 우리가 고르지 않으면 아무도 안 골라준다.
    //
    //   payload.i18n = { ko:{title,body}, en:{...}, ja:{...} } 을 실어 보내면
    //   기기의 lang 으로 고른다. 없으면 payload.title/body 를 그대로 쓴다 —
    //   기존 호출부(16곳)를 한 줄도 안 고쳐도 지금처럼 돈다.
    //
    //   고를 수 없으면 ko 로 떨어뜨린다. 빈 알림을 보내느니 한국어가 낫다.
    function pickLang(sub: any): string {
      const raw = String(sub?.lang || "").toLowerCase();
      if (raw.startsWith("ja")) return "ja";
      if (raw.startsWith("en")) return "en";
      return "ko";
    }
    function payloadFor(sub: any) {
      const p: any = body.payload;
      const i18n = p && p.i18n;
      if (!i18n || typeof i18n !== "object") return p;
      const lang = pickLang(sub);
      const t = i18n[lang] || i18n.ko || i18n.en || i18n.ja;
      if (!t) return p;
      // i18n 은 문구만 갈아끼운다. url·category·tag·badge 는 언어와 무관하다
      return Object.assign({}, p, {
        title: t.title != null ? t.title : p.title,
        body:  t.body  != null ? t.body  : p.body,
      });
    }

    const payloadStr = JSON.stringify(body.payload);

    // 🆕 FCM HTTP v1 API (OAuth2 + Service Account JSON 방식)
    //   Legacy FCM_SERVER_KEY 는 2024-06 Google이 폐기 — 더 이상 동작 X
    //   환경변수 FIREBASE_SERVICE_ACCOUNT 에 비공개 키 JSON 전체를 string으로 저장
    //
    //   - Android: fcm://<token> 엔드포인트 → 즉시 발송
    //   - iOS:     apns://<token> 엔드포인트 → 동일 FCM v1 통해 발송 (Firebase가 APNs 게이트웨이)
    async function sendNativePush(endpoint: string, payload: any) {
      const token = endpoint.replace(/^(fcm|apns):\/\//, "");
      if (!FIREBASE_SERVICE_ACCOUNT_JSON) {
        return { ok: false, status: 500, error: "FIREBASE_SERVICE_ACCOUNT 미설정 (Supabase Secrets)" };
      }
      try {
        const accessToken = await getFcmAccessToken();
        const projectId = _fcmProjectId;
        if (!projectId) {
          return { ok: false, status: 500, error: "project_id 추출 실패 — Service Account JSON 확인" };
        }

        // 🆕 2026.08: 조용한 배지 갱신은 FCM 경로로 보내지 않는다.
        //   FCM v1 의 notification 블록은 화면에 알림을 띄운다 — "배지만 지우려다
        //   빈 알림이 뜨는" 결과가 된다. APNs 직결(APNS_READY)일 때만 지원한다.
        if (payload?.silent === true) {
          return {
            ok: false, status: 400,
            error: "silent 배지 갱신은 APNs 직결에서만 지원 (APNS_* 시크릿 확인)",
          };
        }

        // FCM v1 메시지 페이로드
        // data 필드는 모든 값을 string 으로 강제 (FCM v1 명세)
        const msgBody = {
          message: {
            token,
            notification: {
              title: String(payload.title || "TAAM"),
              body: String(payload.body || ""),
            },
            data: {
              url: String(payload.url || "/"),
              category: String(payload.category || "system"),
              tag: String(payload.tag || ("taam-" + Date.now())),
            },
            android: {
              priority: "high",
              notification: {
                // 🆕 2026-08-28: tag 를 '합침 키' 로 쓴다.
                //   같은 tag 의 알림은 새 것이 옛 것을 대체한다. 종전엔 tag 를
                //   data 로만 실어 보내서 실제 합침이 안 됐고, 같은 사건에 대한
                //   알림이 폰에 3건씩 쌓였다(초대 취소 1건 → 화면에 3건).
                tag: String(payload.tag || ("taam-" + Date.now())),
                // 상태바 아이콘 배경 — 브랜드색. 회색 원으로 보이던 것을 살린다.
                color: "#5C0A14",
                // 🆕 2026-08-28: 채널 지정. Android 8+ 는 채널 없이는 알림을 '표시하지'
                //   않는다. FCM 은 200 OK 를 주고 요약도 「시도 1 · 성공 1」 이 되는데
                //   폰에는 아무것도 안 뜬다 — 배달과 표시는 다른 단계다.
                //   앱이 setupNativePush 에서 만드는 채널 id 와 반드시 같아야 한다.
                channel_id: "taam_default",
                // 알림 클릭 시 앱에서 이 click_action 수신 → URL 이동 처리
                click_action: "OPEN_TAAM",
              },
            },
            apns: {
              headers: {
                "apns-priority": "10",
                // 같은 collapse-id 는 iOS 가 하나로 합친다 (Android tag 와 같은 역할)
                "apns-collapse-id": String(payload.tag || "").slice(0, 64),
              },
              payload: {
                aps: {
                  alert: {
                    title: String(payload.title || "TAAM"),
                    body: String(payload.body || ""),
                  },
                  sound: "default",
                  badge: _apsBadge(payload),   // 🆕 payload.badge 존중 (0 = 배지 지움)
                },
              },
            },
          },
        };

        const res = await fetch(
          `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
          {
            method: "POST",
            headers: {
              "Authorization": "Bearer " + accessToken,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(msgBody),
          },
        );

        const text = await res.text();

        // 만료/무효 토큰 자동 정리
        // 🔧 2026-08-27: 404/410 만 지우고 있었다. FCM v1 은 죽은 토큰을 그것만으로
        //   알려주지 않는다 — 다른 Firebase 프로젝트 토큰, 스킴이 틀어져 저장된
        //   APNs 토큰(fcm://+APNs), 앱 삭제 후 토큰은 400 INVALID_ARGUMENT 로 온다.
        //   그래서 죽은 구독이 영원히 남아 매번 실패했다. 실제로 한 테스트 계정에
        //   5월부터 쌓인 안드로이드 구독이 11건 있었고, 발송 요약의 '실패' 대부분이
        //   그것이었다. 실패 수가 부풀면 진짜 실패를 못 알아본다.
        const _dead = res.status === 404 || res.status === 410 ||
          (res.status === 400 && /INVALID_ARGUMENT|not a valid FCM registration token|Invalid registration/i.test(text)) ||
          /UNREGISTERED|NOT_FOUND|SenderId mismatch|MismatchSenderId/i.test(text);
        if (_dead) {
          try { await sb.from("push_subscriptions").delete().eq("endpoint", endpoint); } catch (_) {}
          return { ok: false, status: res.status, removed: true, reason: "expired", body: text.substring(0, 200) };
        }

        return { ok: res.ok, status: res.status, body: text.substring(0, 300) };
      } catch (e: any) {
        return { ok: false, status: 500, error: e?.message || String(e) };
      }
    }

    // 발송 (Web Push / FCM / APNs 분기)
    const results = await Promise.all(targets.map(async (s: any) => {
      try {
        // 🆕 2026-08: iOS(apns://)는 APNs 로 곧장 보낸다.
        //   FCM 으로 보내면 APNs 기기토큰을 FCM 등록토큰으로 착각해 무조건 거부된다.
        //   APNS 시크릿이 없으면 종전 FCM 경로로 폴백 — 설정 전에도 앱은 그대로 돈다.
        if (s.endpoint.startsWith("apns://") && APNS_READY) {
          const ar = await sendApnsPush(s.endpoint.replace(/^apns:\/\//, ""), payloadFor(s));
          if (ar.ok) return { id: s.id, ok: true, status: ar.status, apns: true };
          if ((ar as any).dead) {
            await sb.from("push_subscriptions").delete().eq("id", s.id);
            return { id: s.id, ok: false, removed: true, status: ar.status, reason: "expired", apns: true };
          }
          return { id: s.id, ok: false, status: ar.status, error: (ar.error || "").substring(0, 200), apns: true };
        }

        // 🆕 Native 토큰이면 FCM v1 사용 (Android FCM · APNs 폴백)
        const isNative = s.endpoint.startsWith("fcm://") || s.endpoint.startsWith("apns://");
        if (isNative) {
          const nr = await sendNativePush(s.endpoint, payloadFor(s));
          if (nr.ok) return { id: s.id, ok: true, status: nr.status, native: true };
          // 만료/무효 토큰은 sendNativePush 안에서 이미 push_subscriptions 에서 삭제됨
          if ((nr as any).removed) {
            return { id: s.id, ok: false, removed: true, status: nr.status, reason: "expired", native: true };
          }
          return { id: s.id, ok: false, status: nr.status, error: (nr.error || nr.body || "").substring(0, 200), native: true };
        }

        // Web Push (기존)
        // 웹푸시는 문자열을 통째로 실어 보낸다. 기기 언어가 다르면 그 기기 것만 다시 만든다
        const _ps = (body.payload as any)?.i18n ? JSON.stringify(payloadFor(s)) : payloadStr;
        const r = await sendWebPush(s.endpoint, s.p256dh, s.auth, _ps);
        if (r.status >= 200 && r.status < 300) {
          return { id: s.id, ok: true, status: r.status };
        }
        if (r.status === 410 || r.status === 404) {
          await sb.from("push_subscriptions").delete().eq("id", s.id);
          return { id: s.id, ok: false, removed: true, status: r.status, reason: "expired" };
        }
        return { id: s.id, ok: false, status: r.status, error: r.body.substring(0, 200) };
      } catch (e: any) {
        return { id: s.id, ok: false, error: (e?.message || String(e)).substring(0, 300) };
      }
    }));

    const summary = {
      attempted: targets.length,
      ok: results.filter(r => r.ok).length,
      failed: results.filter(r => !r.ok).length,
      removed: results.filter(r => (r as any).removed).length,
    };

    // 🆕 2026-08-27: pick 을 같이 돌려준다.
    //   'attempted 0' 만 보면 구독이 없는 건지, 스코프 판정이 어긋난 건지,
    //   설정으로 걸러진 건지 구분할 수 없다. 어디서 0 이 됐는지 남긴다.
    console.log("[send-push]", body.to, JSON.stringify(pick), JSON.stringify(summary));
    return json({ ok: true, summary, pick, details: results }, 200);
  } catch (e) {
    console.error("[send-push] error:", e);
    return json({ error: String(e) }, 500);
  }
});

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
