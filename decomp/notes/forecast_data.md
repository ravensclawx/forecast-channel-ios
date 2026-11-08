# Forecast data path — functional decomp (main.dol, HAFE v7)

Raw m2c: `decomp/build/m2c/data1.c … data4.c`. Port: `Sources/Forecast/Data/` (ForecastFormat.swift is the parser/validator).

## 1. Download (Connect.cpp / WiiConnect24.cpp)
- `fn_8000AC44` (connection object init) formats both URLs with `sprintf`:
  `http://weather.wapp.wii.com/%d/%03d/forecast.bin` and `…/short.bin`, args = (`lbl_80330B36`, `lbl_80330B38 >> 24`).
  - `lbl_80330B36` = **console language** (`fn_8002C124`, set in `fn_8002F3D0` boot; 1 = English).
  - `lbl_80330B38` = SYSCONF address code (`fn_801177B4`), **top byte = Wii country code** (049 = USA).
    If unset (−1): defaults by region type `lbl_80330B3C` (`fn_8002C0CC`): 0 JP → 0x01, 1 US → 0x31 (49), 2 EU → 0x4E (78).
  - US English ⇒ `http://weather.wapp.wii.com/1/049/forecast.bin`.
- `fn_80034B78` registers NWC24 download tasks: filename `"%d.bin"` with task ids **3 (forecast)** and **4 (short)**,
  `NWC24SetDlPriority(100)`, `NWC24SetDlFlags(0x40000000)`, `NWC24SetDlInterval(arg)` (caller `fn_80033C80` passes 0x1E/0x3C;
  m2c argument numbering suggests the interval is 0x1E = 30 min — unverified), `NWC24SetDlRetryMargin(720)`. VF drive `@24`.
- Files arrive in the WC24 VF already **signature-checked by NWC24/IOS** (the channel never verifies RSA). The channel
  reads them, LZ-decompresses (`CXGetCompressionType` / `CXGetUncompressedSize` / `CXUncompressLZ`, error strings at
  0x8019C11C) and validates.
- Served container (from the server, before NWC24 strips it): `0x40` header (zero, unencrypted) + `0x100` RSA-2048
  PKCS#1v1.5 SHA-1 signature + LZ10/LZ11 payload. **The port's loader skips signature verification** (same as Dolphin
  + RiiConnect24/WiiLink setups); our generator writes zeros there (`WC24Container`).

## 2. Validation — `fn_8000C734(forecast, fsize, &fErr, short, ssize, &sErr)` → bool
`now = fn_8000D4C8()` = minutes since 2000-01-01 00:00 (local RTC). Error values: **−1 corrupt, −2 expired, −3 bad version**.
Both files:
- all table offsets 4-aligned; `version & 0xFFFF0000` → −3; `size == fileSize`; `crc == CRC32(data[0xC..size])`
  (`fn_80067D44`: reflected 0xEDB88320, init ~0, final ~); `expires(0x10) < now` → −2; `language(0x18) == lbl_80330B36`.
forecast.bin:
- `message(0x1C)` < size, even; **if non-zero and no error, return OK immediately** (message mode → `ERROR_MESSAGE_e`).
- `0x19 ≤ 2`, `0x1A ≤ 1`; every table `off + count·stride ≤ size`.
- Long (0x80): place id appears exactly once in places; `0xC ≤ 5 || 0xFF`; 2 days via `fn_8000D1EC`, 7 week days via `fn_8000D450`.
- Summary (0x48): same, 2 days.
- Weather types / UV / laundry / pollen: unique id; text offset even and < size.
- Places: unique id; must appear in long ∪ summary ∪ short.bin; text offsets even < size; `0x14 ≤ 9`; `0x15 ≤ 3`.
- `fn_8000D1EC` day: weather + 4 slot codes ∈ weather table (or 0xFFFF); 4 precip ≤100|0xFF; wind dir ≤16|0xFF;
  UV id ∈ UV table (or 0xFF); laundry/pollen ids checked **only when region type == 0 (JP)**.
- `fn_8000D450` week day: weather ∈ table|0xFFFF; precip(6) ≤100|0xFF.
short.bin: `count·0x18 + off ≤ size`; entry place id ∈ places exactly once; weather ∈ table|0xFFFF; `0xE ≤ 99|0xFF`; `0x11 ≤ 16|0xFF`.

## 3. Binding — `fn_8001FB94` (forecast) / `fn_800201DC` (short) → 0x18 on success
Error codes (strings at `lbl_80199D04`): 0x2 MEM_ERROR_WeatherForecasts, 0x3 …Summary, 0x4 …WeatherType, 0x5 …Places,
0x7 …UVIndex, 0x8 …LaundryIndex, 0x9 …PollenIndex, **0xA ERROR_MESSAGE**, 0xB ERROR_NumForecasts (long==0 && summary==0),
0xC ERROR_NumWeatherTypes, 0xD ERROR_NumPlaces, 0xE ERROR_ShortNumNowWeathers, 0xF ERROR_ForecastArrayAddr,
0x10 ERROR_SummaryForecastArrayAddr, 0x11 ERROR_WeatherTypesArrayAddr, 0x12 ERROR_PlaceArrayAddr,
0x13 ERROR_WeatherTypeNameAddr (`fn_80028A50`), 0x14 ERROR_ShortNowWeatherArrayAddr; UV/laundry/pollen text 0x15/0x16/0x17.
Per-record binders: `fn_8002054C` long (local time = `entry[4] − entry[8] + lbl_80330A04`), `fn_800289F8` summary,
`fn_80028A50` weather type, `fn_80028A78` UV, `fn_80020F74` laundry, `fn_80027D80` pollen, `fn_80027D3C` place, `fn_80027CD8` short.

