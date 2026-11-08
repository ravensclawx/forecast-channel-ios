# HOME Button Menu (HBM) — functional decomp notes (main.dol, HAFE v7)

Library: RVL SDK "HBM" (`<< RVL_SDK - HBM release build: May 16 2007 >>`), linked at ~0x80071FD8–0x8007FCC0.
Port: `Sources/Forecast/HomeMenu/` (HomeMenu.swift, HBMTables.swift, HBMMessages.swift).

## Public API wrappers (C ABI) → HomeButton methods
| wrapper | callee | role (inferred from args/use) |
|---|---|---|
| fn_80071FD8 | fn_80072698 / fn_80072A34 | HBMCreate(HBMDataInfo*) → HomeButton ctor (loads layout + anims, builds anim/group objects) |
| fn_80072100 | fn_800727AC | HBMInit |
| fn_80072184 | fn_80073574 | HBMUpdate(controllers) — input; also sets timers 3600/3570 frames (/frameDelta) |
| fn_800721B0 | fn_80073E74 | HBMCalc — per-frame state machine (states 0..0x13), returns ≥0 when finished |
| fn_80072320 | — | HBMGetSelectBtnNum |
| fn_800721F4 / fn_80072530 / fn_800725EC / fn_80072620 | 8007B374 / 8007B52C / 8007B68C / 8007D6F4 | draw / delete / sound update |

## Channel side (d_scene area)
- fn_8002D6F8 (per frame): if not open and any KPAD trig has HOME (0x8000) → open. Copies KPADStatus for 4 channels,
  pointer scale `1.2 × (wide ? 1.1666666 : 1)`, then HBMCalc. When it returns ≥0, HBMGetSelectBtnNum:
  1 → result 1 (Wii Menu), 2 → result 2 (Reset), 3 → Operations Guide (only when a manual exists, unk1C ≥ 2).
- Message file: the channel uses its **own** `home_nosave.csv.LZ` (content 9), not HomeButton3/home.csv.
- Archives: `HomeButton3/LZ77_homeBtn.arc` (anims) + `HomeButton3/LZ77_homeBtn_ENG.arc` (layouts/textures per language),
  `HomeButton3/config.txt` = `th_HomeBtn_c.brlyt,th_HomeBtn_c,1,1,0` (layout, anim prefix, flags), sounds
  `Huf8_HomeButtonSe.brsar`, speaker sounds `Huf8_SpeakerSe.arc`.

## Message file (home_nosave.csv)
UTF-16 text of 28 quoted strings = 4 rows × 7 languages (JP, EN, DE, FR, ES, IT, NL), row-major.
Row 0 = Wii Remote connect instructions (T_msg_00), row 1 = short line (T_msg_01), row 2 = Wii Menu confirmation,
row 3 = Reset confirmation. Big button i uses row i+2. Text is copied into T_Dialog up to the closing quote.

## Animation objects
Anim files `th_HomeBtn_c_<suffix>.brlan`. Three binding tables:
1. Big buttons (lbl_80193DC8): for button i in 0..3: (btnL_i_inOut, cntBtn_in), (btnL_i_inOut, cntBtn_out), (btnL_i_psh, cntBtn_psh).
   The 'c' layout has 3 big buttons (btnL_00, btnL_01, btnL_10).
2. 15 one-to-one (anim suffix == group name): ltrIcn_on, optn_bar_psh, close_bar_psh, hmMenu_bar_in, hmMenu_bar_psh,
   link_msg_in, link_msg_out, cmn_msg_in, cmn_msg_out, cntrl_up, cntrl_wndw_opn, cntrl_dwn, hmMenu_bar_out, cmn_msg_rtrn, 12btn_on.
3. 74 (group, anim) pairs (lbl_80193E28). Group index space: 0 hmMenu_strt, 1 hmMenu_fnsh, 2 hmMenuBck_strt,
   3 hmMenuBck_fnsh, 4 optn_bar_in, 5 optn_bar_out, 6–10 optnBtn_{00,01,10,11,20}_inOut, 11–15 optnBtn_{..}_psh,
   16 optnBtn_10_cntrl, 17/18 msgBtn_00/01_inOut, 19/20 msgBtn_00/01_psh, 21–30 vol_00..09, 31–34 plyr_00..03.
   Anim index space: 0 hmMenu_strt, 1 hmMenu_fnsh, 2 optn_bar_in, 3 optn_bar_out, 4 optn_btn_in, 5 optn_btn_psh,
   6 vb_btn_wht_psh, 7 optn_btn_out, 8 vb_btn_ylw_psh, 9 sound_gry, 10 sound_ylw, 11 cmn_msg_btn_in, 12 cmn_msg_btn_out,
   13 cmn_msg_btn_psh, 14 vb_btn_ylw_ylw, 15 btry_wink, 16 btry_gry, 17 btry_wht, 18 btry_wink_gry, 19 close_bar_in,
   20 close_bar_out, 21 btry_red. (Table values transcribed into HBMTables.swift.)
