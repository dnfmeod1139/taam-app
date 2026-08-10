// Apple Sign In client secret (JWT) 생성기 — 로컬 전용, 커밋 금지 대상 아님(스크립트만).
// 사용: node scripts/gen-apple-secret.js <p8경로> <TeamID> <KeyID> <ServicesID>
const crypto = require('crypto');
const fs = require('fs');
const [, , p8path, teamId, keyId, servicesId] = process.argv;
if (!p8path || !teamId || !keyId || !servicesId) {
  console.error('사용법: node gen-apple-secret.js <p8path> <TeamID> <KeyID> <ServicesID>');
  process.exit(1);
}
const key = fs.readFileSync(p8path, 'utf8');
const now = Math.floor(Date.now() / 1000);
const header = { alg: 'ES256', kid: keyId };
const payload = {
  iss: teamId,
  iat: now,
  exp: now + 15552000, // 180일 (Apple 최대 6개월)
  aud: 'https://appleid.apple.com',
  sub: servicesId
};
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const signingInput = b64(header) + '.' + b64(payload);
const sig = crypto.sign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
console.log('\n===== Apple Client Secret (JWT) — Supabase "Secret Key (for OAuth)"에 붙여넣기 =====\n');
console.log(signingInput + '.' + sig);
console.log('\n(만료: 180일 후. 갱신 필요 시 재실행)\n');
