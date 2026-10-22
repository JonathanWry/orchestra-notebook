#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/.build"
app_dir="$project_dir/dist/配器手记.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
archive_path="$project_dir/dist/Orchestra-Notebook-macOS.zip"
iconset_dir="$build_dir/AppIcon.iconset"
module_cache="$build_dir/module-cache"

rm -rf "$build_dir" "$app_dir" "$archive_path"
mkdir -p "$build_dir" "$macos_dir" "$resources_dir" "$iconset_dir" "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"

xcrun clang \
    -fobjc-arc \
    -fmodules \
    -O2 \
    -mmacosx-version-min=13.0 \
    -framework Cocoa \
    -framework WebKit \
    -framework ApplicationServices \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -framework PDFKit \
    "$project_dir/Sources/main.m" \
    -o "$macos_dir/OrchestraNotebook"

xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=13.0 -framework AppKit \
    "$project_dir/Tools/IconGenerator.m" -o "$build_dir/IconGenerator"
"$build_dir/IconGenerator" "$build_dir/icon-1024.png"

for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" "512 icon_512x512.png" "1024 icon_512x512@2x.png"
do
    pixels="${spec%% *}"
    name="${spec#* }"
    sips -z "$pixels" "$pixels" "$build_dir/icon-1024.png" --out "$iconset_dir/$name" >/dev/null
done

xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=13.0 -framework Foundation \
    "$project_dir/Tools/IcnsBuilder.m" -o "$build_dir/IcnsBuilder"
"$build_dir/IcnsBuilder" "$resources_dir/AppIcon.icns" \
    "$iconset_dir/icon_16x16.png" "$iconset_dir/icon_32x32.png" "$iconset_dir/icon_32x32@2x.png" \
    "$iconset_dir/icon_128x128.png" "$iconset_dir/icon_256x256.png" \
    "$iconset_dir/icon_512x512.png" "$iconset_dir/icon_512x512@2x.png"

cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/index.html" "$resources_dir/index.html"
cp "$project_dir/Resources/app.css" "$resources_dir/app.css"
cp "$project_dir/Resources/app.js" "$resources_dir/app.js"
cp "$project_dir/Resources/OrchestraNotebookCapture.qml" "$resources_dir/OrchestraNotebookCapture.qml"
chmod 755 "$macos_dir/OrchestraNotebook"

xattr -cr "$app_dir"
signed_app=false
for attempt in {1..10}; do
    xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
    xattr -d com.apple.provenance "$app_dir" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
    if codesign --force --deep --sign - --requirements '=designated => identifier "local.codex.OrchestraNotebook"' "$app_dir" >/dev/null 2>&1; then
        signed_app=true
        break
    fi
done
if [[ "$signed_app" != true ]]; then
    print -u2 "App 签名失败"
    exit 1
fi
codesign --verify --deep --strict "$app_dir"

ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent "$app_dir" "$archive_path"
print "构建完成：$app_dir"
print "安装包：$archive_path"
