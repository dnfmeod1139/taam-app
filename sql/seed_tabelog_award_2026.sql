-- ═══════════════════════════════════════════════════════════════════════════
-- Tabelog Award 2026 (Gold 36 · Silver 160) 을 레스토랑 리스트(public.restaurants)에 등록 (2026-09-16)
-- ═══════════════════════════════════════════════════════════════════════════
-- 실행: Supabase SQL Editor 에서 통째로 RUN. 마지막 표 한 줄: 새로 넣은 수 · 이미 있어 건너뛴 수 · 총계.
--
-- 규칙
--   · 회원 리스트에 보이는 행(source_type 이 null/manual/taam_personal)만 대상. 챗 두뇌용 tabelog_award_2026 행은 안 본다.
--   · 이미 있는 매장(영문명·일본어명·타베로그 URL·한글명 중 하나가 같으면 같은 매장)은 **건너뛴다** — 아무것도 안 바꾼다.
--   · 없는 매장은 새로 넣는다. name = 한글명, 한글명이 없으면(SILVER) 영문명. name_jp/name_en 은 CSV 그대로.
--     source_type='manual' · super_admin_only=false (앱이 회원 리스트에서 super_admin_only 행을 빼므로 true 로 넣으면 어드민도 못 쓴다).
--     i18n_status 는 'manual' — 표기를 사람이 넣었으니 AI 가 이름을 건드리지 않는다.
--   · 같은 CSV 를 두 번 돌려도 두 번 안 들어간다.
-- 되돌리기: delete from public.restaurants where rest_info like 'Tabelog Award 2026 %' and source_type='manual' and created_at > now() - interval '1 hour';
-- ═══════════════════════════════════════════════════════════════════════════
create temp table _ta (tier text, genre_en text, genre_ko text, name_ko text, name_jp text, name_en text, city text, pref text, tabelog text, info text);
insert into _ta values
('GOLD','Chinese Cuisine','중식','닌슈로','仁修樓','Ninshurou','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260503/26033124/','Tabelog Award 2026 GOLD
8석 광동요리 카운터, Tabelog 4.62, Gold 3년 연속'),
('GOLD','Chinese Cuisine','중식','사젠카','茶禅華','Sazenka','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130703/13205298/','Tabelog Award 2026 GOLD · CHEFS'' GOLD
도쿄 유일 중식 Gold — 미슐랭 3스타 광동요리'),
('GOLD','French','프렌치','치소 니시 켄이치','馳走西健一','Chiso Nishi Kenichi','Yaizu','Shizuoka','https://tabelog.com/shizuoka/A2203/A220301/22039375/','Tabelog Award 2026 GOLD · BEST REGIONAL RESTAURANTS
8석 카운터, 스루가만 생선, Tabelog 4.56'),
('GOLD','Innovative','이노베이티브','레스토랑 나즈','レストラン ナズ','Naz','Karuizawa','Nagano','https://tabelog.com/nagano/A2003/A200301/20028578/','Tabelog Award 2026 GOLD · BEST NEW ENTRY
2025년 6월 오픈, 1년만에 Gold. 셰프 鈴木夏暉(스즈키 나츠키), 디너 ¥6~8만대'),
('GOLD','Innovative','이노베이티브','아오','蒼','Ao','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13243463/','Tabelog Award 2026 GOLD'),
('GOLD','Italian','이탈리안','키타노자카 키노시타','北野坂 木下','Kinoshita','Kobe','Hyogo','https://tabelog.com/hyogo/A2801/A280101/28057663/','Tabelog Award 2026 GOLD
9석 프렌치/이탈리안 카운터, Tabelog 4.57'),
('GOLD','Japanese Cuisine','일본요리','슈모쿠초 시미즈','橦木町 しみず','Shimizu','Nagoya','Aichi','https://tabelog.com/aichi/A2301/A230104/23080047/','Tabelog Award 2026 GOLD'),
('GOLD','Japanese Cuisine','일본요리','카타오리','片折','Kataori','Kanazawa','Ishikawa','https://tabelog.com/ishikawa/A1701/A170101/17011166/','Tabelog Award 2026 GOLD
Tabelog 4.72 — Gold 전체 1위 점수. Opinionated About Dining 2025 일본 1위. Gold 6년 연속'),
('GOLD','Japanese Cuisine','일본요리','도진','道人','Dojin','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260301/26030764/','Tabelog Award 2026 GOLD
Opinionated About Dining 순위에서 2년만에 60위 → 19위로 급상승'),
('GOLD','Japanese Cuisine','일본요리','이이다','飯田','Iida','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260202/26016833/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Japanese Cuisine','일본요리','오가타','緒方','Ogata','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260201/26012136/','Tabelog Award 2026 GOLD · CLUB 10-4
미슐랭 2스타 카이세키, Tabelog 4.56'),
('GOLD','Japanese Cuisine','일본요리','솟타쿠 츠카모토','啐啄 つか本','Sottaku Tsukamoto','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260301/26013373/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Japanese Cuisine','일본요리','토쿠하모토나리','徳ㇵ本也','Tokuhamotonari','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260503/26040349/','Tabelog Award 2026 GOLD · CHEFS'' GOLD
Tabelog 4.52, 미슐랭 1스타, 호쿠리쿠 어부 네트워크 통한 직거래 어종 수급'),
('GOLD','Japanese Cuisine','일본요리','유키모토','柚木元','YUKIMOTO','Iida','Nagano','https://tabelog.com/nagano/A2006/A200603/20004238/','Tabelog Award 2026 GOLD
Gold 3년 연속, 주택가 카이세키, Tabelog 4.46+'),
('GOLD','Japanese Cuisine','일본요리','혼코게츠','本湖月','Honkogetsu','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270202/27001286/','Tabelog Award 2026 GOLD · CHEFS'' GOLD, CLUB 10-4
Tabelog 4.59 — Gold 중 최고점급. 600년 된 노송 카운터, 50년 경력 셰프 阿南秀生(아나미 히데오)'),
('GOLD','Japanese Cuisine','일본요리','온자쿠','温石','Onjaku','Yaizu','Shizuoka','https://tabelog.com/shizuoka/A2203/A220301/22006811/','Tabelog Award 2026 GOLD · BEST REGIONAL RESTAURANTS'),
('GOLD','Japanese Cuisine','일본요리','마츠카와','松川','Matsukawa','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13124391/','Tabelog Award 2026 GOLD · CLUB 10-4
초대 시상식부터 지금까지 Gold를 유지한 3개 가게 중 하나 (Sugita, Saito와 함께)'),
('GOLD','Japanese Cuisine','일본요리','신바시 호시노','新ばし 星野','Shimbashi Hoshino','Tokyo','Tokyo','https://tabelog.com/tokyo/A1314/A131401/13136847/','Tabelog Award 2026 GOLD'),
('GOLD','Japanese Cuisine','일본요리','긴자 시노하라','銀座 しのはら','Shinohara','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13200949/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Spanish','스페인요리','아카','アカ','acá 1°','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130202/13249117/','Tabelog Award 2026 GOLD
2026년 종합 1위 — Abon을 제치고 최고점 등극. 스시·카이세키의 나라에서 스페인 요리가 1위 = 이례적'),
('GOLD','Sushi','스시','치카마츠','近松','Chikamatsu','Fukuoka','Fukuoka','https://tabelog.com/fukuoka/A4001/A400104/40000415/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Sushi','스시','코마다','こま田','Komada','Ise','Mie','https://tabelog.com/mie/A2403/A240301/24012212/','Tabelog Award 2026 GOLD
Tabelog 4.54, 이세 지역의 친밀한 에도마에 스시'),
('GOLD','Sushi','스시','스시 산신','鮨 三心','Sanshin','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270204/27095402/','Tabelog Award 2026 GOLD'),
('GOLD','Sushi','스시','히가시아자부 아마모토','東麻布 天本','Amamoto','Tokyo','Tokyo','https://tabelog.com/tokyo/A1314/A131401/13196420/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Sushi','스시','스시 아라이','鮨 あらい','Arai','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13188186/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Sushi','스시','미타니','三谷','Mitani','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130902/13042204/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Sushi','스시','스시 사이토','鮨 さいとう','Saito','Tokyo','Tokyo','https://tabelog.com/tokyo/A1308/A130802/13015251/','Tabelog Award 2026 GOLD · CLUB 10-4
초대 시상식부터 Gold — 전 세계에서 가장 예약 어려운 스시 가게로 꼽힘'),
('GOLD','Sushi','스시','사와다','さわ田','Sawada','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13001043/','Tabelog Award 2026 GOLD · CLUB 10-4'),
('GOLD','Sushi','스시','시마즈','島津','Shimazu','Tokyo','Tokyo','https://tabelog.com/tokyo/A1316/A131602/13252991/','Tabelog Award 2026 GOLD
올해 유일한 Silver→Gold 승격 — 2026년 최대 등급 상승 사례'),
('GOLD','Sushi','스시','니혼바시 카키가라초 스기타','日本橋蛎殻町 すぎた','Sugita','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130204/13018162/','Tabelog Award 2026 GOLD · CHEFS'' GOLD, CLUB 10-4
초대 시상식부터 Gold — 동료 셰프들이 꼽는 1위 스시 레퍼런스'),
('GOLD','Sushi','스시','스시 잇코','鮨 一幸','Sushi Ikko','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13300481/','Tabelog Award 2026 GOLD · BEST NEW ENTRY
초대 전용 — 일반인 사실상 접근 불가'),
('GOLD','Tempura','덴푸라','나루세','成生','Naruse','Shizuoka','Shizuoka','https://tabelog.com/shizuoka/A2201/A220101/22037788/','Tabelog Award 2026 GOLD · CHEFS'' GOLD'),
('GOLD','Tempura','덴푸라','타키야','たきや','Takiya','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130702/13185763/','Tabelog Award 2026 GOLD'),
('GOLD','Unagi','우나기','슌','瞬','SHUN','Shizuoka','Shizuoka','https://tabelog.com/shizuoka/A2201/A220101/22019273/','Tabelog Award 2026 GOLD
Tabelog 4.57 — Gold 등급 유일한 우나기(장어)'),
('GOLD','Yakiniku/Meat dishes','야키니쿠','아카사카 라이몬','赤坂 らいもん','Raimon','Tokyo','Tokyo','https://tabelog.com/tokyo/A1308/A130801/13224635/','Tabelog Award 2026 GOLD
Gold 등급 유일한 야키니쿠 — 프리미엄 곱창/호르몬'),
('GOLD','Yakitori/Poultry','야키토리','카사하라','かさ原','Kasahara','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130905/13266251/','Tabelog Award 2026 GOLD
Gold 등급 유일한 야키토리'),
('SILVER','Chinese Cuisine','중식',null,'真善美','Shinzenbi','Nagoya','Aichi','https://tabelog.com/aichi/A2301/A230104/23075825/','Tabelog Award 2026 SILVER
12-seat Sichuan, Bronze→Silver'),
('SILVER','Chinese Cuisine','중식',null,'一凛 離れ','Ichirin Hanare','Kamakura','Kanagawa','https://tabelog.com/kanagawa/A1404/A140402/14066990/','Tabelog Award 2026 SILVER
Sichuan-inflected, converted house'),
('SILVER','Chinese Cuisine','중식',null,'グゥ','Guu','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260202/26038550/','Tabelog Award 2026 SILVER
6-seat counter, Instagram DM bookings'),
('SILVER','Chinese Cuisine','중식',null,'弘澤','Hirosawa','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260201/26039000/','Tabelog Award 2026 SILVER
Chinese × Japanese × French, 10-seat townhouse'),
('SILVER','Chinese Cuisine','중식',null,'西渕飯店','Nishibuchi Hanten','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260301/26022200/','Tabelog Award 2026 SILVER · CLUB 10-4
Modern Kyoto-style Chinese, dinner-only'),
('SILVER','Chinese Cuisine','중식',null,'彩華','Saika','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260304/26023771/','Tabelog Award 2026 SILVER · CLUB 10-4
8-seat counter, sommelier-led wine'),
('SILVER','Chinese Cuisine','중식',null,'北川','Kitagawa','Matsusaka','Mie','https://tabelog.com/mie/A2401/A240102/24013156/','Tabelog Award 2026 SILVER
Matsusaka beef + Nouvelle Chinois, 80yr-old residence'),
('SILVER','Chinese Cuisine','중식',null,'月泉','Gessen','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270103/27082740/','Tabelog Award 2026 SILVER
18-seat avant-garde, daily-changing menu'),
('SILVER','Chinese Cuisine','중식',null,'田中 義英','Tanaka Yoshihide','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270107/27135992/','Tabelog Award 2026 SILVER
Chinese × Japanese seasonal ingredients, 8-seat'),
('SILVER','Chinese Cuisine','중식',null,'中華 大重','Oshige','Karatsu','Saga','https://tabelog.com/saga/A4102/A410201/41008162/','Tabelog Award 2026 SILVER · Best New Entry, BEST NEW ENTRY
Opened Sep 2024, Kyoto technique × Chinese'),
('SILVER','Chinese Cuisine','중식',null,'富麗華','FUREIKA','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130702/13004967/','Tabelog Award 2026 SILVER · CLUB 10-4
Shanghai/Cantonese, 100+ à la carte items'),
('SILVER','Chinese Cuisine','중식',null,'古田','Furuta','Tokyo','Tokyo','https://tabelog.com/tokyo/A1313/A131301/13176780/','Tabelog Award 2026 SILVER · CLUB 10-4
8-seat creative Chinese, ¥100k+/head'),
('SILVER','Chinese Cuisine','중식',null,'ジーキューブ','Ji-Cube','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13259432/','Tabelog Award 2026 SILVER · Best New Entry, BEST NEW ENTRY
Sichuan via omakase logic, 26 seats'),
('SILVER','Chinese Cuisine','중식',null,'とし','Toshi','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13225413/','Tabelog Award 2026 SILVER
Chinese × French logic, 8-seat basement'),
('SILVER','Chinese Cuisine','중식',null,'ワサ','Wasa','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130302/13251804/','Tabelog Award 2026 SILVER
8-seat Chinese omakase counter'),
('SILVER','Creative cuisine','창작요리',null,'傳','DEN','Tokyo','Tokyo','https://tabelog.com/tokyo/A1306/A130603/13046855/','Tabelog Award 2026 SILVER · CLUB 10-4
Chef Hasegawa Zaiyu — 2-Michelin, Asia 50 Best alumnus, Tabelog Innovative/Creative Tabelog 100 2025'),
('SILVER','French','프렌치',null,'レミニセンス','Reminiscence','Nagoya','Aichi','https://tabelog.com/aichi/A2301/A230106/23085308/','Tabelog Award 2026 SILVER
House restaurant, 32 seats'),
('SILVER','French','프렌치',null,'ハギフレンチ','HAGI','Iwaki','Fukushima','https://tabelog.com/fukushima/A0704/A070401/7008647/','Tabelog Award 2026 SILVER · Best Regional Restaurants, BEST REGIONAL RESTAURANTS
Fukushima produce-driven omakase'),
('SILVER','French','프렌치',null,'アキナガオ','aki nagao','Sapporo','Hokkaido','https://tabelog.com/hokkaido/A0101/A010103/1028665/','Tabelog Award 2026 SILVER
French-innovative w/ Hokkaido seafood focus'),
('SILVER','French','프렌치',null,'レストランウオゼン','Restaurant UOZEN','Sanjo','Niigata','https://tabelog.com/niigata/A1501/A150102/15015200/','Tabelog Award 2026 SILVER
Niigata produce + French framework'),
('SILVER','French','프렌치',null,'オトワレストラン','Otowa Restaurant','Utsunomiya','Tochigi','https://tabelog.com/tochigi/A0901/A090101/9002357/','Tabelog Award 2026 SILVER
Cuisine Mestiza, Relais & Châteaux member'),
('SILVER','French','프렌치',null,'ボンニュ','Bon.nu','Tokyo','Tokyo','https://tabelog.com/tokyo/A1304/A130401/13184186/','Tabelog Award 2026 SILVER · CLUB 10-4
Contemporary French + on-site patisserie'),
('SILVER','French','프렌치',null,'シェ・イノ','Chez Inno','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130202/13000510/','Tabelog Award 2026 SILVER · Chefs'' Gold, CLUB 10-4, CHEFS'' GOLD
Gold→Silver in 2026, 1984 institution'),
('SILVER','French','프렌치',null,'グルマンディーズ','GOURMANDISE','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13190448/','Tabelog Award 2026 SILVER
10-seat bistro, open until 3 AM'),
('SILVER','French','프렌치',null,'レフェルヴェソンス','L''Effervescence','Tokyo','Tokyo','https://tabelog.com/tokyo/A1306/A130602/13116356/','Tabelog Award 2026 SILVER · CLUB 10-4
3 Michelin stars + Green Star'),
('SILVER','French','프렌치',null,'ロオジエ','L''OSIER','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13002607/','Tabelog Award 2026 SILVER · CLUB 10-4
3 Michelin stars, 34 seats'),
('SILVER','French','프렌치',null,'ラ ターブル ドゥ ジョエル・ロブション','LA TABLE de Joël Robuchon','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130302/13009310/','Tabelog Award 2026 SILVER
Robuchon group''s Yebisu Garden Place address'),
('SILVER','French','프렌치',null,'レ セゾン','Les Saisons','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130102/13002294/','Tabelog Award 2026 SILVER · CLUB 10-4
Inside Imperial Hotel Tokyo'),
('SILVER','French','프렌치',null,'オオイシ','Oishi','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13238352/','Tabelog Award 2026 SILVER'),
('SILVER','French','프렌치',null,'カンテサンス','Quintessence','Tokyo','Tokyo','https://tabelog.com/tokyo/A1314/A131405/13159567/','Tabelog Award 2026 SILVER · CLUB 10-4, CHEFS'' GOLD
3 Michelin stars, 13-course tasting'),
('SILVER','French','프렌치',null,'セザン','Sézanne','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130201/13256878/','Tabelog Award 2026 SILVER · CHEFS'' GOLD
Four Seasons Marunouchi 7F, 3 Michelin stars, Asia 50 Best #4 (2025)'),
('SILVER','French','프렌치',null,'津志見','TSUSHIMI','Yamanashi','Yamanashi','https://tabelog.com/yamanashi/A1902/A190202/19012518/','Tabelog Award 2026 SILVER
1 group/sitting, planned 10-year run only'),
('SILVER','Innovative','이노베이티브',null,'アオ','AO','Fukuoka','Fukuoka','https://tabelog.com/fukuoka/A4001/A400106/40051882/','Tabelog Award 2026 SILVER
9-seat counter, fully booked through 2026'),
('SILVER','Innovative','이노베이티브',null,'アカイ','AKAI','Hiroshima','Hiroshima','https://tabelog.com/hiroshima/A3402/A340205/34025803/','Tabelog Award 2026 SILVER · BEST REGIONAL RESTAURANTS'),
('SILVER','Innovative','이노베이티브',null,'ペシコ','pesceco','Shimabara','Nagasaki','https://tabelog.com/nagasaki/A4203/A420302/42008914/','Tabelog Award 2026 SILVER · BEST REGIONAL RESTAURANTS
Ariake Sea seafood-only, lunch-only'),
('SILVER','Innovative','이노베이티브',null,'ビア','Bia','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13270211/','Tabelog Award 2026 SILVER
Japanese × Thai fusion'),
('SILVER','Innovative','이노베이티브',null,'チウネ','CHIUnE','Tokyo','Tokyo','https://tabelog.com/tokyo/A1308/A130801/13295095/','Tabelog Award 2026 SILVER
OAD top 75 Japan, ¥80-100k/head'),
('SILVER','Innovative','이노베이티브',null,'長谷川 稔','Hasegawa Minoru','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130703/13220575/','Tabelog Award 2026 SILVER
4-seat counter, OMAKASE platform'),
('SILVER','Innovative','이노베이티브',null,'ナリサワ','NARISAWA','Tokyo','Tokyo','https://tabelog.com/tokyo/A1306/A130603/13005423/','Tabelog Award 2026 SILVER · CLUB 10-4
World''s 50 Best 2025 re-entry'),
('SILVER','Innovative','이노베이티브',null,'スガラボ','Sugalabo','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130704/13182678/','Tabelog Award 2026 SILVER · CLUB 10-4
Invitation-only, French-Japanese fusion'),
('SILVER','Innovative','이노베이티브',null,'エテ','été','Tokyo','Tokyo','https://tabelog.com/tokyo/A1318/A131811/13249143/','Tabelog Award 2026 SILVER
Chef Natsuko Shoji, ¥100k/head'),
('SILVER','Innovative','이노베이티브',null,'トレス','τρεῖς','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130703/13246316/','Tabelog Award 2026 SILVER
Members-only, 10 seats, Innovative/Creative Top 100 (2025)'),
('SILVER','Innovative','이노베이티브',null,'レヴォ','L''évo','Nanto','Toyama','https://tabelog.com/toyama/A1605/A160502/16009727/','Tabelog Award 2026 SILVER · Chefs'' Gold, CHEFS'' GOLD
Mountain destination dining, La Liste 97pt'),
('SILVER','Italian','이탈리안',null,'イル アオヤマ','il AOYAMA','Nagoya','Aichi','https://tabelog.com/aichi/A2301/A230104/23087381/','Tabelog Award 2026 SILVER'),
('SILVER','Italian','이탈리안',null,'プレゼンテ スギ','PRESENTE Sugi','Sakura','Chiba','https://tabelog.com/chiba/A1204/A120402/12038574/','Tabelog Award 2026 SILVER · BEST REGIONAL RESTAURANTS
Gold→Silver in 2026, kaiseki-style Italian'),
('SILVER','Italian','이탈리안',null,'ウシマル','Ushimaru','Sammu','Chiba','https://tabelog.com/chiba/A1205/A120502/12000598/','Tabelog Award 2026 SILVER · CLUB 10-4
Farm-to-table, Thu-Sun lunch+dinner'),
('SILVER','Italian','이탈리안',null,'パルコ フィエラ','PARCO FIERA','Sapporo','Hokkaido','https://tabelog.com/hokkaido/A0101/A010203/1064202/','Tabelog Award 2026 SILVER
House-made prosciutto, Hokkaido produce'),
('SILVER','Italian','이탈리안',null,'余市 サグラ','SAGRA','Yoichi','Hokkaido','https://tabelog.com/hokkaido/A0106/A010602/1057186/','Tabelog Award 2026 SILVER · BEST REGIONAL RESTAURANTS
Italian auberge in Hokkaido wine country'),
('SILVER','Italian','이탈리안',null,'ヤマグチ','Yamaguchi','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260301/26018397/','Tabelog Award 2026 SILVER · CLUB 10-4
Referral-only, 6-seat counter'),
('SILVER','Italian','이탈리안',null,'チェルカ トローヴァ','CERCA TROVA','Nobeoka','Miyazaki','https://tabelog.com/miyazaki/A4505/A450501/45003573/','Tabelog Award 2026 SILVER
Miyazaki producer-direct, 14-seat house'),
('SILVER','Italian','이탈리안',null,'フォリオリーナ・デラ・ポルタフォルトゥーナ','Fogliolina della Porta Fortuna','Karuizawa','Nagano','https://tabelog.com/nagano/A2003/A200301/20011920/','Tabelog Award 2026 SILVER
Single-group/day, 6 seats'),
('SILVER','Italian','이탈리안',null,'グチーテ','gucite','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270104/27093817/','Tabelog Award 2026 SILVER
Italian WEST 100, wine-mandatory'),
('SILVER','Italian','이탈리안',null,'ラ カーザ トム クリオーザ','TOM Curiosa','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270101/27135015/','Tabelog Award 2026 SILVER
1 Michelin star'),
('SILVER','Italian','이탈리안',null,'カテ クオーレ','kate cuore','Imari','Saga','https://tabelog.com/saga/A4102/A410202/41006295/','Tabelog Award 2026 SILVER · Best Regional Restaurants, BEST REGIONAL RESTAURANTS
5-seat counter, self-raised beef'),
('SILVER','Italian','이탈리안',null,'メグリヴァ','Megriva','Tokyo','Tokyo','https://tabelog.com/tokyo/A1317/A131701/13225445/','Tabelog Award 2026 SILVER · Best New Entry, BEST NEW ENTRY
Referral-only, 10 seats'),
('SILVER','Italian','이탈리안',null,'ペレグリーノ','Pellegrino','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130302/13072775/','Tabelog Award 2026 SILVER · CLUB 10-4
Gold→Silver in 2026, fish-focused, ¥100k+/head'),
('SILVER','Italian','이탈리안',null,'プリズマ','PRISMA','Tokyo','Tokyo','https://tabelog.com/tokyo/A1306/A130602/13123890/','Tabelog Award 2026 SILVER
2 Michelin stars, 10-seat counter'),
('SILVER','Italian','이탈리안',null,'三和','Sanwa','Tokyo','Tokyo','https://tabelog.com/tokyo/A1316/A131602/13264755/','Tabelog Award 2026 SILVER
Charcoal grill + Italian framework, prix fixe closing on pasta'),
('SILVER','Italian','이탈리안',null,'タクボ','Tacubo','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130303/13109940/','Tabelog Award 2026 SILVER · CLUB 10-4
20 seats, producer-led, OAD #86 Japan (2023)'),
('SILVER','Japanese Cuisine','일본요리',null,'たかむら','Takamura','Akita','Akita','https://tabelog.com/akita/A0501/A050101/5000664/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'松山','Matsuyama','Fukuoka','Fukuoka','https://tabelog.com/fukuoka/A4004/A400404/40028665/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'飛梅','TOBIUME','Fukuoka','Fukuoka','https://tabelog.com/fukuoka/A4004/A400404/40019957/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'柳家','Yanagiya','Gifu','Gifu','https://tabelog.com/gifu/A2103/A210301/21000023/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'馳走 啐啄一','Chiso Sottakuito','Hiroshima','Hiroshima','https://tabelog.com/hiroshima/A3401/A340117/34023887/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'味処','Ajidocoro','Hokkaido','Hokkaido','https://tabelog.com/hokkaido/A0107/A010704/1016052/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'木佐貫','Kisanuki','Ishikawa','Ishikawa','https://tabelog.com/ishikawa/A1701/A170101/17015162/','Tabelog Award 2026 SILVER · BEST NEW ENTRY'),
('SILVER','Japanese Cuisine','일본요리',null,'北島','Kitajima','Kanagawa','Kanagawa','https://tabelog.com/kanagawa/A1404/A140402/14083457/','Tabelog Award 2026 SILVER · BEST REGIONAL RESTAURANTS'),
('SILVER','Japanese Cuisine','일본요리',null,'川口','Kawaguchi','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260301/26006453/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'木山','Kiyama','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260202/26029017/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'京天神 野口','Kyotenjin Noguchi','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260501/26018304/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'三田','Mita','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260302/26016620/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'NÖMI','NÖMI RESTAURANT','Kyoto','Kyoto','https://tabelog.com/kyoto/A2608/A260802/26037575/','Tabelog Award 2026 SILVER · BEST NEW ENTRY'),
('SILVER','Japanese Cuisine','일본요리',null,'おがわ','Ogawa','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260201/26013892/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'山岸','Yamagishi','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260201/26026316/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'新宅','Shintaku','Niigata','Niigata','https://tabelog.com/niigata/A1505/A150504/15001790/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'廣門','Hirokado','Oita','Oita','https://tabelog.com/oita/A4402/A440202/44012162/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'沢田','Sawada Osaka','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270108/27137065/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'比山','Hiyama','Saitama','Saitama','https://tabelog.com/saitama/A1102/A110201/11010989/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'比良山荘','Hirasansou','Shiga','Shiga','https://tabelog.com/shiga/A2501/A250101/25000772/','Tabelog Award 2026 SILVER · CLUB 10-4
Mountain inn famous for jibie/wild boar hot pot in winter'),
('SILVER','Japanese Cuisine','일본요리',null,'ふじ','FUJI','Shizuoka','Shizuoka','https://tabelog.com/shizuoka/A2201/A220101/22027669/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'青林','Seirin','Shizuoka','Shizuoka','https://tabelog.com/shizuoka/A2202/A220201/22034729/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'石川','Ishikawa','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130905/13004079/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'いそだ','Isoda','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130204/13303109/','Tabelog Award 2026 SILVER · BEST NEW ENTRY'),
('SILVER','Japanese Cuisine','일본요리',null,'井雪','Iyuki','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13030881/','Tabelog Award 2026 SILVER · CLUB 10-4, BEST NEW ENTRY'),
('SILVER','Japanese Cuisine','일본요리',null,'木本','Kimoto','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130905/13226856/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'貴山','Kizan','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130202/13303152/','Tabelog Award 2026 SILVER · BEST NEW ENTRY'),
('SILVER','Japanese Cuisine','일본요리',null,'蒔村','Makimura','Tokyo','Tokyo','https://tabelog.com/tokyo/A1315/A131502/13003338/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'三鷹','Mitaka','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130103/13228116/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'宮坂','Miyasaka','Tokyo','Tokyo','https://tabelog.com/tokyo/A1306/A130602/13264981/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'明寂','Myojaku','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13270958/','Tabelog Award 2026 SILVER · CHEFS'' GOLD'),
('SILVER','Japanese Cuisine','일본요리',null,'NK','NK','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130905/13249655/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'おぎ乃','Ogino','Tokyo','Tokyo','https://tabelog.com/tokyo/A1308/A130801/13245499/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'晴山','SEIZAN','Tokyo','Tokyo','https://tabelog.com/tokyo/A1314/A131402/13127807/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Japanese Cuisine','일본요리',null,'末冨','Suetomi','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130301/13259485/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'山崎','Yamazaki','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13225691/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'ふじ居','Fujii','Toyama','Toyama','https://tabelog.com/toyama/A1601/A160101/16005789/','Tabelog Award 2026 SILVER'),
('SILVER','Japanese Cuisine','일본요리',null,'出羽屋','Dewaya','Yamagata','Yamagata','https://tabelog.com/yamagata/A0605/A060505/6000120/','Tabelog Award 2026 SILVER · CHEFS'' GOLD
Long-running mountain ryokan, sansai/wild-mountain cuisine'),
('SILVER','Ramen','라멘',null,'らぁ麺屋 飯田商店','IIDASHOUTEN','Kanagawa','Kanagawa','https://tabelog.com/kanagawa/A1410/A141002/14038776/','Tabelog Award 2026 SILVER
Yugawara, Kanagawa — shoyu ramen pinnacle, multi-month reservation queue'),
('SILVER','Seafood','해산물',null,'虹吉','Nijikichi','Ehime','Ehime','https://tabelog.com/ehime/A3802/A380201/38015606/','Tabelog Award 2026 SILVER
Ehime regional seafood — strong regional Best Regional candidate'),
('SILVER','Seafood','해산물',null,'味満ん','Ajiman','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13001332/','Tabelog Award 2026 SILVER · CLUB 10-4
Famous fugu (pufferfish) specialist — winter-only premium tasting tradition'),
('SILVER','Spanish','스페인요리',null,'レスピラシオン','respiración','Kanazawa','Ishikawa','https://tabelog.com/ishikawa/A1701/A170101/17010732/','Tabelog Award 2026 SILVER
Ishikawa produce + Spanish framework, La Liste 88pt, sommelier-led'),
('SILVER','Sushi','스시',null,'鮨 こま','Sushikoma','Yurihonjo','Akita','https://tabelog.com/akita/A0506/A050601/5006041/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'すし英','Sushiei','Chiba','Chiba','https://tabelog.com/chiba/A1201/A120101/12052833/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'車寿司','Kurumasushi','Matsuyama','Ehime','https://tabelog.com/ehime/A3801/A380101/38002524/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 十兵衛','Jubei','Fukui','Fukui','https://tabelog.com/fukui/A1801/A180101/18001608/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Sushi','스시',null,'菊鮨','Kikuzushi','Fukuoka','Fukuoka','https://tabelog.com/fukuoka/A4003/A400301/40010675/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 さかい','Sakai','Fukuoka','Fukuoka','https://tabelog.com/fukuoka/A4001/A400103/40034544/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Sushi','스시',null,'天寿し 京町店','Tenzushi Kyomachi','Kitakyushu','Fukuoka','https://tabelog.com/fukuoka/A4004/A400401/40000721/','Tabelog Award 2026 SILVER · CLUB 10-4
2026 downgrade from Gold to Silver'),
('SILVER','Sushi','스시',null,'尾花','Obana','Tatebayashi','Gunma','https://tabelog.com/gunma/A1002/A100204/10002097/','Tabelog Award 2026 SILVER
Famous since 1968'),
('SILVER','Sushi','스시',null,'鮨 みやかわ','Sushi Miyakawa','Sapporo','Hokkaido','https://tabelog.com/hokkaido/A0101/A010105/1073214/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'すし処 めくみ','Mekumi','Nonoichi','Ishikawa','https://tabelog.com/ishikawa/A1702/A170203/17000700/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Sushi','스시',null,'鮨処 のむら','Sushisho Nomura','Kagoshima','Kagoshima','https://tabelog.com/kagoshima/A4601/A460101/46000087/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Sushi','스시',null,'鮨 喜雨','Kiu','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260201/26034605/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'兄弟寿司','Kyodaizushi','Niigata','Niigata','https://tabelog.com/niigata/A1501/A150101/15023066/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'ときわ鮨 新発田本店','Tokiwasushi Shibata Honten','Shibata','Niigata','https://tabelog.com/niigata/A1505/A150502/15001390/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨処 久田','Hisada','Akaiwa','Okayama','https://tabelog.com/okayama/A3301/A330104/33000059/','Tabelog Award 2026 SILVER · Best Regional Restaurants, CLUB 10-4, BEST REGIONAL RESTAURANTS'),
('SILVER','Sushi','스시',null,'鮨 いのまた','Sushi Inomata','Saitama','Saitama','https://tabelog.com/saitama/A1102/A110201/11036797/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 あきら','Akira','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130302/13241432/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'はるたか','Harutaka','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130103/13032283/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Sushi','스시',null,'鮨 はしもと','Hashimoto','Tokyo','Tokyo','https://tabelog.com/tokyo/A1313/A131301/13238306/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鳩','Hato','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130905/13245540/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'難波 日比谷','Namba Hibiya','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130102/13219857/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 木村','Sushi Kimura','Tokyo','Tokyo','https://tabelog.com/tokyo/A1317/A131708/13026584/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 めいの','Sushi Meino','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130702/13292357/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 にし崎','Sushi Nishizaki','Tokyo','Tokyo','https://tabelog.com/tokyo/A1318/A131811/13270984/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 龍次郎','Ryujiro','Tokyo','Tokyo','https://tabelog.com/tokyo/A1306/A130603/13240787/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 しゅんじ','Shunji','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13282687/','Tabelog Award 2026 SILVER'),
('SILVER','Sushi','스시',null,'鮨 俊輔','Shunsuke','Tokyo','Tokyo','https://tabelog.com/tokyo/A1319/A131905/13127515/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Sushi','스시',null,'鮨 たかみつ','Takamitsu','Tokyo','Tokyo','https://tabelog.com/tokyo/A1317/A131701/13128483/','Tabelog Award 2026 SILVER · CLUB 10-4'),
('SILVER','Sushi','스시',null,'鮨匠','Sushisho','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130902/13000852/','Tabelog Award 2026 SILVER · CLUB 10-4
Originally Sushisho Masa, Yotsuya — legendary edomae counter'),
('SILVER','Tempura','덴푸라',null,'天白','Tenhaku','Chiba','Chiba','https://tabelog.com/chiba/A1201/A120101/12037698/','Tabelog Award 2026 SILVER
Reservations via Ikkyu only'),
('SILVER','Tempura','덴푸라',null,'天麩羅 たけうち','Takeuchi','Nakagawa','Fukuoka','https://tabelog.com/fukuoka/A4003/A400301/40013636/','Tabelog Award 2026 SILVER
Bronze→Silver in 2026'),
('SILVER','Tempura','덴푸라',null,'天ぷら もっこす','Mokkosu','Takasaki','Gunma','https://tabelog.com/gunma/A1001/A100102/10000668/','Tabelog Award 2026 SILVER
100% Taihaku sesame oil'),
('SILVER','Tempura','덴푸라',null,'天ぷら 沼田','Numata','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270101/27119864/','Tabelog Award 2026 SILVER
2 Michelin stars'),
('SILVER','Tempura','덴푸라',null,'中村','Nakamura','Shizuoka','Shizuoka','https://tabelog.com/shizuoka/A2203/A220301/22041228/','Tabelog Award 2026 SILVER
Bronze→Silver in 2026, opened 2023'),
('SILVER','Tempura','덴푸라',null,'天ぷら 浅沼','Asanuma','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130202/13275655/','Tabelog Award 2026 SILVER'),
('SILVER','Tempura','덴푸라',null,'楠 本店','Kusunoki Honten','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130902/13223239/','Tabelog Award 2026 SILVER
Membership reservation'),
('SILVER','Tempura','덴푸라',null,'そのじ','Sonoji','Tokyo','Tokyo','https://tabelog.com/tokyo/A1302/A130204/13201969/','Tabelog Award 2026 SILVER
Edomae tempura + sakura shrimp soba finish'),
('SILVER','Tonkatsu/Fried foods','돈카츠',null,'あぼん','Abon','Hyogo','Hyogo','https://tabelog.com/hyogo/A2803/A280302/28000052/','Tabelog Award 2026 SILVER · BEST REGIONAL, CLUB 10-4, BEST REGIONAL RESTAURANTS
Best Regional + CLUB 10-4 double designation — exceptional within tonkatsu category'),
('SILVER','Tonkatsu/Fried foods','돈카츠',null,'YODA','YODA','Kanagawa','Kanagawa','https://tabelog.com/kanagawa/A1401/A140104/14082436/','Tabelog Award 2026 SILVER · BEST NEW ENTRY'),
('SILVER','Unagi','우나기',null,'友栄','Tomoei','Kanagawa','Kanagawa','https://tabelog.com/kanagawa/A1410/A141001/14001626/','Tabelog Award 2026 SILVER · CLUB 10-4
Hakone-area destination unagi'),
('SILVER','Unagi','우나기',null,'うらん','Uran','Shiga','Shiga','https://tabelog.com/shiga/A2501/A250101/25004102/','Tabelog Award 2026 SILVER · BEST REGIONAL RESTAURANTS'),
('SILVER','Unagi','우나기',null,'浅谷','Asaya','Tokyo','Tokyo','https://tabelog.com/tokyo/A1318/A131810/13289291/','Tabelog Award 2026 SILVER · BEST NEW ENTRY'),
('SILVER','Unagi','우나기',null,'かぶと','Kabuto','Tokyo','Tokyo','https://tabelog.com/tokyo/A1305/A130501/13016660/','Tabelog Award 2026 SILVER · CLUB 10-4
Long-established Tokyo unagi institution'),
('SILVER','Unagi','우나기',null,'魚政','Uomasa','Tokyo','Tokyo','https://tabelog.com/tokyo/A1324/A132403/13035339/','Tabelog Award 2026 SILVER · CLUB 10-4
Tokyo''s most-revered traditional unagi house'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'炭火焼肉ホルモン さわいし','Sawaishi','Kawasaki','Kanagawa','https://tabelog.com/kanagawa/A1405/A140504/14091558/','Tabelog Award 2026 SILVER'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'肉の匠 みよし','Miyoshi','Kyoto','Kyoto','https://tabelog.com/kyoto/A2601/A260301/26002222/','Tabelog Award 2026 SILVER · CLUB 10-4
Beef kaiseki format, Gold 2019-20'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'恵比寿 よろにく','Ebisu YORONIKU','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130302/13211927/','Tabelog Award 2026 SILVER
''Meat kaiseki'' format'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'かわむら','Kawamura','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13016506/','Tabelog Award 2026 SILVER · CLUB 10-4
Counter-only steak, referral-only, ¥100k+/head'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'肉屋 田中 銀座','Nikuya Tanaka Ginza','Tokyo','Tokyo','https://tabelog.com/tokyo/A1301/A130101/13237628/','Tabelog Award 2026 SILVER
Binchotan charcoal, beef kaiseki'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'スタミナ苑','Sutaminaen','Tokyo','Tokyo','https://tabelog.com/tokyo/A1323/A132305/13003777/','Tabelog Award 2026 SILVER · CLUB 10-4
Legendary downtown yakiniku, cash-only, no reservations'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'焼肉 光泉','Yakiniku Kosen','Tokyo','Tokyo','https://tabelog.com/tokyo/A1324/A132403/13133997/','Tabelog Award 2026 SILVER · Best New Entry'),
('SILVER','Yakiniku/Meat dishes','야키니쿠',null,'よろにく 麻布台ヒルズ','YORONIKU TOKYO AZABUDAIHILLS','Tokyo','Tokyo','https://tabelog.com/tokyo/A1307/A130701/13291424/','Tabelog Award 2026 SILVER
Yakiniku + meat kaiseki, English service'),
('SILVER','Yakitori/Poultry','야키토리',null,'山麓','Sanroku','Kumamoto','Kumamoto','https://tabelog.com/kumamoto/A4303/A430301/43001156/','Tabelog Award 2026 SILVER
Robatayaki Sanroku — chicken & meat dishes'),
('SILVER','Yakitori/Poultry','야키토리',null,'鳥匠 いし井','Torisho Ishii','Osaka','Osaka','https://tabelog.com/osaka/A2701/A270103/27117938/','Tabelog Award 2026 SILVER'),
('SILVER','Yakitori/Poultry','야키토리',null,'茶太呂','Chataro','Tokyo','Tokyo','https://tabelog.com/tokyo/A1303/A130301/13157208/','Tabelog Award 2026 SILVER'),
('SILVER','Yakitori/Poultry','야키토리',null,'巻鶏 神戸','MAKITORI SHINKOBE','Tokyo','Tokyo','https://tabelog.com/tokyo/A1308/A130801/13291292/','Tabelog Award 2026 SILVER'),
('SILVER','Yakitori/Poultry','야키토리',null,'大草','OHKUSA','Tokyo','Tokyo','https://tabelog.com/tokyo/A1309/A130903/13240980/','Tabelog Award 2026 SILVER'),
('SILVER','Yakitori/Poultry','야키토리',null,'鷹匠 寿','Takajo Kotobuki','Tokyo','Tokyo','https://tabelog.com/tokyo/A1311/A131102/13003661/','Tabelog Award 2026 SILVER · CLUB 10-4
Listed as ''Toriryori'' (poultry cuisine), referral-only'),
('SILVER','Yakitori/Poultry','야키토리',null,'鳥しき','Torishiki','Tokyo','Tokyo','https://tabelog.com/tokyo/A1316/A131601/13041029/','Tabelog Award 2026 SILVER · CLUB 10-4');

with member_rows as (
  select * from public.restaurants r
   where r.source_type is null or r.source_type in ('manual','taam_personal')
), matched as (
  select t.*, r.id as rid
    from _ta t
    join member_rows r
      on lower(btrim(coalesce(r.name_en,''))) = lower(t.name_en)
      or (nullif(btrim(coalesce(r.name_jp,'')),'') is not null and btrim(r.name_jp) = t.name_jp)
      or (nullif(btrim(coalesce(r.tabelog_url,'')),'') is not null and btrim(r.tabelog_url) = t.tabelog)
      or lower(btrim(coalesce(r.name,''))) = lower(coalesce(nullif(t.name_ko,''), t.name_en))
), ins as (
  insert into public.restaurants
    (name, name_en, name_jp, name_local, description, genre, genre_en, region, country_en, city_en, district,
     tabelog_url, rest_info, source_type, super_admin_only, i18n_status_en, i18n_status_jp)
  select coalesce(nullif(t.name_ko,''), t.name_en), t.name_en, t.name_jp, t.name_jp, t.genre_ko, t.genre_ko, t.genre_en,
         '일본', 'japan', t.city, t.pref, t.tabelog, t.info, 'manual', false, 'manual', 'manual'
    from _ta t
   where not exists (select 1 from matched m where m.name_en = t.name_en)
  returning id
)
select (select count(*) from ins) as "새로 등록",
       (select count(distinct name_en) from matched) as "이미 있어 건너뜀",
       (select count(*) from _ta) as "CSV 총계";
