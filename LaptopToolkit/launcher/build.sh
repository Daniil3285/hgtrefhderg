#!/usr/bin/env bash
# Сборка LaptopToolkit.exe на Linux: mono-mcs, binutils-mingw-w64-x86-64 (windres), imagemagick.
# Результат: dist/LaptopToolkit.exe (.NET Framework 4.x - есть в каждой Windows 10/11).
set -euo pipefail
cd "$(dirname "$0")"
root="$(cd .. && pwd)"
out="$root/dist"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"

# Иконка: бирюзовый квадрат с молнией, несколько размеров в одном .ico
for s in 16 24 32 48 64 128 256; do
  convert -size 256x256 xc:none \
    -fill '#10141a' -draw 'roundrectangle 8,8 248,248 48,48' \
    -fill '#00c8ac' -draw 'polygon 146,28 64,146 122,146 104,228 192,104 132,104 158,28' \
    -resize ${s}x${s} "$tmp/i$s.png"
done
convert "$tmp"/i16.png "$tmp"/i24.png "$tmp"/i32.png "$tmp"/i48.png "$tmp"/i64.png "$tmp"/i128.png "$tmp"/i256.png "$tmp/app.ico"

cp app.manifest app.rc "$tmp/"
(cd "$tmp" && x86_64-w64-mingw32-windres -I /usr/share/mingw-w64/include -O res -i app.rc -o app.res)

mcs -nologo -target:winexe -platform:anycpu -optimize+ \
  -r:System.Windows.Forms.dll \
  -win32res:"$tmp/app.res" \
  -resource:"$root/LaptopToolkit.ps1,LaptopToolkit.ps1" \
  -out:"$out/LaptopToolkit.exe" Launcher.cs

cp "$tmp/app.ico" "$out/app.ico"
ls -la "$out/LaptopToolkit.exe"
