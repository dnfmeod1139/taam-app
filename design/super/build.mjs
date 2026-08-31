// TAAM 관리자 시안 — 조각(.body.html) + 공용 CSS → 아트보드(.dc.html)
//   .dc.html 끼리는 런타임을 공유하지 않으므로 스타일을 파일마다 넣어야 한다.
//   손으로 아홉 번 복사하는 대신 여기서 한 번에 끼워 넣는다.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(dir, '_shared.css'), 'utf8');
const FONTS = 'https://fonts.googleapis.com/css2?family=Oswald:wght@300;400;500;600;700'
            + '&family=Noto+Sans+KR:wght@400;500;700;900&family=Montserrat:wght@700;800&display=swap';

const bodies = readdirSync(dir).filter((f) => f.endsWith('.body.html')).sort();
for (const f of bodies) {
  const name = f.replace('.body.html', '');
  const body = readFileSync(join(dir, f), 'utf8').trim();
  const out = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <link rel="stylesheet" href="${FONTS}">
  <style>
${css.trim()}
  </style>
</helmet>
${body}
</x-dc>
</body>
</html>
`;
  writeFileSync(join(dir, `${name}.dc.html`), out);
  console.log('built', `${name}.dc.html`, `${(out.length / 1024).toFixed(1)}kB`);
}
