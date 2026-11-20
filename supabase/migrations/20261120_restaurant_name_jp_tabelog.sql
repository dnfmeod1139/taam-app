-- ============================================================================
-- 20261120_restaurant_name_jp_tabelog.sql — 레스토랑 일본어 이름을 타베로그 표기로 (2026-11-20)
-- ============================================================================
-- 왜: 일본어 화면에 스시 이코우가 「鮨 以降」로 떴다(타베로그 「鮨 一幸」). restaurants.name_jp 가 자동 번역으로
--   채워져 발음만 보고 한자를 지어낸 줄이 많았다(Ishikawa 「石川」 → 「神楽坂 石かわ」 · Mitaka 「三鷹」 → 「味享」 …).
--   운영 지시(2026-11-20): 「타베로그랑 대조해서 맞춰」.
-- 근거: 타베로그 주소가 등록된 196곳을 타베로그 일본어판 페이지 제목(「店名 - 駅/ジャンル [食べログ]」 · 같은 매장 번호의
--   결과만)으로 대조 — 같음 86 · 다름 110. 다른 110곳은 앞 결과를 모르는 채 한 번 더 찾아 전부 같은 답이 나온 것만 넣었다.
--   주소가 없던 매장 3곳(鮨 陸 · 鮨むん · 食堂 aca)은 타베로그 페이지를 찾아 확인한 것.
-- 무엇: ① name_jp 113곳을 타베로그 표기 그대로(띄어쓰기 · 로마자 표기 포함)  ② name_local(현지 이름) 89곳도 같은 표기로
--   (name_local 이 같은 틀린 값을 담고 있었다). 다른 칸(한국어 이름 · 영문 이름 · 번역 상태)은 건드리지 않는다.
-- 안전: **지금 값이 아래 「옛 값」 그대로인 줄만** 바꾼다 — 그 사이 어드민이 손으로 고친 이름은 덮지 않는다(④ 에 건수만).
--   여러 번 돌려도 같다. 옛 값·새 값은 public._taam_name_fix_20261120 에 남는다(RLS 켬 · 정책 없음 — 슈퍼어드민도 앱에서는 못 읽는다).
-- 되돌리기(SQL Editor): update public.restaurants r set name_jp = f.old_jp from public._taam_name_fix_20261120 f
--                        where r.id = f.id and f.new_jp is not null and r.name_jp = f.new_jp;   -- name_local 도 같은 모양으로
-- ============================================================================
create table if not exists public._taam_name_fix_20261120 (
  id         uuid primary key,
  old_jp     text,
  new_jp     text,          -- null = name_jp 는 안 바꾼다
  old_local  text,
  new_local  text,          -- null = name_local 은 안 바꾼다
  applied_at timestamptz
);
alter table public._taam_name_fix_20261120 enable row level security;
revoke all on public._taam_name_fix_20261120 from public, anon, authenticated;

