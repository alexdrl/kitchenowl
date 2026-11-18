#!/bin/sh
# Builds this fork's release APK. Runs inside ghcr.io/cirruslabs/flutter (used only for
# its Android SDK + JDK: its newest tag is older than the Flutter this repo needs), with
# Flutter $KO_FLUTTER downloaded into a cache volume. See "This fork" in CLAUDE.md.
#
# Args: <git ref of alexdrl/kitchenowl> <build-name> <build-number>
# Mounts: /keys/key.properties (+ the keystore it points at), /out (the APK lands here),
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
  printf '
org.gradle.caching=true
' >> /src/kitchenowl/android/gradle.properties  # file has no final newline
cd /src/kitchenowl
flutter pub get >/dev/null
# arm64 only: every phone the user has, and a third of the build time and memory.
flutter build apk --release --target-platform android-arm64 --build-name="$NAME" --build-number="$NUMBER"
cp build/app/outputs/flutter-apk/app-release.apk "/out/kitchenowl-$NAME.apk"
echo "== built /out/kitchenowl-$NAME.apk"