Animations bind to a layout group (only that group's panes/materials) and play once from frame 0; "playing" flag
(+0x14) is what the state machine waits on.

## Hit test (fn_8007AEC8)
Bounding panes in order: B_btnL_00, B_btnL_01, B_btnL_10 (big buttons, count = unk8), then B_btn_00 (top bar = close),
B_bar_10 (bottom bar), B_optnBtn_00 (vol −), B_optnBtn_01 (vol +), B_optnBtn_10 / B_optnBtn_11 (rumble), B_optnBtn_20
(connect), cntrl_00 (Wii Remote picture). In the dialog: B_BtnA = Yes, B_BtnB = No (handler cases 7/8).
Hover enter: inOut "in" anim + SE 4 (FOCUS); leave: "out".

## Press handling (fn_80079448 / fn_8007699C), interactive state 2
- Big button i: psh anim + SE 5 SELECT. If its confirm bit is set (HBMDataInfo +0x24, bit i): show dialog
  (cmn_msg_in, msgBtn_00/01_inOut in, T_Dialog = row i+2) → state 0xB. Else finish directly (state 0xF).
- Top bar (B_btn_00): hmMenu_bar_psh, SE 1 RETURN_APP → close (hmMenu_fnsh), select 0.
- Bottom bar / cntrl_00: toggle the Wii Remote settings panel. Open: optn_bar_psh, cntrl_up + cntrl_wndw_opn,
  optnBtn_*_inOut in, SE 5 then SE 7 (OPEN_CONTROLLER). Close: cntrl_dwn, optn_bar_out + close_bar_out, SE 8.
- Volume (panel open; also Minus/Plus buttons on the remote): level 0..10 shown by vol_00..09 groups
  (sound_ylw = lit, sound_gry = unlit). − : SE 0xA, at 0 → SE 0xC (limit); + : SE 9, at 10 → SE 0xB; already at
  the limit → SE 0xD NOTHING_DONE. Applies speaker volume level/10 to all 4 remotes.
- Rumble on (B_optnBtn_10): SE 0xE, vb_btn_ylw_psh / ylw_ylw; off (B_optnBtn_11): SE 0xF, vb_btn_wht_psh.
- Connect (B_optnBtn_20): hides battery icons, SE 5 + 0x10 START_CONNECT_WINDOW, link_msg_in with T_msg_00/01,
  30-frame timer, then waits up to 180 frames polling WPAD; closes with SE 0x15 END_CONNECT_WINDOW, link_msg_out.
- Dialog Yes: msgBtn_00_psh + SE 2 (Wii Menu) or SE 3 (Reset); No: msgBtn_01_psh + SE 6 CANCEL → cmn_msg_out.
- B button: closes the settings panel or dialog if open (cancel), otherwise closes the menu like the top bar.

## Open / close
- Open (state 0): SE 0 HOME_BUTTON. If the "background" flag (HBMDataInfo +0x18) is set → hmMenuBck_strt with back_02
  shown / back_00 hidden; else hmMenu_strt with back_00 shown. Letter icon (ltrIcn_on) loops if new mail.
- Battery (groups plyr_00..03): btry_wht (normal), btry_red (low), btry_gry (not connected), btry_wink* blink.
- Finish: hmMenu_fnsh (or hmMenuBck_fnsh). For Wii Menu/Reset the library fades the game's master volume
  (AX master volume = 32768 × remaining/duration) and all HBM-archive voices to 0 over the finish animation,
  then reports the selection; the channel shows a black screen and exits.
- Backdrop: the HBM does not capture the frame itself — the game keeps its last frame and HBM draws over it;
  `back_00` is the translucent dimmer, `back_02` the alternative backing.

## Uncertain
- m2c output for fn_80073E74 has broken switch fallthroughs; the state order above is reconstructed from which
  anims/flags each case touches. Exact frames between sub-steps come from the BRLAN frame sizes.
- Meaning of the 3600/3570-frame timers (unk5C8/unk5CC): a 60 s watchdog on the connect/battery flow.