insert into public._taam_name_fix_20261120 (id, old_jp, new_jp, old_local, new_local) values
  ('0409067a-da85-4824-a365-f30151b9a4bd', '恵比寿 よろにく', '蕃 YORONIKU', '恵比寿 よろにく', '蕃 YORONIKU'),
  ('067d7824-9f69-4f42-964e-05525d54167e', '古田', 'フルタ', '古田', 'フルタ'),
  ('06d1b451-57a4-4127-b523-1307a5fcfe06', 'グチーテ', 'グシテ', 'グチーテ', 'グシテ'),
  ('07057212-b711-43b5-947c-0ffeb8daeea6', '中華 大重', '中華 大しげ', '中華 大重', '中華 大しげ'),
  ('082f5e83-4239-4d6f-9b7f-f896403724cc', '余市 サグラ', '余市SAGRA', '余市 サグラ', '余市SAGRA'),
  ('097efbe5-66d5-4f8d-a8a9-36003669b887', '食堂aca', '食堂 aca', null, '食堂 aca'),
  ('09f189c9-29fc-49b0-89a5-64f9d44ad57a', 'おがわ', '食堂 おがわ', 'おがわ', '食堂 おがわ'),
  ('0f86b78f-2d31-4ef8-878c-a492f1ff9ba6', 'たき屋', 'たきや', null, null),
  ('10c71f39-5ba4-433a-a954-1fcd0394b22d', 'ラ カーザ トム クリオーザ', 'トムクリオーザ', 'ラ カーザ トム クリオーザ', 'トムクリオーザ'),
  ('137d2459-04e8-425b-9be6-42c1e1afaa1e', null, null, null, 'ひき田'),
  ('1492ccfa-61ad-42a2-8189-4893e1ac7d1e', 'めぐみ', 'すし処 めくみ', null, null),
  ('157149df-77b5-4cce-a80d-ee3b73927b9a', '友栄', 'うなぎ亭 友栄', '友栄', 'うなぎ亭 友栄'),
  ('1632d24a-be5e-4427-a367-2f8c5993d628', '山麓', 'ろばたやき山ろく', '山麓', 'ろばたやき山ろく'),
  ('1b13ecb1-562d-4479-91b7-526b5b797fae', '馳走 啐啄一', '馳走 啐啄一十', '馳走 啐啄一', '馳走 啐啄一十'),
  ('1cb21841-d9bd-4040-aa54-40e3216026d4', '山岸', '富小路 やま岸', '山岸', '富小路 やま岸'),
  ('2015f33c-3b86-40bb-a912-dc146e164ef2', '銀座しのはら', '銀座 しのはら', null, null),
  ('21be68dc-9637-46d8-b455-e3c36a5d53f5', '北野坂 キノシタ', '北野坂 木下', null, null),
  ('22d8609a-b205-4ecb-a8ce-020b10145134', '仁紫楼', '仁修樓', null, null),
  ('2705d949-3829-4ea3-9aca-15fbed019fb0', 'なんば 日比谷', '鮨 なんば 日比谷', null, null),
  ('272d517d-56f5-4402-a09a-41b6e9cfd242', 'NÖMI', 'NOMI RESTAURANT', 'NÖMI', 'NOMI RESTAURANT'),
  ('29d28ee3-90ef-49d8-99cf-72f8ef6dde86', '焼肉 光泉', '焼肉幸泉', '焼肉 光泉', '焼肉幸泉'),
  ('2b4df66e-af1c-4496-a197-09387ae7f74c', '松山', '御料理 まつ山', '松山', '御料理 まつ山'),
  ('2cd6aaf6-591a-4695-a93e-84346a5a7f35', 'ゆき元', '柚木元', null, null),
  ('2da4cf17-8370-4e47-ab8c-964076d55e82', 'タクボ', 'TACUBO', 'タクボ', 'TACUBO'),
  ('2f7db8bf-d5ca-41d5-9573-223390e841de', 'ワサ', 'わさ', 'ワサ', 'わさ'),
  ('2ff98058-ea92-4d1d-8684-ecbf598c524f', '味処', '味道広路', '味処', '味道広路'),
  ('30480948-bdcf-488d-9c25-49f24c1c44a3', 'よろにく 麻布台ヒルズ', 'YORONIKU TOKYO AZABUDAIHILLS', 'よろにく 麻布台ヒルズ', 'YORONIKU TOKYO AZABUDAIHILLS'),
  ('331813d9-b32f-46b1-8920-8d8bb231ecaa', 'オオイシ', '銀座 大石', 'オオイシ', '銀座 大石'),
  ('38bff51c-a32c-4653-a540-8611e27d02b7', '鮨 むーん', '鮨むん', null, '鮨むん'),
  ('3c942ac1-6b08-43e0-a28e-2189ceae7ab7', '鮨 以降', '鮨 一幸', null, null),
  ('3ca2792b-31b4-499c-ab67-c589b5839adb', '魚政', 'うなぎ 魚政', '魚政', 'うなぎ 魚政'),
  ('3cabd4bf-04ef-4665-bd07-ea4889145b51', '山崎', '山﨑', '山崎', '山﨑'),
  ('3cac37d5-9b9c-4f20-803a-8c6ff1fa944b', '浅谷', '参宮橋 あさや', '浅谷', '参宮橋 あさや'),
  ('4403a072-1aff-438b-95e7-1cc2a419c9ac', 'ナリサワ', 'NARISAWA', 'ナリサワ', 'NARISAWA'),
  ('4599bab3-1660-4761-a390-b2dc49401592', 'グゥ', '中国菜 Guu', 'グゥ', '中国菜 Guu'),
  ('464868ed-7605-4875-9aa0-1a5187f00120', 'らぁ麺屋 飯田商店', '飯田商店', 'らぁ麺屋 飯田商店', '飯田商店'),
  ('48fba906-3361-4adf-8e49-3dda6f96a090', 'チウネ', 'CHIUnE', 'チウネ', 'CHIUnE'),
  ('4936870b-c6ce-4ed4-a108-874d9e329c47', 'そのじ', '日本橋 蕎ノ字', null, null),
  ('496d430c-6331-488c-a3a9-61d77a2234bd', '鷹匠 寿', '鷹匠壽', '鷹匠 寿', '鷹匠壽'),
  ('4a147976-59bc-434d-a266-2f71e9acbf62', 'あぼん', '串かつ あーぼん', 'あぼん', '串かつ あーぼん'),
  ('4ebcecc9-415a-4314-91c1-85e867764702', '弘澤', '廣澤', '弘澤', '廣澤'),
  ('550ec03e-70f1-4f72-bed6-9a4c2800034d', 'アカイ', 'AKAI', 'アカイ', 'AKAI'),
  ('585e1ffb-8fac-4a24-92e4-aa53c1228bae', '西崎', '鮨 西崎', null, null),
  ('58ecdc63-20e9-4313-b4be-f5ff388e8b80', '天ぷら 浅沼', '天ぷら浅沼', null, null),
  ('591c1cd2-4681-4f94-9495-5f0d9d94a613', '真善美', '眞善美', '真善美', '眞善美'),
  ('5a67b7ff-ea2b-4d67-b679-56ed8ebf797a', '彩華', '齋華', '彩華', '齋華'),
  ('5b6a682c-81e4-404f-9054-0aab85dfa2d0', 'YODA', '揚雫', 'YODA', '揚雫'),
  ('5c18f189-49d3-477b-b8bb-e3ca1904bf0b', '比山', '樋山', '比山', '樋山'),
  ('625e2430-c159-4fd3-b21b-e9598aac9076', 'とし', '隼', 'とし', '隼'),
  ('6589e4b9-262f-4975-855f-15cb02f56401', '新宅', '割烹 新多久', '新宅', '割烹 新多久'),
  ('67986055-0f2e-4d13-bea0-8f5d2e7a4d80', 'エテ', 'ete', 'エテ', 'ete'),
  ('6db3ca30-1588-4c46-a469-243a9a9f2815', 'ふじ居', '御料理ふじ居', 'ふじ居', '御料理ふじ居'),
  ('7284ab90-8c92-4aed-9ab6-7404db0ab577', '木本', '紀茂登', '木本', '紀茂登'),
  ('72ee59a1-699a-436f-aa26-a04dc59fc26f', '橦木町 清水', '橦木町 しみず', null, null),
  ('736134d6-b3cf-470a-84e1-379056722f67', '鮨 さん心', '鮨 三心', null, null),
  ('7481ee59-6351-45f5-94eb-a85796f7fbf6', 'ボンニュ', 'ボニュ', 'ボンニュ', 'ボニュ'),
  ('7786e66f-76d4-4829-ad7f-90fd91faff57', 'たかむら', '日本料理 たかむら', 'たかむら', '日本料理 たかむら'),
  ('7a34f4b7-1d2d-4255-96a2-9768f7cf1256', 'レストランウオゼン', 'レストラン ウオゼン', 'レストランウオゼン', 'レストラン ウオゼン'),
  ('7e93047a-cbcf-40fa-9a2a-63a9a8606708', 'おぎ乃', '赤坂おぎ乃', 'おぎ乃', '赤坂おぎ乃'),
  ('81db13e2-b5ea-49a3-b206-2602f3583213', '炭火焼肉ホルモン さわいし', '炭火焼肉ホルモンさわいし', '炭火焼肉ホルモン さわいし', '炭火焼肉ホルモンさわいし'),
  ('820e6a9a-1159-43a5-b98c-851d15dade09', 'ペシコ', 'pesceco', 'ペシコ', 'pesceco'),
  ('837b80a4-9397-4566-ba86-fcf3f995c3ba', '西渕飯店', 'にしぶち飯店', '西渕飯店', 'にしぶち飯店'),
  ('84917b1c-9b71-4f1c-ac7a-b8a442790d9c', '新橋 星野', '新ばし 星野', null, null),
  ('8d4c5764-1afd-49df-9800-160880c8e959', 'ビア', '美会', 'ビア', '美会'),
  ('91c60e14-7f91-4879-b1d9-3a4590a2f97a', 'カテ クオーレ', 'katecuore', 'カテ クオーレ', 'katecuore'),
  ('92a31e08-0b0e-4b7c-9c3f-86500d504637', '巻鶏 神戸', '薪鳥新神戸', '巻鶏 神戸', '薪鳥新神戸'),
  ('92a41b9b-3b92-4165-8f37-52558fd7e720', 'ヤマグチ', 'やまぐち', 'ヤマグチ', 'やまぐち'),
  ('944c6f6c-e320-411b-8564-985853f87215', 'アキナガオ', 'AKI NAGAO', 'アキナガオ', 'AKI NAGAO'),
  ('9a2de049-dd93-40ac-8a0a-29fe7a1b3d84', null, null, null, '竹屋町 三多'),
  ('9a2e7264-b46b-422e-b91d-c9698a00f76b', 'セザン', 'SEZANNE', 'セザン', 'SEZANNE'),
  ('9cb608a0-0547-4840-afa1-6ebee98181fd', '笠原', 'かさ原', null, null),
  ('9d881ca4-fca1-4a9a-9c06-281a97bcea65', 'オトワレストラン', 'オトワ レストラン', 'オトワレストラン', 'オトワ レストラン'),
  ('9ee8bb24-5ae0-4782-a67c-413ea4d4af25', 'ハギフレンチ', 'HAGI', 'ハギフレンチ', 'HAGI'),
  ('a0038ec7-8d50-40e9-9bd4-fc72a40d002d', 'フォリオリーナ・デラ・ポルタフォルトゥーナ', 'フォリオリーナ・デッラ・ポルタ・フォルトゥーナ', 'フォリオリーナ・デラ・ポルタフォルトゥーナ', 'フォリオリーナ・デッラ・ポルタ・フォルトゥーナ'),
  ('a290b46a-3a2a-40cc-ac15-138bde3a0ac0', '龍二郎', '鮨 龍次郎', null, null),
  ('a353d295-64ce-4d6e-8531-6fab6800917c', '馳走 西健一郎', '馳走西健一', null, null),
  ('a4a7c0ef-d261-4fd4-a91f-acae0fc02373', '三田', '竹屋町 三多', '三田', '竹屋町 三多'),
  ('a6bf2923-95e9-4e79-a7b6-14b5f1cf62bc', '石川', '神楽坂 石かわ', '石川', '神楽坂 石かわ'),
  ('a81e9334-fc22-4a34-869b-2eadce8f57ab', '廣門', '日本料理 別府 廣門', '廣門', '日本料理 別府 廣門'),
  ('ac330831-f6d2-4566-8c83-a2396fbaf90a', '北島', '鎌倉 北じま', '北島', '鎌倉 北じま'),
  ('ac35bbb7-c935-47d1-805e-f61ede8d3dce', '鮨 りく', '鮨 陸', null, '鮨 陸'),
  ('ad8fb60c-f2ee-46f0-b095-865e9211878b', '茶太呂', 'とり茶太郎', '茶太呂', 'とり茶太郎'),
  ('b2c0f102-c489-4e51-949f-c8319f40b85e', '青林', '勢麟', '青林', '勢麟'),
  ('b3053b13-7b28-412a-a0c0-11274d02c96d', 'さかい', '鮨 さかい', null, null),
  ('b8827192-2c5f-49c0-b387-7c188692cea0', '飛梅', '日本料理 TOBIUME', '飛梅', '日本料理 TOBIUME'),
  ('baa95a2a-513b-4c99-a7c2-624e9717ebf6', null, null, null, '鮨こばやし'),
  ('c0a4cd14-762c-4857-85f6-c20ab874cd9d', '鮨 栄', '寿司栄', null, null),
  ('c17af52c-5e7b-401d-a539-971e99d21373', 'アキラ', 'すし 良月', null, null),
  ('c3029219-9d4f-467d-a277-36a264beb1a0', '旬', '瞬', null, null),
  ('c467fb3c-fe88-4d07-9818-9272e5610789', '草卓 塚本', '啐啄 つか本', null, null),
  ('c8b6b714-da4b-42a9-a6cd-0ab6ca0d4c2b', '晴山', '日本料理 晴山', '晴山', '日本料理 晴山'),
  ('c97597fc-6a79-4d4b-ba0b-65c86798073c', '成瀬', '成生', null, null),
  ('ca15d82f-fe2c-4f1b-8053-9b6cd4196293', '大草', 'オオクサ', '大草', 'オオクサ'),
  ('cb68d385-4c6e-4f2c-8a32-4a0452a28c5d', '一凛 離れ', 'イチリン ハナレ', '一凛 離れ', 'イチリン ハナレ'),
  ('cc4656e4-da90-433a-907f-c44a19f7e413', '赤坂 雷門', '赤坂 らいもん', null, null),
  ('cd846ecf-f62a-40b9-ae34-cc0b7c7db2cb', '肉屋 田中 銀座', '肉屋 田中', '肉屋 田中 銀座', '肉屋 田中'),
  ('cf0eee61-1915-4f3c-b5a2-c2c1547d2de3', '三鷹', '味享', '三鷹', '味享'),
  ('cfa9d6a0-4ea6-4618-8e18-9b9b4b0dba34', '田中 義英', '田中圭英', '田中 義英', '田中圭英'),
  ('d42aab43-18f3-435d-87d4-d786c2263d90', 'トレス', 'トレイス', 'トレス', 'トレイス'),
  ('d4e944a6-e3a1-450b-83f1-3ffd12a42867', 'うらん', 'う嵐', 'うらん', 'う嵐'),
  ('d5b248fc-f1b4-4b8f-8193-df8b506bec7e', 'スガラボ', 'SUGALABO', 'スガラボ', 'SUGALABO'),
  ('d9542a9d-442e-4182-ba74-5febb09025c4', 'ジーキューブ', 'Ji-Cube', 'ジーキューブ', 'Ji-Cube'),
  ('e4521929-c901-47b2-b7d6-637e68ccf4bd', '津志見', 'TSUSHIMI', '津志見', 'TSUSHIMI'),
  ('e93d977b-c367-4205-b864-a3196d3f5349', '季雨', 'きう', null, null),
  ('ea87b2b4-4194-4f66-bc66-90038df49984', '蒔村', 'まき村', '蒔村', 'まき村'),
  ('eb81f731-417d-4a55-b9db-2a1ea252afb4', '沢田', '澤田', '沢田', '澤田'),
  ('ebfc4e69-5eee-4717-9e11-16b4cc283525', 'ふじ', '日本料理FUJI', 'ふじ', '日本料理FUJI'),
  ('ed32c76b-d0d3-4adc-baad-81247050f7b3', 'いそだ', '礒田', 'いそだ', '礒田'),
  ('ed49f38a-30cd-45b6-9a43-aa72ef331185', '車寿司', 'くるますし', '車寿司', 'くるますし'),
  ('ef532cc4-4275-49f2-a0f9-dee86c8dcf5f', 'ラ ターブル ドゥ ジョエル・ロブション', 'ガストロノミー ジョエル・ロブション', 'ラ ターブル ドゥ ジョエル・ロブション', 'ガストロノミー ジョエル・ロブション'),
  ('f06db812-ac96-4dbf-b9ec-649a673c6f2d', '川口', '料理 川口', '川口', '料理 川口'),
  ('f5022b6f-51cd-4484-864b-3856b7063c3e', '肉の匠 みよし', 'にくの匠 三芳', '肉の匠 みよし', 'にくの匠 三芳'),
  ('f9493bd2-4059-4770-8e52-a7ae2908b75a', '小俣', 'こま田', null, null),
  ('fac7b986-2a92-47e6-8ee5-53dfe89519ca', '北川', '私房菜 きた川', '北川', '私房菜 きた川'),
  ('fbf6b477-eb92-4732-bdb4-cb0e35f05ae6', '富麗華', '中国飯店 富麗華', '富麗華', '中国飯店 富麗華'),
  ('fd0241fb-204e-4b51-a5d5-0acf64d9dbab', '宮川', 'すし宮川', null, null)
