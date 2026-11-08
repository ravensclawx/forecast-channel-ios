# Forecast Channel for iPhone

**forecast-channel-ios** by **RavensClawX**

The Wii Forecast Channel, rebuilt for iPhone. This is a from-scratch Swift + Metal port based on a decompilation
of the original channel: its layouts, fonts, sounds, spinning globe and city markers, rearranged for a portrait touch
screen. It shows live weather. There is also a macOS build that runs the channel in its original widescreen layout.

> **Bring your own WAD.** This repository contains no Nintendo code, assets or keys. To build it you need your own
> copy of the Forecast Channel (USA, title HAFE, v7) and your own Wii common key. The app reads them at build
> time; nothing from them is committed.

![screenshots](docs/) <!-- add your own captures to docs/ -->

## Features

- The channel's own pages: Current, Today, Tomorrow, 5-Day and UV, plus the 6-hour forecast, with the original art,
  fonts, colours, sounds and animations.
- The 3D globe with its star field, weather and temperature markers for hundreds of cities, the six display modes,
  and the original zoom from a city back to its forecast.
- Live weather from [Open-Meteo](https://open-meteo.com) (free, no API key), converted into the channel's own
  `forecast.bin` / `short.bin` format.
- Touch controls built for portrait:
  - swipe up or down to change pages, and tap Today or Tomorrow for the 6-hour forecast
  - drag to spin the globe, pinch to zoom, drag two fingers up or down to tilt, tap a city to open it
  - every original button still works
- Native iOS Settings (Settings → Apps → Forecast Channel): your current location or a city of your choice,
  Fahrenheit or Celsius, mph or km/h, and a switch to reset the downloaded data.
- Optional AI-upscaled textures for a sharp picture on Retina screens (see [tools/upscale](tools/upscale/README.md)).

## Requirements

- A Mac with Xcode 26 or later; the iPhone needs iOS 17 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Your own Forecast Channel WAD (USA, `HAFE`, v7) and your Wii common key (`common-key.bin`, 16 bytes).

## Build the iPhone app

```sh
# 1. Stage your WAD and key (copied into gitignored folders), render the app icon, generate the Settings page
tools/ios/stage_assets.sh --wad /path/to/HAFE.wad --key /path/to/common-key.bin

# 2. Signing: copy the example and set your Apple developer team (Xcode → Settings → Accounts)
cp iOS/Local.xcconfig.example iOS/Local.xcconfig     # edit DEVELOPMENT_TEAM (and the bundle ID if needed)

# 3. Generate and open the Xcode project, then build and run on your iPhone
cd iOS && xcodegen && open ForecastPhone.xcodeproj
```

With a free Apple ID ("Personal Team") the app has to be reinstalled from Xcode every 7 days.

## Build the Mac app

```sh
swift build -c release
.build/release/ForecastMac      # reads ~/Library/Application Support/ForecastChannel/{HAFE.wad,common-key.bin}
```

The mouse acts as the Wii Remote pointer: left button = A, right button or Esc = B, H = HOME Menu.

## Project layout

| Path | What |
|---|---|
| `Sources/RVL` | Revolution SDK replacements: WAD/ES decryption, U8 archives, LZ/Huffman decompression, DOL reader |
| `Sources/GX` | GX GPU state model, texture decoders, TEV → Metal shader generator |
| `Sources/NW4R` | NintendoWare formats and runtime: g3d models, lyt layouts and animations, fonts, sound, effects |
| `Sources/Forecast` | The ported channel: scenes, pages, globe, markers, settings, forecast data and Metal renderers |
| `Sources/ForecastMac`, `iOS/` | The macOS and iPhone apps |
| `Sources/fcdata`, `fcdump`, `fcupscale` | Data generator, offscreen renderer / QA harness, texture upscaler |
| `decomp/` | decomp-toolkit config, symbols and notes from the decompilation (no binaries) |
| `tools/` | WAD, QA, iOS staging and data scripts |

## Credits

- Weather data: [Open-Meteo](https://open-meteo.com), CC BY 4.0.
- City names and coordinates: [GeoNames](https://www.geonames.org), CC BY 4.0.
- Globe marker ranks of the original city lists, as preserved by
  [RiiConnect24 File-Maker](https://github.com/RiiConnect24/File-Maker) (`forecastlists.py`).
- [Dolphin](https://dolphin-emu.org) was the reference for GX/TEV behaviour and for checking the port against the
  original channel.
- Decompilation with [decomp-toolkit](https://github.com/encounter/decomp-toolkit) and
  [m2c](https://github.com/matt-kempster/m2c).

## License

TBD by the author.

## Disclaimer

This is an unofficial fan project, not affiliated with or endorsed by Nintendo. Wii and Forecast Channel are
trademarks of Nintendo. No Nintendo code, assets or keys are included; you need your own copy of the channel.