## 4. File formats (big-endian; strings UTF-16BE NUL-terminated)
### Header (both)
| off | type | field |
|---|---|---|
| 0x00 | u32 | version (0) |
| 0x04 | u32 | file size |
| 0x08 | u32 | CRC-32 of [0x0C, size) |
| 0x0C | u32 | issued (min since 2000) |
| 0x10 | u32 | expires (Nintendo: issued + 63) |
| 0x14 | u8 | Wii country code |
| 0x15 | u32 | language (low byte at 0x18 is compared) |
| 0x19 | u8 | region flag ≤2 (0 JP, 1 US, 2 EU) |
| 0x1A | u8 | kind ≤1 (forecast 1, short 0) |
| 0x1B | u8 | pad |
forecast.bin continues: 0x1C message off; then (count, offset) pairs: 0x20/0x24 long, 0x28/0x2C summary,
0x30/0x34 weather types, 0x38/0x3C UV, 0x40/0x44 laundry, 0x48/0x4C pollen, 0x50/0x54 places. short.bin: 0x1C count, 0x20 offset.

### Long forecast (0x80) — home-country cities
0x00 u32 location id · 0x04 u32 city local time · 0x08 u32 file time (diff = UTC offset) · 0x0C u8 status (≤5) +3 pad ·
0x10 Day today · 0x2C Day tomorrow · 0x48 Week[7].
### Summary forecast (0x48) — international cities
same as long without the week table.
### Day (0x1C)
0x00 u16 weather · 0x02 u16[4] quarter-day weather · 0x0A s8 hi °C · 0x0B s8 hi °C Δ · 0x0C s8 lo °C · 0x0D Δ ·
0x0E s8 hi °F · 0x0F Δ · 0x10 s8 lo °F · 0x11 Δ · 0x12 u8[4] precip % · 0x16 u8 wind dir (1 NNE … 15 NNW, 16 N) ·
0x17 u8 km/h · 0x18 u8 mph · 0x19 u8 UV id · 0x1A u8 laundry id · 0x1B u8 pollen id.
(Δ = change vs previous day; temperature/wind byte meanings beyond the validated fields come from served files +
RiiConnect24's generator — the display code is screen-track territory.)
### Week day (8)
u16 weather · s8 hi °C · s8 lo °C · s8 hi °F · s8 lo °F · u8 precip · pad.
### Weather type (8)
u16 data code · u16 **display code** · u32 name offset. `fn_800203F0` maps data → display code (0xFFFF if unknown).
Display code → icon: `fn_80020574` switch on `code & 0x7FFF` (0x00–0x7E, jumptable_8019AF48; all 127 valid),
bit 15 = night; `< 0x64` static icon path `fn_80020AD4`, `≥ 0x64` animated international icons.
### UV / laundry / pollen (8)
u8 id · 3 pad · u32 text offset.
### Place (0x18)
0x00 u32 id = [country u8][region u8][city u16] (0xFE = none) · 0x04 city text · 0x08 region text (0 = none) ·
0x0C country text (0 = none) · 0x10 s16 lat · 0x12 s16 lon (binary angle ×360/65536, `ConvLatLon16ToDeg`) ·
0x14 u8 zoom1 ≤9 (globe marker rank: shown when rank ≥ zoom index — see globe.md) · 0x15 u8 zoom2 ≤3 · 0x16 pad.
### Current (short.bin, 0x18)
0x00 id · 0x04 local time · 0x08 file time · 0x0C u16 weather · 0x0E u8 (≤99, unknown; served files 0) ·
0x0F s8 °C · 0x10 s8 °F · 0x11 u8 wind dir · 0x12 km/h · 0x13 mph · 0x14 u16 0 · 0x16 u16 0xFFFF.

### Globe marker use
`fn_8000A764(marker, mode)`: mode 0/1 → today/tomorrow `day.weather` from the long or summary entry; mode 2 → short.bin
current weather. `fn_80019268` draws each via `fn_800203F0` → `fn_80020574`.

## 5. Cross-check
RiiConnect24 **File-Maker** (`Channels/Forecast_Channel/forecast.py`, GitHub, **AGPL-3.0**) — read as a reference
only; no code or tables copied. It agrees with the decomp on every validated field and supplied names for the
temperature/wind bytes, the location-id composition, timestamps (expires = now + 63) and the server container.

## 6. Port data source
- Weather: **Open-Meteo** (free, no key, open source; data CC-BY 4.0). One paced batch fetch per refresh
  (≈490 locations × 1.4 weight; ≤480 weight/min; 429 → wait 61 s). WMO → channel code table in `WeatherCodes.swift`.
- Cities: **GeoNames** cities15000/admin1/countryInfo (CC-BY 4.0) → `fcdata cities` → `CityList.swift`
  (US: top 3 per state + all ≥150k = 262; world: capitals ≥500k + cities ≥3M = 228).
- Refresh: 3 h (free-tier budget); file validity = 3 h + 63 min, so the channel's own expiry check still applies.
