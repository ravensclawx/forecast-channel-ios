# Operations Guide (electronic manual)

Only trigger: HOME Menu button 3 ("Operations Guide"). No in-channel help/notice page opens the browser.

## Launch path
- CScene_ctor (0x8003B4D4): start URL by region/language — JP `arc:/html/index/index_Frameset.html` (lbl_803301D0),
  US table lbl_8019C1D0+0xB4[lang] = {0, startup.html, 0, startup_fra.html, startup_esp.html, 0, 0}, EU +0x124.
  Archive name lbl_8019C1D0+0x34[region] = html-jp/us/eu.arc (content 10). CContentArc_ctor(8, arc, url, …).
- CContentArc (0x8002D1D4, the HBM wrapper): +0x28 start URL, +0x2C last URL (strncpy 0x1FF).
- fn_8002D6F8: HBMGetSelectBtnNum()==3 and +1C ≥ 2 → +10 (manual pending); when the earth model is loaded (+E):
  fn_8003C054, unload earth (+F), fn_8002DDCC; reload earth, fn_8003BF08, CFade_StartFadeIn(0xF).
- fn_8002DDCC: loads the arc, WWW browser 0x328×0x1C8 (wide) / 0x260×0x1C8, fn_80083CA4(start URL),
  fn_80083CA0(draw cb fn_8002E1A0, +0x2C, channel) → returns the current URL → copied to +0x2C (resume next time).

## Manual library (DOL side; the engine is wwwlib-rvl.lz7 in content 2, font WiiNTLG-Regular.ttc content 3)
- Main loop fn_80083878; input fn_80082544/fn_800822BC (Wii Remote) / fn_800823D0 (Classic):
  A→1 click (move+down+up in one frame, fn_80082B64), ↑→8 / ↓→4 wheel ∓1 (fn_80082D48; repeat after 16 frames,
  then every frame if width > 640, else every 2), −→0x10 previous page (lbl_80330F50), +→0x20 start page
  (SE 5 unless already there), HOME→0x40 close (SE 3). Non-A buttons need DF0 == 15 and no load in progress.
- vcJavaScriptExt (fn_80081B18): FadeIn/LeftScroll/RightScroll set transition 0/1/2 (+SE 1 for the scrolls),
  FocusSound → SE 0 (only when idle), SelectSound → flag: next navigation plays SE 5 (start page) or SE 1.
- fn_8007E2A8(n) → HBM SE (fn_80072354): 0→0x17, 1→0x18, 2→0x16 (first page shown), 3→0x1B, 5→0x1A;
  same n within 3 frames dropped.
- fn_800809B8: page change after load in 15 frames: old page alpha 255−255t/15; with LeftScroll/RightScroll both
  slide by 0.15·width (new from −(15−t)·d, old to t·d, d = ±1/15). Scroll display chases Opera's scroll: v += 2/frame
  up to 40, braking v = 2(√(d+¼)−½).
- Cursor: per-player tinted 50×50 hand (lbl_801B5498 colours, P1 = 0,0x8C,0xFF) from arc/timg/defcursor_final*.

Port: Sources/Forecast/Manual/ (WKWebView + `wiiarc:` scheme serving the archive from memory, Metal compositing).

## Follow-up (cursor, sound, scroll step)
- Cursor fn_8007E37C/fn_8007E67C: HBM language arc `arc/timg/defcursor_final64_a.tpl` (IA4 shade/alpha, TEXMAP1) +
  `defcursor_final_p1..4.tpl` (I4 hand, TEXMAP0). TEV: lerp(C0 player colour, C1 white, hand) × shade; alpha
  A2 × shade.a, A2 = visibility (+0: +0x32/frame with input or motion, −1/frame, cap 0x5DC → alpha min(+0/3, 0xC0)).
  50×50, hotspot (0.38, 0.92 from the bottom), rotated by the KPAD horizon. Port: Manual/ManualCursor.swift.
- Sound: fn_8002DDCC/fn_8002D6F8 make no sound calls. HBM open (fn_80073AFC) saves AX master/aux volumes, installs
  its AXFX aux callback, sets master 0x8000, aux returns 0; finish (fn_80073E74 states 0x10/0x11) fades master and
  HBM voices only if HBMGetSelectBtnNum (+B0) != 3; state 17 restores the saved AX settings. → BGM continues at
  normal volume during the manual; fn_80041F54 does not run (game loop blocked in fn_80083878).
- Opera scroll step: wwwlib-rvl.lz7 is an uncompressed RSO (www_no_font.plf). Its internal relocations give the
  prefs table at file 0x522A20; entry 12 "Scroll Step" = 50, 13 "Scroll Step Handheld" = 25, 14 Horizontal = 5.
  WWWSetRenderingMode (export 0xC8 → 0x6B9E4 → 0x6D704) maps game mode 6 → window LayoutMode 0 (normal; modes
  0–4 → LayoutMode 1–5), so the normal 50-px step applies. WWWSurfaceWheelEvt (0x2C → 0x6A540 → 0x721D0)
  dispatches the delta through a virtual OnMouseWheel chain (vtable +52); the core's delta→pixels code was not
  located (no symbols, virtual dispatch, pref read not found by the li r4,12 pattern), so "1 unit = 1 Scroll Step"
  is the remaining assumption.
