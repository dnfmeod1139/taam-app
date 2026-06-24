-- ═══════════════════════════════════════════════════════════════
-- TAAM — 파트너십 후보 일괄 추가: Tabelog Award 2026 Gold+Silver+Bronze (2026-06-24)
-- ═══════════════════════════════════════════════════════════════
-- 출처: venues/_award_index.json → tabelog_award_2026.gold(36)+silver(160)+bronze(213)
-- 합집합 409곳. venue_id = /venues/{id}.json 슬러그(모두 인덱스 존재).
--
-- ⚠️ 방침: '무조건 노출' 이 아니라 → is_partner=false (숨김) 상태로 추가.
--   · 회원 예약요청 화면에는 안 보임. 관리 화면(🤝 파트너십 관리)에 '숨김'으로 등록됨.
--   · 슈퍼어드민이 거기서 원하는 매장만 '노출' 토글 → 회원에게 공개.
--   · on conflict do nothing: 이미 등록된(이미 노출 켠) 매장은 건드리지 않음.
--
-- idempotent: 재실행 안전. 실행: Supabase SQL Editor 에 붙여넣고 RUN.
-- ═══════════════════════════════════════════════════════════════

insert into public.venue_partners (venue_id, is_partner, channel)
select vid, false, 'request_open'
from (values
  ('aca-1-tokyo'),  -- [gold] 아카
  ('amamoto-tokyo'),  -- [gold] 히가시아자부 아마모토
  ('ao-tokyo'),  -- [gold] 아오
  ('arai-tokyo'),  -- [gold] 스시 아라이
  ('chikamatsu-fukuoka'),  -- [gold] 치카마츠
  ('chiso-nishi-kenichi-yaizu'),  -- [gold] 치소 니시 켄이치
  ('dojin-kyoto'),  -- [gold] 도진
  ('honkogetsu-osaka'),  -- [gold] 혼코게츠
  ('iida-kyoto'),  -- [gold] 이이다
  ('kasahara-tokyo'),  -- [gold] 카사하라
  ('kataori-kanazawa'),  -- [gold] 카타오리
  ('kinoshita-kobe'),  -- [gold] 키타노자카 키노시타
  ('komada-ise'),  -- [gold] 코마다
  ('matsukawa-tokyo'),  -- [gold] 마츠카와
  ('mitani-tokyo'),  -- [gold] 미타니
  ('naruse-shizuoka'),  -- [gold] 나루세
  ('naz-karuizawa'),  -- [gold] 레스토랑 나즈
  ('ninshurou-kyoto'),  -- [gold] 닌슈로
  ('ogata-kyoto'),  -- [gold] 오가타
  ('onjaku-yaizu'),  -- [gold] 온자쿠
  ('raimon-tokyo'),  -- [gold] 아카사카 라이몬
  ('saito-tokyo'),  -- [gold] 스시 사이토
  ('sanshin-osaka'),  -- [gold] 스시 산신
  ('sawada-tokyo'),  -- [gold] 사와다
  ('sazenka-tokyo'),  -- [gold] 사젠카
  ('shimazu-tokyo'),  -- [gold] 시마즈
  ('shimbashi-hoshino-tokyo'),  -- [gold] 신바시 호시노
  ('shimizu-nagoya'),  -- [gold] 슈모쿠초 시미즈
  ('shinohara-tokyo'),  -- [gold] 긴자 시노하라
  ('shun-shizuoka'),  -- [gold] 슌
  ('sottaku-tsukamoto-kyoto'),  -- [gold] 솟타쿠 츠카모토
  ('sugita-tokyo'),  -- [gold] 니혼바시 카키가라초 스기타
  ('sushi-ikko-tokyo'),  -- [gold] 스시 잇코
  ('takiya-tokyo'),  -- [gold] 타키야
  ('tokuhamotonari-kyoto'),  -- [gold] 토쿠하모토나리
  ('yukimoto-iida'),  -- [gold] 유키모토
  ('abon-hyogo'),  -- [silver] Abon
  ('ajidocoro-hokkaido'),  -- [silver] 아지도코로
  ('ajiman-tokyo'),  -- [silver] Ajiman
  ('akai-hiroshima'),  -- [silver] AKAI
  ('akasaka-ogino-tokyo'),  -- [silver] 아카사카 오기노
  ('aki-nagao-sapporo'),  -- [silver] aki nagao
  ('akira-tokyo'),  -- [silver] 아키라
  ('ao-fukuoka'),  -- [silver] AO
  ('asanuma-tokyo'),  -- [silver] 아사누마
  ('asaya-tokyo'),  -- [silver] Asaya
  ('bia-tokyo'),  -- [silver] Bia
  ('bonnu-tokyo'),  -- [silver] Bon.nu
  ('cerca-trova-nobeoka'),  -- [silver] CERCA TROVA
  ('chataro-tokyo'),  -- [silver] Chataro
  ('chez-inno-tokyo'),  -- [silver] Chez Inno
  ('chiso-sottakuito-hiroshima'),  -- [silver] 치소 솟타쿠이토
  ('chiune-tokyo'),  -- [silver] CHIUnE
  ('chuka-ooshige-karatsu'),  -- [silver] Chuka Ooshige
  ('den-tokyo'),  -- [silver] DEN
  ('dewaya-yamagata'),  -- [silver] 데와야
  ('ebisu-yoroniku-tokyo'),  -- [silver] Ebisu YORONIKU
  ('ete-tokyo'),  -- [silver] été
  ('fogliolina-della-porta-fortuna-karuizawa'),  -- [silver] Fogliolina della Porta Fortuna
  ('fuji-shizuoka'),  -- [silver] 후지
  ('fujii-toyama'),  -- [silver] 후지이
  ('fureika-tokyo'),  -- [silver] FUREIKA
  ('furuta-tokyo'),  -- [silver] Furuta
  ('gessen-osaka'),  -- [silver] Gessen
  ('gourmandise-tokyo'),  -- [silver] GOURMANDISE
  ('gucite-osaka'),  -- [silver] gucite
  ('guu-kyoto'),  -- [silver] Guu
  ('hagi-iwaki'),  -- [silver] HAGI
  ('harutaka-tokyo'),  -- [silver] 하루타카
  ('hasegawa-minoru-tokyo'),  -- [silver] Hasegawa Minoru
  ('hashimoto-tokyo'),  -- [silver] 하시모토
  ('hato-tokyo'),  -- [silver] 하토우
  ('hirasansou-shiga'),  -- [silver] 히라산소
  ('hirokado-oita'),  -- [silver] 히로카도
  ('hirosawa-kyoto'),  -- [silver] Hirosawa
  ('hisada-okayama'),  -- [silver] 히사다
  ('hiyama-saitama'),  -- [silver] 히야마
  ('ichirin-hanare-kamakura'),  -- [silver] Ichirin Hanare
  ('iidashouten-kanagawa'),  -- [silver] IIDASHOUTEN
  ('il-aoyama-nagoya'),  -- [silver] il AOYAMA
  ('inomata-saitama'),  -- [silver] 이노마타
  ('isoda-tokyo'),  -- [silver] 이소다
  ('iyuki-tokyo'),  -- [silver] 이유키
  ('ji-cube-tokyo'),  -- [silver] Ji-Cube
  ('jubei-fukui'),  -- [silver] 주베이
  ('kabuto-tokyo'),  -- [silver] Kabuto
  ('kagurazaka-ishikawa-tokyo'),  -- [silver] 카구라자카 이시카와
  ('kate-cuore-imari'),  -- [silver] kate cuore
  ('kawaguchi-kyoto'),  -- [silver] 카와구치
  ('kawamura-tokyo'),  -- [silver] Kawamura
  ('kikuzushi-fukuoka'),  -- [silver] 키쿠즈시
  ('kimoto-tokyo'),  -- [silver] 키모토
  ('kimura-tokyo'),  -- [silver] 키무라
  ('kisanuki-ishikawa'),  -- [silver] 키사누키
  ('kitagawa-matsusaka'),  -- [silver] Kitagawa
  ('kitajima-kanagawa'),  -- [silver] 키타지마
  ('kiu-kyoto'),  -- [silver] 키우
  ('kiyama-kyoto'),  -- [silver] 키야마
  ('kizan-tokyo'),  -- [silver] 키잔
  ('kurumasushi-ehime'),  -- [silver] 쿠루마스시
  ('kusunoki-honten-tokyo'),  -- [silver] 쿠스노키 본점
  ('kyodaizushi-niigata'),  -- [silver] 쿄다이즈시
  ('kyotenjin-noguchi-kyoto'),  -- [silver] 쿄텐진 노구치
  ('la-casa-tom-curiosa-osaka'),  -- [silver] La casa TOM Curiosa
  ('la-table-de-jol-robuchon-tokyo'),  -- [silver] LA TABLE de Joël Robuchon
  ('leffervescence-tokyo'),  -- [silver] L'Effervescence
  ('les-saisons-tokyo'),  -- [silver] Les Saisons
  ('losier-tokyo'),  -- [silver] L'OSIER
  ('lvo-nanto'),  -- [silver] L'évo
  ('makimura-tokyo'),  -- [silver] 마키무라
  ('makitori-shinkobe-tokyo'),  -- [silver] MAKITORI SHINKOBE
  ('matsuyama-fukuoka'),  -- [silver] 마츠야마
  ('megriva-tokyo'),  -- [silver] Megriva
  ('meino-tokyo'),  -- [silver] 메이노
  ('mekumi-ishikawa'),  -- [silver] 메쿠미
  ('mita-kyoto'),  -- [silver] 미타
  ('mitaka-tokyo'),  -- [silver] 미타카
  ('miyakawa-hokkaido'),  -- [silver] 미야카와
  ('miyasaka-tokyo'),  -- [silver] 미야사카
  ('miyoshi-kyoto'),  -- [silver] Miyoshi
  ('mokkosu-gunma'),  -- [silver] 몯코스
  ('myojaku-tokyo'),  -- [silver] 묘자쿠
  ('nakamura-shizuoka'),  -- [silver] 나카무라
  ('namba-hibiya-tokyo'),  -- [silver] 난바 히비야
  ('narisawa-tokyo'),  -- [silver] NARISAWA
  ('nijikichi-ehime'),  -- [silver] Nijikichi
  ('nikuya-tanaka-ginza-tokyo'),  -- [silver] Nikuya Tanaka Ginza
  ('nishibuchi-hanten-kyoto'),  -- [silver] Nishibuchi Hanten
  ('nishizaki-tokyo'),  -- [silver] 니시자키
  ('nk-tokyo'),  -- [silver] NK
  ('nomi-kyoto'),  -- [silver] NÖMI RESTAURANT
  ('numata-osaka'),  -- [silver] 누마타
  ('obana-gunma'),  -- [silver] 오바나
  ('ogawa-kyoto'),  -- [silver] 오가와
  ('ohkusa-tokyo'),  -- [silver] OHKUSA
  ('oishi-tokyo'),  -- [silver] Oishi
  ('otowa-restaurant-utsunomiya'),  -- [silver] Otowa Restaurant
  ('parco-fiera-sapporo'),  -- [silver] PARCO FIERA
  ('pellegrino-tokyo'),  -- [silver] Pellegrino
  ('pesceco-shimabara'),  -- [silver] pesceco
  ('presente-sugi-sakura'),  -- [silver] PRESENTE Sugi
  ('prisma-tokyo'),  -- [silver] PRISMA
  ('quintessence-tokyo'),  -- [silver] Quintessence
  ('reminiscence-nagoya'),  -- [silver] Reminiscence
  ('respiracion-kanazawa'),  -- [silver] Respiracion
  ('restaurant-uozen-sanjo'),  -- [silver] Restaurant UOZEN
  ('ryujiro-tokyo'),  -- [silver] 류지로
  ('saika-kyoto'),  -- [silver] Saika
  ('sakai-fukuoka'),  -- [silver] 사카이
  ('sanroku-kumamoto'),  -- [silver] Sanroku
  ('sanwa-tokyo'),  -- [silver] Sanwa
  ('sawada-osaka'),  -- [silver] 사와다
  ('sawaishi-kawasaki'),  -- [silver] Sawaishi
  ('seirin-shizuoka'),  -- [silver] 세이린
  ('seizan-tokyo'),  -- [silver] 세이잔
  ('shintaku-niigata'),  -- [silver] 신타쿠
  ('shinzenbi-nagoya'),  -- [silver] Shinzenbi
  ('shunji-tokyo'),  -- [silver] 슌지
  ('shunsuke-asagaya-tokyo'),  -- [silver] 슌스케 아사가야
  ('sonoji-tokyo'),  -- [silver] 소노지
  ('suetomi-tokyo'),  -- [silver] 스에토미
  ('sugalabo-tokyo'),  -- [silver] Sugalabo
  ('sushiei-chiba'),  -- [silver] 스시에이
  ('sushikoma-akita'),  -- [silver] 스시코마
  ('sushisho-nomura-kagoshima'),  -- [silver] 스시쇼 노무라
  ('sushisho-tokyo'),  -- [silver] 스시쇼
  ('sutaminaen-tokyo'),  -- [silver] Sutaminaen
  ('szanne-tokyo'),  -- [silver] Sézanne
  ('tacubo-tokyo'),  -- [silver] Tacubo
  ('takajo-kotobuki-tokyo'),  -- [silver] Takajo Kotobuki
  ('takamitsu-tokyo'),  -- [silver] 타카미츠
  ('takamura-akita'),  -- [silver] 타카무라
  ('takeuchi-fukuoka'),  -- [silver] 타케우치
  ('tanaka-yoshihide-osaka'),  -- [silver] Tanaka Yoshihide
  ('tenhaku-chiba'),  -- [silver] 텐하쿠
  ('tenzushi-kyomachi-fukuoka'),  -- [silver] 텐즈시 쿄마치점
  ('tobiume-fukuoka'),  -- [silver] 토비우메
  ('tokiwasushi-shibata-niigata'),  -- [silver] 토키와스시 시바타본점
  ('tomoei-kanagawa'),  -- [silver] Tomoei
  ('tori-shiki-tokyo'),  -- [silver] Tori-Shiki
  ('torisho-ishii-osaka'),  -- [silver] Torisho Ishii
  ('toshi-tokyo'),  -- [silver] Toshi
  ('trace-tokyo'),  -- [silver] τρεῖς (Trace)
  ('tsushimi-yamanashi'),  -- [silver] TSUSHIMI
  ('uomasa-tokyo'),  -- [silver] Uomasa
  ('uran-shiga'),  -- [silver] Uran
  ('ushimaru-sammu'),  -- [silver] Ushimaru
  ('wasa-tokyo'),  -- [silver] Wasa
  ('yakiniku-kosen-tokyo'),  -- [silver] Yakiniku Kosen
  ('yamagishi-kyoto'),  -- [silver] 야마기시
  ('yamaguchi-kyoto'),  -- [silver] Yamaguchi
  ('yamazaki-tokyo'),  -- [silver] 야마자키
  ('yanagiya-gifu'),  -- [silver] 야나기야
  ('yoda-kanagawa'),  -- [silver] YODA
  ('yoichi-sagra-yoichi'),  -- [silver] Yoichi Sagra
  ('yoroniku-azabudai-hills-tokyo'),  -- [silver] Yoroniku Azabudai Hills
  ('4000-chinese-restaurant-tokyo-b'),  -- [bronze] 4000 Chinese Restaurant
  ('akakichi-matsuyama-b'),  -- [bronze] Akakichi
  ('amaki-nagoya-b'),  -- [bronze] Amaki
  ('ara-ki-tokyo-b'),  -- [bronze] Ara Ki
  ('aragawa-kobe-b'),  -- [bronze] Aragawa
  ('araki-hokkaido-b'),  -- [bronze] Araki
  ('arata-osaka-b'),  -- [bronze] Arata
  ('arima-sapporo-b'),  -- [bronze] Arima
  ('asago-fukuoka-b'),  -- [bronze] Asago
  ('aube-osaka-b'),  -- [bronze] AUBE
  ('awajishima-nobu-awaji-b'),  -- [bronze] Awajishima Nobu
  ('azabu-juban-hatano-yoshiki-tokyo-b'),  -- [bronze] Azabu Juban Hatano Yoshiki
  ('caravan-saga-b'),  -- [bronze] Caravan
  ('daibon-osaka-b'),  -- [bronze] Daibon
  ('daimon-takaoka-b'),  -- [bronze] Daimon
  ('edo-machi-sugimoto-toba-b'),  -- [bronze] Edo Machi Sugimoto
  ('edomae-shinsaku-tokyo-b'),  -- [bronze] Edomae Shinsaku
  ('eiki-tokyo-b'),  -- [bronze] Eiki
  ('en-okayama-b'),  -- [bronze] En
  ('eragon-hyogo-b'),  -- [bronze] Eragon
  ('fujii-osaka-b'),  -- [bronze] Fujii
  ('fujisawa-nagoya-b'),  -- [bronze] Fujisawa
  ('fukamachi-tokyo-b'),  -- [bronze] Fukamachi
  ('fukunaga-shiga-b'),  -- [bronze] Fukunaga
  ('gahojin-fukuoka-b'),  -- [bronze] Gahojin
  ('ginza-sushi-kanesaka-hon-ten-tokyo-b'),  -- [bronze] Ginza Sushi Kanesaka Hon Ten
  ('goichi-higobashi-osaka-b'),  -- [bronze] Goichi Higobashi
  ('gyusen-saga-b'),  -- [bronze] Gyusen
  ('hama-gen-nagoya-b'),  -- [bronze] Hama Gen
  ('hasunomi-okayama-b'),  -- [bronze] Hasunomi
  ('hatsunezushi-tokyo-b'),  -- [bronze] Hatsunezushi
  ('hidetaka-sapporo-b'),  -- [bronze] Hidetaka
  ('higebozu-hokkaido-b'),  -- [bronze] Higebozu
  ('hijikata-nagoya-b'),  -- [bronze] Hijikata
  ('hinotori-osaka-b'),  -- [bronze] Hinotori
  ('hiro-gifu-b'),  -- [bronze] hiro
  ('hiro-nagoya-nagoya-b'),  -- [bronze] HIRO NAGOYA
  ('hitotsu-miyazaki-b'),  -- [bronze] Hitotsu
  ('hitsujiya-yamagata-b'),  -- [bronze] Hitsujiya
  ('ichikawa-tokyo-b'),  -- [bronze] Ichikawa
  ('ichimatsu-osaka-b'),  -- [bronze] Ichimatsu
  ('ichiunagi-shizuoka-b'),  -- [bronze] Ichiunagi
  ('imaishihanten-suzuka-fukuoka-b'),  -- [bronze] IMAISHIHANTEN SUZUKA
  ('ino-matsuyama-b'),  -- [bronze] Ino
  ('ishimaru-saitama-b'),  -- [bronze] Ishimaru
  ('isshinzushi-koyo-miyazaki-b'),  -- [bronze] Isshinzushi Koyo
  ('ito-fukushima-b'),  -- [bronze] Ito
  ('ito-oita-b'),  -- [bronze] Ito
  ('jambo-hanare-tokyo-b'),  -- [bronze] Jambo Hanare
  ('jinsei-osaka-b'),  -- [bronze] Jinsei
  ('jiyu-san-tokyo-b'),  -- [bronze] Jiyu San
  ('jo-tokyo-b'),  -- [bronze] JO
  ('jotaki-tokyo-b'),  -- [bronze] JOTAKI
  ('kaikatei-gifu-b'),  -- [bronze] Kaikatei
  ('karyu-tokyo-b'),  -- [bronze] Karyu
  ('kibatani-kanazawa-b'),  -- [bronze] Kibatani
  ('kinryusan-tokyo-b'),  -- [bronze] Kinryusan
  ('kioicho-mitani-tokyo-b'),  -- [bronze] 키오이초 미타니
  ('kitchen-ribbon-nagoya-b'),  -- [bronze] Kitchen Ribbon
  ('kiyota-hanare-tokyo-b'),  -- [bronze] Kiyota Hanare
  ('kiyota-tokyo-b'),  -- [bronze] Kiyota
  ('kizaki-tokyo-b'),  -- [bronze] Kizaki
  ('kobanzushi-tanagura-tanagura-b'),  -- [bronze] Kobanzushi Tanagura
  ('kohane-shizuoka-b'),  -- [bronze] Kohane
  ('koho-tokyo-b'),  -- [bronze] Koho
  ('koizumi-ishikawa-b'),  -- [bronze] Koizumi
  ('koki-tokyo-b'),  -- [bronze] Koki
  ('komatsu-yasuke-kanazawa-b'),  -- [bronze] Komatsu Yasuke
  ('kondo-tokyo-b'),  -- [bronze] Kondo
  ('kotan-fukuoka-b'),  -- [bronze] Kotan
  ('koto-fukuoka-b'),  -- [bronze] Koto
  ('kuishinbo-yamanaka-kyoto-b'),  -- [bronze] Kuishinbo YAMANAKA
  ('kuromori-miyagi-b'),  -- [bronze] KUROMORI
  ('kurosaki-tokyo-b'),  -- [bronze] Kurosaki
  ('kuruma-gunma-b'),  -- [bronze] Kuruma
  ('kyo-seika-kyoto-b'),  -- [bronze] Kyo Seika
  ('kyoboshi-kyoto-b'),  -- [bronze] Kyoboshi
  ('kyogokuzushi-shiga-b'),  -- [bronze] Kyogokuzushi
  ('kyu-akita-b'),  -- [bronze] Kyu
  ('maekawa-ishikawa-b'),  -- [bronze] Maekawa
  ('manger-osaka-b'),  -- [bronze] MANGER
  ('manzan-chiba-b'),  -- [bronze] Manzan
  ('masachan-osaka-b'),  -- [bronze] Masachan
  ('masuda-tokyo-b'),  -- [bronze] Masuda
  ('masuki-hiroshima-b'),  -- [bronze] MASUKI
  ('matsuishi-miyagi-b'),  -- [bronze] Matsuishi
  ('matsuka-nagano-b'),  -- [bronze] Matsuka
  ('matsumoto-kobe-b'),  -- [bronze] Matsumoto
  ('matsuura-tokyo-b'),  -- [bronze] Matsuura
  ('meizan-kimiya-kagoshima-b'),  -- [bronze] Meizan Kimiya
  ('mikasa-kanagawa-b'),  -- [bronze] Mikasa
  ('mikawa-akita-b'),  -- [bronze] Mikawa
  ('mikawa-zezankyo-tokyo-b'),  -- [bronze] Mikawa Zezankyo
  ('mimuro-kumamoto-b'),  -- [bronze] Mimuro
  ('minato-sapporo-b'),  -- [bronze] Minato
  ('miyamoto-shizuoka-b'),  -- [bronze] Miyamoto
  ('mizukami-tokyo-b'),  -- [bronze] Mizukami
  ('mizuki-gifu-b'),  -- [bronze] Mizuki
  ('moe-es-tokyo-b'),  -- [bronze] Moe es
  ('muen-nagano-b'),  -- [bronze] Muen
  ('murakami-kumamoto-b'),  -- [bronze] Murakami
  ('musashino-saitama-b'),  -- [bronze] Musashino
  ('mutsuki-nagoya-b'),  -- [bronze] Mutsuki
  ('nakahara-tokyo-b'),  -- [bronze] NAKAHARA
  ('nakajo-kanagawa-b'),  -- [bronze] Nakajo
  ('nanachome-tokyo-b'),  -- [bronze] Nanachome
  ('narikura-tokyo-b'),  -- [bronze] Narikura
  ('nikawa-mie-b'),  -- [bronze] Nikawa
  ('nikutoieba-matsuda-nara-honten-nara-b'),  -- [bronze] Nikutoieba Matsuda Nara Honten
  ('nikuya-setsugekka-nagoya-nagoya-b'),  -- [bronze] Nikuya Setsugekka Nagoya
  ('noguchi-osaka-b'),  -- [bronze] Noguchi
  ('oga-osaka-b'),  -- [bronze] Oga
  ('ohata-osaka-b'),  -- [bronze] Ohata
  ('okagesan-miyagi-b'),  -- [bronze] Okagesan
  ('omino-tokyo-b'),  -- [bronze] Omino
  ('onza-shiga-b'),  -- [bronze] Onza
  ('osamu-fukuoka-b'),  -- [bronze] Osamu
  ('osamuchan-osaka-b'),  -- [bronze] Osamuchan
  ('otomezushi-kanazawa-b'),  -- [bronze] Otomezushi
  ('pome-osaka-b'),  -- [bronze] Pome
  ('ramen-feel-tokyo-b'),  -- [bronze] Ramen FeeL
  ('ranmaru-tokyo-b'),  -- [bronze] Ranmaru
  ('ribatei-kanagawa-b'),  -- [bronze] Ribatei
  ('rin-shizuoka-b'),  -- [bronze] Rin
  ('roan-matsuda-sasayama-sasayama-b'),  -- [bronze] Roan Matsuda Sasayama
  ('saeki-hanten-tokyo-b'),  -- [bronze] Saeki Hanten
  ('saeki-tokyo-b'),  -- [bronze] Saeki
  ('sakurabito-hyogo-b'),  -- [bronze] Sakurabito
  ('sato-briand-honten-tokyo-b'),  -- [bronze] SATO Briand Honten
  ('sato-briand-nigo-tokyo-b'),  -- [bronze] SATO Briand Nigo
  ('seiryuen-tokyo-b'),  -- [bronze] Seiryuen
  ('sen-kanagawa-b'),  -- [bronze] Sen
  ('sen-miyazaki-b'),  -- [bronze] Sen
  ('sense-tokyo-b'),  -- [bronze] SENSE
  ('setsugekka-tanaka-satoru-nagoya-b'),  -- [bronze] Setsugekka Tanaka Satoru
  ('shima-tokyo-b'),  -- [bronze] Shima
  ('shimbashi-shimizu-tokyo-b'),  -- [bronze] Shimbashi Shimizu
  ('shinois-tokyo-b'),  -- [bronze] ShinoiS
  ('shizuku-osaka-b'),  -- [bronze] Shizuku
  ('shoshinan-akita-b'),  -- [bronze] Shoshinan
  ('shota-sapporo-b'),  -- [bronze] Shota
  ('shutei-tanaka-tokyo-b'),  -- [bronze] Shutei Tanaka
  ('soshi-hiroshima-b'),  -- [bronze] Soshi
  ('steak-house-baron-kumamoto-b'),  -- [bronze] STEAK HOUSE Baron
  ('sudo-haruyoshi-fukuoka-b'),  -- [bronze] Sudo Haruyoshi
  ('sugaya-tokyo-b'),  -- [bronze] Sugaya
  ('sushi-ao-tokyo-b'),  -- [bronze] 스시 아오
  ('sushi-chiba-takaoka-tokyo-b'),  -- [bronze] Sushi Chiba Takaoka
  ('sushi-fujinaga-tokyo-b'),  -- [bronze] Sushi Fujinaga
  ('sushi-gyoten-fukuoka-b'),  -- [bronze] Sushi Gyoten
  ('sushi-hashiguchi-tokyo-b'),  -- [bronze] Sushi Hashiguchi
  ('sushi-josuke-kobe-b'),  -- [bronze] Sushi Josuke
  ('sushi-karashima-fukuoka-b'),  -- [bronze] Sushi Karashima
  ('sushi-kizuna-osaka-b'),  -- [bronze] Sushi Kizuna
  ('sushi-nakamura-kumamoto-b'),  -- [bronze] Sushi Nakamura
  ('sushi-riku-tokyo-b'),  -- [bronze] sushi riku
  ('sushi-sohei-sapporo-b'),  -- [bronze] Sushi Sohei
  ('sushi-suzuki-tokyo-b'),  -- [bronze] Sushi Suzuki
  ('sushi-taito-yatsushiro-b'),  -- [bronze] Sushi Taito
  ('sushi-takaoka-chiba-b'),  -- [bronze] Sushi Takaoka
  ('sushi-yasumitsu-tokyo-b'),  -- [bronze] Sushi Yasumitsu
  ('sushi-yuuki-tokyo-b'),  -- [bronze] Sushi Yuuki
  ('sushikin-sapporo-b'),  -- [bronze] Sushikin
  ('sushinokura-sapporo-b'),  -- [bronze] Sushinokura
  ('sushisai-wakichi-sapporo-b'),  -- [bronze] Sushisai Wakichi
  ('sushisho-akita-b'),  -- [bronze] Sushisho
  ('sushisho-saito-tokyo-b'),  -- [bronze] Sushisho Saito
  ('sushishunbi-nishikawa-nagoya-b'),  -- [bronze] Sushishunbi Nishikawa
  ('suzaki-shokuryohinten-kagawa-b'),  -- [bronze] Suzaki Shokuryohinten
  ('tada-osaka-b'),  -- [bronze] Tada
  ('takahashi-kentaro-osaka-b'),  -- [bronze] Takahashi Kentaro
  ('takarazushibunten-akita-b'),  -- [bronze] Takarazushibunten
  ('takumi-shingo-tokyo-b'),  -- [bronze] Takumi Shingo
  ('tamawarai-tokyo-b'),  -- [bronze] Tamawarai
  ('taniguchi-hyogo-b'),  -- [bronze] Taniguchi
  ('tashiro-aichi-b'),  -- [bronze] Tashiro
  ('teruzushi-kitakyushu-b'),  -- [bronze] TERUZUSHI
  ('tokiwa-sushi-niigata-ten-niigata-b'),  -- [bronze] Tokiwa Sushi Niigata Ten
  ('tokyo-nikushabuya-subin-tokyo-b'),  -- [bronze] Tokyo Nikushabuya Subin
  ('tokyo-nikushabuya-tokyo-b'),  -- [bronze] Tokyo Nikushabuya
  ('tokyoen-tokyo-b'),  -- [bronze] Tokyoen
  ('tomidokoro-tokyo-b'),  -- [bronze] Tomidokoro
  ('tomono-osaka-b'),  -- [bronze] TOMONO
  ('torila-fukuoka-b'),  -- [bronze] torila
  ('torisaki-kyoto-b'),  -- [bronze] Torisaki
  ('torishige-shizuoka-b'),  -- [bronze] Torishige
  ('torisho-ishii-hina-tokyo-b'),  -- [bronze] Torisho Ishii Hina
  ('torisho-tokyo-b'),  -- [bronze] Torisho
  ('toyonaga-osaka-b'),  -- [bronze] Toyonaga
  ('tsubasa-fukuoka-b'),  -- [bronze] Tsubasa
  ('tsuchiya-osaka-b'),  -- [bronze] Tsuchiya
  ('tsugumian-tokyo-b'),  -- [bronze] Tsugumian
  ('tsunechan-osaka-b'),  -- [bronze] Tsunechan
  ('tsuruhachi-kumamoto-b'),  -- [bronze] Tsuruhachi
  ('tsushima-tokyo-b'),  -- [bronze] Tsushima
  ('ueda-aichi-nagoya-b'),  -- [bronze] Ueda (Aichi)
  ('ueda-hyogo-kobe-b'),  -- [bronze] Ueda (Hyogo)
  ('uramatsu-tokyo-b'),  -- [bronze] Uramatsu
  ('ushigoro-s-ginza-tokyo-b'),  -- [bronze] USHIGORO S. GINZA
  ('vesta-tokyo-b'),  -- [bronze] Vesta
  ('wadakin-matsusaka-b'),  -- [bronze] Wadakin
  ('wagyu-lab-k-hiroshima-b'),  -- [bronze] Wagyu lab K
  ('woniku-osaka-b'),  -- [bronze] Woniku
  ('yamamoto-hiroshima-b'),  -- [bronze] Yamamoto
  ('yamanomi-nagano-b'),  -- [bronze] Yamanomi
  ('yamasei-nagano-b'),  -- [bronze] Yamasei
  ('yamato-tokyo-b'),  -- [bronze] Yamato
  ('yassan-kyoto-b'),  -- [bronze] Yassan
  ('yoroniku-tokyo-b'),  -- [bronze] Yoroniku
  ('yoshida-fukuoka-b'),  -- [bronze] Yoshida
  ('yoshitake-tokyo-b'),  -- [bronze] Yoshitake
  ('yuji-tokyo-b'),  -- [bronze] Yuji
  ('zaisho-fukuoka-b')   -- [bronze] Zaisho
) as t(vid)
on conflict (venue_id) do nothing;

do $$
declare n_total int; n_on int;
begin
  select count(*) into n_total from public.venue_partners;
  select count(*) into n_on    from public.venue_partners where is_partner = true;
  raise notice '✅ Gold+Silver+Bronze 후보 추가 완료 — 전체 %곳 / 노출(ON) %곳. 관리 화면에서 노출 토글하세요.', n_total, n_on;
end $$;
