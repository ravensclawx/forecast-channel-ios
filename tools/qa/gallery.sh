#!/bin/zsh
# Renders every screen/state of the port through the real WeatherScene into $1 (default: scratch/qa).
# Logical pointer coords are in the 832x456 widescreen space.
cd "$(dirname $0)/../.."
OUT=${1:-.qa/qa}
mkdir -p $OUT; rm -f $OUT/*.png
F=${FCDUMP:-.build/release/fcdump}
UP="ptr:445,44"; DOWN="ptr:445,411"; SET="ptr:707,44"; BACK="ptr:127,411"; GLOBE="ptr:707,411"
run() { local name=$1; shift; timeout 300 $F --scene $OUT/$name "$@" 2>&1 | grep -E "^shot|error" | sed "s|$OUT/||"; }
# Hub pages (saved location), scroll through all pages
run hub boot wait:240 shot:p1_current $UP wait:30 a wait:90 shot:p0_uv $DOWN wait:30 a wait:90 a wait:90 shot:p2_today a wait:90 shot:p3_tomorrow a wait:90 shot:p4_week
# 6-hour strip on Today (pointer over the strip area)
run sixh boot wait:240 $DOWN wait:30 a wait:120 ptr:416,300 wait:60 shot:today_hover a wait:60 shot:today_6h
# Settings + toggles
run set boot wait:240 $SET wait:30 a wait:120 shot:settings ptr:600,180 wait:20 shot:settings_hover
# Globe: all six modes + zoom levels + tilt
run globe boot wait:240 $GLOBE wait:30 a wait:200 shot:m0_z0 ptr:416,300 minus wait:40 minus wait:40 minus wait:40 minus wait:40 minus wait:40 minus wait:60 shot:m0_z6 right wait:30 shot:m1 right wait:30 shot:m2 right wait:30 shot:m3 right wait:30 shot:m4 right wait:30 shot:m5 minus wait:40 minus wait:40 minus wait:60 shot:m5_z9 up wait:60 up wait:60 shot:tilt2
# Globe → marker click → hub (non top level) → back to globe → back to hub
run marker boot wait:240 $GLOBE wait:30 a wait:200 ptr:416,300 minus wait:40 minus wait:40 minus wait:40 minus wait:80 shot:before a wait:150 shot:hub_from_marker $BACK wait:40 a wait:150 shot:back_globe $BACK wait:40 a wait:150 shot:back_hub
# HOME Menu over the hub
run home boot wait:240 home wait:60 shot:hbm
# Settings → change location → city list → candidate → confirm Yes → hub of the new city
run addr boot wait:240 $SET wait:30 a wait:120 ptr:645,138 wait:40 a wait:80 shot:list ptr:416,200 wait:40 a wait:100 shot:confirm ptr:416,257 wait:40 a wait:180 shot:hub
# First run (no save): date check → region list
run first fresh boot wait:120 shot:date ptr:416,256 wait:40 a wait:150 shot:regions
