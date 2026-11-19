#!/bin/sh
# Builds this fork's release APK. Runs inside ghcr.io/cirruslabs/flutter (used only for
# its Android SDK + JDK: its newest tag is older than the Flutter this repo needs), with
# Flutter $KO_FLUTTER downloaded into a cache volume. See "This fork" in CLAUDE.md.
#
# Args: <git ref of alexdrl/kitchenowl> <build-name> <build-number>
# Mounts: /keys/key.properties (+ the keystore it points at), /out (the APKs land here),
# and the volumes ko-src (/src), ko-gradle, ko-pub, ko-android-sdk, ko-flutter-cache (/cache).
set -eu
REF="$1"; NAME="$2"; NUMBER="$3"
# Not FLUTTER_VERSION: the cirruslabs image already sets that one to its own version.
KO_FLUTTER="${KO_FLUTTER:-3.50.0}"
SDK="/cache/flutter-$KO_FLUTTER"

if [ ! -x "$SDK/bin/flutter" ]; then
  echo "== downloading Flutter $KO_FLUTTER"
  rm -rf "$SDK" && mkdir -p "$SDK"
  curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$KO_FLUTTER-stable.tar.xz" \
    | tar -xJ -C "$SDK" --strip-components=1
fi
export PATH="$SDK/bin:$PATH"
git config --global --add safe.directory '*'
flutter config --no-analytics >/dev/null
flutter --version | head -1

# /src is a volume (ko-src) kept between builds: reusing the checkout keeps Gradle's and
# Kotlin's incremental outputs (build/, .gradle/), which a fresh clone threw away every time.
if [ -d /src/.git ]; then
  echo "== updating the kept checkout to $REF"
  git -C /src fetch -q origin
else
  echo "== cloning alexdrl/kitchenowl"
  git clone -q https://github.com/alexdrl/kitchenowl /src
fi
git -C /src checkout -qf "$REF"
git -C /src log -1 --format='%h %s'

cp /keys/key.properties /src/kitchenowl/android/key.properties
# gradle.properties asks for an 8 GB heap, more than Docker Desktop's whole VM has: the
# first build was OOM-killed. 3 GB is plenty for one ABI. The build cache lets unchanged
# Gradle tasks come from the ko-gradle volume.
sed -i 's/^org.gradle.jvmargs=.*/org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=512m/' \
  /src/kitchenowl/android/gradle.properties
grep -q '^org.gradle.caching=' /src/kitchenowl/android/gradle.properties ||
  printf '\norg.gradle.caching=true\n' >> /src/kitchenowl/android/gradle.properties  # file has no final newline
cd /src/kitchenowl
flutter pub get >/dev/null
# Logs (lib/services/app_log_upload.dart): the collector's URL and token come from a file
# next to the signing key, never from git. Without it the app sends nothing.
LOG_DEFINES=""
if [ -f /keys/app-logs.env ]; then
  LOG_DEFINES="--dart-define-from-file=/keys/app-logs.env"
  echo "== log upload: configured from /keys/app-logs.env"
else
  echo "== log upload: off (no /keys/app-logs.env)"
fi
# arm64 only: every phone the user has, and a third of the build time and memory.
flutter build apk --release --target-platform android-arm64 --build-name="$NAME" --build-number="$NUMBER" $LOG_DEFINES
cp build/app/outputs/flutter-apk/app-release.apk "/out/kitchenowl-$NAME.apk"
echo "== built /out/kitchenowl-$NAME.apk"

# The Wear OS watch app (branch feat/wear-shopping-list), when this ref has it. Same key and
# applicationId as the phone app: the Data Layer only pairs those. It is sideloaded with adb,
# so it goes to a separate file that Obtainium must never pick for the phone.
if [ -d android/wear ]; then
  (cd android && ./gradlew -q :wear:assembleRelease -PwearVersionName="$NAME" -PwearVersionCode="$NUMBER")
  cp build/wear/outputs/apk/release/wear-release.apk "/out/kitchenowl-wear-$NAME.apk"
  echo "== built /out/kitchenowl-wear-$NAME.apk"
fi
