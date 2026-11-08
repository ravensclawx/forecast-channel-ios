# Hub (CNormal) — port notes

Swift: `Sources/Forecast/Scene/Normal/{NormalScreen,HubPages}.swift`, `Sources/Forecast/UI/{SpriteText,TelopText}.swift`,
`Sources/Forecast/Render/LytRenderer+Sprites.swift`. Preview: `renderHub(path:page:)` in `Sources/fcdump/HubPreview.swift`.

## Structure (ctor fn_80020F9C)
- Layouts: forecast.brlyt (+0 buttons), base.brlyt (+4 plate; alpha 255 top level, 128 otherwise), base_belt.brlyt (+8),
  day_6h_nWW.brlyt (+C).
- Pages stacked vertically: page i centred at y = 228 + 456·i, scroll target = 456·i; page offset = (0, scroll − 456·i);
  layouts translated by it, data drawn at anchor.y − offset.y. US order: 0 UV (fn_80011100), 1 Current (fn_80010C30),
  2 Today (fn_8001230C), 3 Tomorrow (fn_80012A1C), 4 5-Day (fn_8001312C). Belt title index = page index.
- Scroll (fn_80025CF8): ChaseValue(scroll, target, 0.1125, 100, 1); SE 0x29. Belt title/clock alpha step ±0x10/frame
  (fn_80025B58); title variant swaps while invisible.
- up/down captions = neighbour page names (upT children 0..3 → index cur−1, downT 1..4 → index cur), disabled at ends.
- Buttons (CNormal_StInteractive fn_800227B0): set → SE 0x25, request 4; back → (top level: SE 0x25 + return-to-Wii-Menu)
  SE 0x26, request 3; around → SE 0, request 5. d-pad up/down flash the buttons.
- 6-hour strip (fn_80025FA8): state machine 0x800/frame to 0x8000 (16 frames, sin ease), dim quad alpha 40·t.

## Sprites (d_scene.cpp) — tables read from main.dol at runtime
- Records lbl_801F6E80 = {lbl_8018F4E8[i] TPLCommon image, w, h} for i < 0x59.
- Small table lbl_8018F668 (digits, '-', JP weekday kanji) → records 0..17; large table lbl_8018F6D0 (digits, '-',
  'C', 'F', 0xFF9F degree) → records 0x21+.
- DrawSpriteString: first glyph centred on the point; advance scale·(−1 + ½prevW + ½curW); shadow pass at +2,+2.
- Weather icon fn_80020574: jumptable_8019AF48[code&0x7FFF] → `lis/addi` → layer list (0x18 bytes:
  {u32 TPLWeather image, f32 dx, dy, scale, rgba main, rgba shadow}, 0xFFFFFFFF ends). Night bit: image 4→1, 15→0xB.
  Codes < 0x64 draw a shadow (+2,+2). Unknown codes draw "--".
- Weekday sprites: TPLCommon image lbl_80179CFC[lang·7 + wday]; Sat/Sun lbl_80330A40, others lbl_80330A1C; shadow +3,+3.
- Wind text: direction names lbl_801994D8 (US) / lbl_80199748 (EU) [lang·0x11 + dir], unit names lbl_801999B0 /
  lbl_80199A70 [lang·2 + unit]; right-aligned (draw flag 0x122) in `wind_telop`.
- Colours (fn_80010728): white A0C, shadow A10/A20 (0x20), red A14, cyan A18, grey A1C, pink A24, blue A30,
  light cyan A3C, yellow A40.
- 5-Day anchors (fn_80013738): names lbl_8019A268+0x498, scales lbl_801797B8 (youbi 1.0, everything else 0.5);
  high → A40, low → A3C. Columns start at tomorrow (entry time + 0x5A0 min each) and read week[0..4].
- Day pages (non-JP) colour the temperature anchors A40 (fn_8001230C).
- UV page: number = UV table id at life_b_1-1/-10/-100 (one digit per anchor), description in life_b_telop.