on conflict (id) do nothing;

update public.restaurants r
   set name_jp = f.new_jp, updated_at = now()
  from public._taam_name_fix_20261120 f
 where r.id = f.id and f.new_jp is not null
   and r.name_jp is not distinct from f.old_jp;

update public.restaurants r
   set name_local = f.new_local, updated_at = now()
  from public._taam_name_fix_20261120 f
 where r.id = f.id and f.new_local is not null
   and r.name_local is not distinct from f.old_local;

update public._taam_name_fix_20261120 set applied_at = now() where applied_at is null;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 · ⚠ 는 정보 ──
select '① 일본어 이름(name_jp) — 타베로그 표기가 된 매장' as what,
       (select count(*) from public._taam_name_fix_20261120 f join public.restaurants r on r.id = f.id
         where f.new_jp is not null and r.name_jp = f.new_jp)::text
       || ' / ' || (select count(*) from public._taam_name_fix_20261120 where new_jp is not null)::text
       || case when (select count(*) from public._taam_name_fix_20261120 where new_jp is not null) = 113 then ' ✅' else ' ❌ 대상 수가 다르다' end as result
union all
select '② 현지 이름(name_local) — 타베로그 표기가 된 매장',
       (select count(*) from public._taam_name_fix_20261120 f join public.restaurants r on r.id = f.id
         where f.new_local is not null and r.name_local = f.new_local)::text
       || ' / ' || (select count(*) from public._taam_name_fix_20261120 where new_local is not null)::text || ' ✅'
union all
select '③ 대상인데 지금은 없는 매장(삭제됨 · 정보)',
       (select count(*) from public._taam_name_fix_20261120 f where not exists (select 1 from public.restaurants r where r.id = f.id))::text || ' ⚠ 정보'
union all
select '④ 건너뜀 — 그 사이 다른 값으로 바뀌어 덮지 않은 이름(정보)',
       (select count(*) from public._taam_name_fix_20261120 f join public.restaurants r on r.id = f.id
         where (f.new_jp is not null and r.name_jp is distinct from f.new_jp)
            or (f.new_local is not null and r.name_local is distinct from f.new_local))::text || ' ⚠ 정보';
