# CWeatherScene port notes (Sources/Forecast/Scene)

## PTMF table lbl_80199AA8 (+off → function)  [state PTMF +C0 / draw PTMF +CC]
D4 fn_800172A0 (address fly-to) · E0 StE6B8 (address draw) · EC StNormal · F8 StConnect · 104 StFAE4 (settings) ·
110 StE6C8 (hub/globe draw) · 11C/128/134 CNormal_StPassive · 140 StF660 (globe) · 14C/164 fn_8002721C · 158 StFAE4 ·
170 StF660 · 17C StE6C8 · 188/194 CAround_StInteractive · 1A0 fn_80027270 · 1AC/1B8 StNormal · 1C4 StE6C0 (settings draw) ·
1D0 StConnect · 1DC StNormal · 1E8 StAddress · 1F4 StE7EC (connect draw) · 200.. StE7F4 (message draw).
lbl_80199B40 = StNormal, lbl_80199B4C = StAddress (fn_8000E078 targets).
=> notes/scenes.md had StFAE4/StF660 swapped: StFAE4 = settings (CSetting), StF660 = globe (CAround).

## States as ported (WeatherScene.swift)
- boot: CConnect (ForecastService replaces NWC24) → SaveData_Load → CMessage {ok&match → hub; mismatch 3; nofile 1 (date/time yes/no, error3); broken 2; nand 4} → fn_8000E078.
- fn_8000E078: units from save, else forecast header regionFlag (1 → °F+mph, else °C+km/h); location = country<<24 when unsaved.
- address: request 2 → store save → hub; request 4 → settings. CAddress: city list of the user's region + "other regions" row (wide string table lbl_80199428) → region list; row band FFFFFF40 / hover 8CB4B4FF (static init fn_80017494 / fn_8003F4D0), row 60 px from y 100, list clip y 103..456, text 0x111-centred.
- hub (StNormal): request 5 → dim (fade2 0x14, step 12/frame, wait 40) → globe reset to home city → globe; 4 → settings; 3 (not top level) → globe.
- globe (StF660): request 3 → back to hub (fade2 0xC, wait 30, SELF BGM); request 6 → marker's city pages (hub not top level).
- settings (StFAE4): request 1 → address (back enabled); request 2 → store save → hub.
- connectError (StConnect): CMessage 4 (store 3) / 5.
- CMessage types: 1 error3 yes/no + date "%02d/%02d/%04d %02d:%02d" (read from DOL, lbl_80199018+0x16C); 0/2/3 error4 OK (text 0 type 2, 1 type 3); 4/5/6 error2 fatal → Wii Menu (texts 1/2/0). "No" on the date → type 6.
- CConnect error0 index map and "%ls %ls%06d" error code (strings rel. lbl_80198D80) as fn_8000B46C/fn_8000B9C8; progress dots fn_8000B6B0 (TPLWeather images lbl_80179358 [+0x18 non-JP], 40 px apart, 0.6 scale, 12-frame chase); SE 0x17 loop while waiting.
- BGM: 4 layers {cur,target,step} with steps from rodata 0x80179400/10 (day in/out) and 0x80179420/30 (night); ED20 SELF, F4B8 globe group, E7FC option; silent layers paused (fn_8000DD84).
- Settings: value rows glow LerpU8(0x40,0xC0,hover/12) via CPaneCtl brightness; JP hides wind rows, others hide `text`.

## Deviations
- wbf1.brfna (console system font) is not in the title; free text uses font_weather_city.brfnt.
- NWC24 result codes are synthesized from URLError (no-connection → -9, other → -1).
- Address fly-to wait is 40 frames (fn_800172A0's exact wait not traced).
