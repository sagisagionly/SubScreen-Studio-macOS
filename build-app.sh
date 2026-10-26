#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/SubScreen Studio.app"

cd "$project_dir"
mkdir -p "$project_dir/.build/ModuleCache" "$project_dir/.build/SwiftPMCache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/SwiftPMCache"
# Some macOS beta Command Line Tools leave the unversioned SDK symlink one
# patch ahead of the bundled Swift compiler. Prefer the compatible SDK when it
# is present so one-click builds keep working after an OS update.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift_compat_args=()
# CLT 27 currently ships a Swift 6.4 compiler without the SwiftUI macro
# plug-in required by its SDK, while retaining the complete macOS 26.5 SDK.
# Let the newer compiler consume that compatible SDK interface.
if swift --version | grep -q 'Apple Swift version 6.4'; then
    swift_compat_args=(-Xswiftc -Xfrontend -Xswiftc -interface-compiler-version -Xswiftc -Xfrontend -Xswiftc 6.3.2.1.2)
fi
binary_path="$project_dir/.build/release/SubScreenStudio"
if ! swift build -c release --disable-sandbox -Xswiftc -gnone "${swift_compat_args[@]}"; then
    # Some restricted build environments allow linking the app but block only
    # the optional dSYM bundle. The linked release executable is still valid.
    if [[ ! -x "$binary_path" ]] || find "$project_dir/Sources" "$project_dir/Package.swift" -type f -newer "$binary_path" -print -quit | grep -q .; then
        exit 1
    fi
    print "Continuing with the linked release executable (debug symbols unavailable)."
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/release/SubScreenStudio" "$app_dir/Contents/MacOS/SubScreenStudio"
cp "$project_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Sources/SubScreenStudio/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
mkdir -p "$app_dir/Contents/Resources/ThirdPartyLicenses"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE.txt"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$project_dir/vendor/sub-screen-player/LICENSE-MIT" "$app_dir/Contents/Resources/ThirdPartyLicenses/Sub-Screen-Player-MIT.txt"
cp "$project_dir/vendor/sub-screen-player/LICENSE-APACHE" "$app_dir/Contents/Resources/ThirdPartyLicenses/Sub-Screen-Player-APACHE-2.0.txt"
cp "$project_dir/ThirdPartyLicenses/Pear-Desktop-MIT.txt" "$app_dir/Contents/Resources/ThirdPartyLicenses/Pear-Desktop-MIT.txt"
ssp_binary="$project_dir/vendor/sub-screen-player/target/release/ssp"
if [[ ! -x "$ssp_binary" ]] || find "$project_dir/vendor/sub-screen-player/crates" "$project_dir/vendor/sub-screen-player/Cargo.toml" -type f -newer "$ssp_binary" -print -quit | grep -q .; then
    cargo build --manifest-path "$project_dir/vendor/sub-screen-player/Cargo.toml" -p sub-screen-player --release
fi
cp "$ssp_binary" "$app_dir/Contents/Resources/ssp"
chmod +x "$app_dir/Contents/MacOS/SubScreenStudio"
chmod +x "$app_dir/Contents/Resources/ssp"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