## Belt / strip (verified against the Dolphin reference research/reference/hub_current.png)
- Title alternation fn_80026B34 (state +828, timer +824 = 0xF0): page title 240 frames → fade (±0x10/frame, +810→+814)
  → weekday title (index 5 + wday) 240 frames → fade back. Weekday per page (fn_8002698C, US): UV → today, Current →
  current-conditions entry time, Today → long-forecast time, Tomorrow → +0x5A0 min, 5-Day → page title only.
- City telop (CNormal_SetupCityTelop fn_80022D2C + draw in fn_80023E58 + ticker fn_80027998): lines city → region →
  country, each fitted on X only to the city box width (+798 − +790); drawn with the system font (lbl_80330BDC = wbf1)
  at x = box right (+798), y = box centre + scroll + i·50, flag 0x122, scale (fit, 1.0), shadow 0x20 at +1,+1, inside a
  scissor band y 74..124. Ticker: hold 240 frames, ChaseValue(+7D8, lbl_8017B440[i] = {0, −50, −100}, 0.1, 10, 0.5).
- Timestamp (no clock): fn_8002322C picks the entry time (Current page → current-conditions entry, else long/summary
  forecast entry), US formatter fn_80023430 builds lbl_8019BC2C[lang] + h:mm + lbl_8032FF68 + *lbl_803300F8|FC (a.m./p.m.)
  + lbl_8032FF6C + MM/DD; system font, scale 0.6 (x shrunk to fit 1.3684·timeWW width), at (W − 36, 228 − timeWW.y),
  flag 0x122, alpha +81C.
- base_belt: fn_800393E8(belt_time, "belt_timeB") hides every belt_timeB<lang> except the current language.
- Fixed ('F'/'f') CPaneCtl wrappers are never alpha-written by CPaneCtl_PreDraw (+99 defaults to 1); Pane_SetAlphaRec
  writes material element 0xB (TEV colour 1 alpha), not pane alpha. (Hub restores authored pane alphas locally.)
- Credit: CWeatherScene's draw (after fn_80023E58) draws TPLWeather image 0x18 + ((lbl_803309F8>>1)&1) (JP 0x16) at
  (28/36, 365 + lbl_803309D8); TPLCommon image 3/6 below it when the hub isn't top level.
- Temperatures: degree glyph only ("34°") for both units. Single-line telops are width-fitted only (wind "SSE 10 mph"
  draws at scale 1.0 in the 28 px box).

## Gaps / approximations
- Day/current anchor scales were not traced (1.0 used; 6-hour icons 0.7). UV day selection (today vs tomorrow after the
  date rolls, fn_80011BD8) uses today.

## Verified 2026-11-07 (QA pass)
- CNormal slots (ctor 0x800215AC): +10 "around", +14 "set", +18 "back", +1C "up", +20 "down". Off the top level
  (hub opened from a globe marker) CNormal_StInteractive disables + presses **around and set**; back shows backI/"Back".
- CPaneCtl_Press sets +96 on itself but +95 (hover) only on its child wrappers (+24/+28) — a disabled wrapper pressed
  every frame keeps its normal body colour; PreDraw zeroes text/icon alpha for disabled (+98) wrappers.
- WeatherScene_StE6C8 (hub draw) = GlobeScreen_Draw (earth + markers; globe layouts only while CAround +24F) then
  fn_80023E58. +24F cleared by StF660 when the hub takes over (0x8000F6A4 / 0x8000F9F4), set by StNormal 0x8000F3A4
  and fn_8001BECC.
- Globe temperature numbers (fn_8003F088 → fn_8003F214): #202020 shadow at (+2,+2) first, then the digits in the
  temperature colour (fn_800099CC). TEV (C1, TEXC, C0, C1) with C1 = 0 from Setup2DRender = TEXC·C0.
- StFAE4 step 4 (settings → change city) starts the fade-in before switching to StAddress; step 3 stores the save
  only if location/units changed.
