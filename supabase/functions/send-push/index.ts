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
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);
    let query = sb.from("push_subscriptions").select("id,endpoint,p256dh,auth,user_id,topics,role");
    const [scope, scopeValue] = body.to.includes(":") ? body.to.split(":") : [body.to, ""];

    if (scope === "all") {
      // no filter
    } else if (scope === "uid" && scopeValue) {
      query = query.eq("user_id", scopeValue);
    } else if (scope === "role" && scopeValue) {
      query = query.eq("role", scopeValue);
    } else if (scope === "topic" && scopeValue) {
      query = query.contains("topics", [scopeValue]);
    } else if (scope === "user" && callerUserId) {
      query = query.eq("user_id", callerUserId);
    } else {
      return json({ error: "Invalid 'to'", to: body.to }, 400);
    }

    const { data: subs, error: qErr } = await query;
    if (qErr) return json({ error: "Query failed", detail: qErr.message }, 500);

    let targets = subs || [];

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
                // 알림 클릭 시 앱에서 이 click_action 수신 → URL 이동 처리
                click_action: "OPEN_TAAM",
              },
            },
            apns: {
              headers: { "apns-priority": "10" },
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

        // 만료/무효 토큰 (UNREGISTERED / INVALID_ARGUMENT 등) 자동 정리
        if (res.status === 404 || res.status === 410) {
          try { await sb.from("push_subscriptions").delete().eq("endpoint", endpoint); } catch (_) {}
          return { ok: false, status: res.status, removed: true, reason: "expired", body: text.substring(0, 200) };
        }

        return { ok: res.ok, status: res.status, body: text };
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
          const ar = await sendApnsPush(s.endpoint.replace(/^apns:\/\//, ""), body.payload);
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
          const nr = await sendNativePush(s.endpoint, body.payload);
          if (nr.ok) return { id: s.id, ok: true, status: nr.status, native: true };
          // 만료/무효 토큰은 sendNativePush 안에서 이미 push_subscriptions 에서 삭제됨
          if ((nr as any).removed) {
            return { id: s.id, ok: false, removed: true, status: nr.status, reason: "expired", native: true };
          }
          return { id: s.id, ok: false, status: nr.status, error: (nr.error || nr.body || "").substring(0, 200), native: true };
        }

        // Web Push (기존)
        const r = await sendWebPush(s.endpoint, s.p256dh, s.auth, payloadStr);
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

    return json({ ok: true, summary, details: results }, 200);
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
