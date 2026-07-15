-- 후쿠오카 큐레이션 41곳 → 슈퍼어드민 전용 시드 (우종 제공, 2026-07)
-- name=한글, name_local=일본어, region=후쿠오카, naver_map_url=구글맵 링크(앱에서 지도버튼으로 사용)
-- super_admin_only=true(회원 비공개), verified_by_taam=false, source_type='manual'
-- ▶ super_admin_only.sql 실행돼 있어야 함. 재실행해도 같은 이름 중복 안 됨(NOT EXISTS).
-- 장르 매핑: 스시야→스시 / 일식·캇포→가이세키 / 야키니쿠→야키니쿠 / 프렌치·이탈리안→양식
--            / 야키토리→야키토리 / 우나기→우나기 / 기타→일본요리 (필요시 편집화면에서 조정)

INSERT INTO public.restaurants (name, name_local, region, genre, naver_map_url, country_en, super_admin_only, verified_by_taam, source_type)
SELECT v.name, v.jp, '후쿠오카', v.genre, v.url, 'Japan', true, false, 'manual'
FROM (VALUES
  -- 스시 (12)
  ('스시사카이','鮨 さかい','스시','https://maps.app.goo.gl/JYuoF4gUSSiJx8do7'),
  ('가호진','我逢人','스시','https://maps.app.goo.gl/sbq1Z7S84AYvJMF6A'),
  ('자이쇼','在掌','스시','https://maps.app.goo.gl/7S9Waxk5mD7DGTV46'),
  ('치카마츠','近松','스시','https://maps.app.goo.gl/u9uMw7oyrMkKWxJo6'),
  ('스시 카라시마','鮨 唐島','스시','https://maps.app.goo.gl/4uFJSHk8kRvxsskb8'),
  ('코탄','枯淡','스시','https://maps.app.goo.gl/hZ1tX8umjZXaQcBc8'),
  ('스시 센파치','鮨 仙八','스시','https://maps.app.goo.gl/Hi9wgqs6kQmcxu4t6'),
  ('스시 오가','鮓 枉駕','스시','https://maps.app.goo.gl/ZFfZtUknafBXezHH9'),
  ('스시 코토쿠','すし幸德','스시','https://maps.app.goo.gl/DuS5xoFjSa4mE8u48'),
  ('스시도코로 이시바시','寿し處 石ばし','스시','https://maps.app.goo.gl/6iLpQxK4DY99HBtu8'),
  ('스시 카즈야','鮨かず矢','스시','https://maps.app.goo.gl/sAQnzAmnf86kDTyK7'),
  ('코야나기 스시','小柳寿司','스시','https://maps.app.goo.gl/TSmxpbnFvX6fcrkY6'),
  -- 일식·캇포 (10)
  ('이모토','井本','가이세키','https://maps.app.goo.gl/FALnnLkvPwe535ir6'),
  ('오료리 야마노쿠치','お料理 山乃口','가이세키','https://maps.app.goo.gl/sYquWXRjFzowpeN4A'),
  ('아카사카 후지타','赤坂 藤田','가이세키','https://maps.app.goo.gl/u3PNGjXKhm6S8suP9'),
  ('잇폰기 이시바시','一本木石橋','가이세키','https://maps.app.goo.gl/b9UrDrB6G7rJcfXk9'),
  ('나카무타','食と酒 なかむた 薬院','가이세키','https://maps.app.goo.gl/m9VS7jH475ySD1EDA'),
  ('다이도코로','大どころ','가이세키','https://maps.app.goo.gl/K4urDKMfQH35PXy16'),
  ('우치야마','お料理 うち山','가이세키','https://maps.app.goo.gl/fWhq2Us7vUijEdV29'),
  ('아지 타케바야시','味竹林','가이세키','https://maps.app.goo.gl/DEwZ1s8cAMA66ZSz6'),
  ('료리 센스이','料理 千翠','가이세키','https://maps.app.goo.gl/SLyaA15gqi3xeKcw9'),
  ('이무리','IMURI','가이세키','https://maps.app.goo.gl/B84rgQLezipsy1vw7'),
  -- 야키니쿠 (3)
  ('야키니쿠 스도 하루요시','焼肉 すどう 春吉','야키니쿠','https://maps.app.goo.gl/TP543FvXETAx5rD79'),
  ('리키한텐','力飯店','야키니쿠','https://maps.app.goo.gl/ycGFVMxhWDJys5EU7'),
  ('유키','游來','야키니쿠','https://maps.app.goo.gl/MFRZ3p7WYrVFCezM8'),
  -- 프렌치·이탈리안 (3)
  ('조르쥬 마르소','レストラン・ジョルジュマルソー','양식','https://maps.app.goo.gl/5uMMPLD95jEGyx5U7'),
  ('팡파레','Ristorante fanfare','양식','https://maps.app.goo.gl/JGSra9CjxgjhDGFy6'),
  ('나카가와','なかがわ','양식','https://maps.app.goo.gl/v3Q3TeDePTSNanSj6'),
  -- 야키토리 (4)
  ('야키토리 토리라','とりら','야키토리','https://maps.app.goo.gl/7ZTmrVCNm1QQFsta6'),
  ('야키토리 코토','焼き鳥 こと','야키토리','https://maps.app.goo.gl/VziBkJjuM7sUewn26'),
  ('야키토리 마코','焼鳥 まこ','야키토리','https://maps.app.goo.gl/kkbR9bhH1NbEkove6'),
  ('하카타 토리카와야키 구','博多とりかわ焼 隅-ぐう-','야키토리','https://maps.app.goo.gl/UGQBcik2fKY3z7QU8'),
  -- 우나기 (2)
  ('요시즈카 우나기야','博多名代 吉塚うなぎ屋','우나기','https://maps.app.goo.gl/c14PBdrGTnaqxyjRA'),
  ('우나기 도코로 야마미치','うなぎ処山道','우나기','https://maps.app.goo.gl/2iSeDWBv96FcmL859'),
  -- 기타 (7)
  ('텐코','天孝','일본요리','https://maps.app.goo.gl/6T5st4tXdSf4juvz7'),
  ('토아히스','トアヒス','일본요리','https://maps.app.goo.gl/BbA2M9kpsxswDQuj8'),
  ('햐쿠시키','百式','일본요리','https://maps.app.goo.gl/TtCdM9E17p8qp6DU9'),
  ('킨츠타','金蔦本店','일본요리','https://maps.app.goo.gl/BeD19totJvck3yjW9'),
  ('토리덴','博多水炊き とり田 薬院店','일본요리','https://maps.app.goo.gl/wyEP3RsQMLVWBkRo9'),
  ('스이게츠','水月','일본요리','https://maps.app.goo.gl/7bXXgRACzFRQZHYH7'),
  ('다이다이','博多水炊き専門 橙','일본요리','https://maps.app.goo.gl/mvQfyFg3j62DpBs48')
) AS v(name, jp, genre, url)
WHERE NOT EXISTS (
  SELECT 1 FROM public.restaurants r WHERE r.name = v.name
);
