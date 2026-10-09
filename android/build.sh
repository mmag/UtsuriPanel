#!/bin/zsh
# Builds build/utsuripanel.apk with the SDK's tools directly (no Gradle), signed
# with the debug key.
#   build.sh [--install]   --install also installs it on the phone and opens it
set -euo pipefail

here=${0:A:h}
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
tools=$sdk/build-tools/36.0.0
jar=$sdk/platforms/android-34/android.jar
out=$here/build

rm -rf $out
mkdir -p $out/classes $out/dex
$tools/aapt2 compile --dir $here/res -o $out/res.zip
$tools/aapt2 link -I $jar --manifest $here/AndroidManifest.xml -o $out/unsigned.apk $out/res.zip
javac -source 8 -target 8 -bootclasspath $jar -Xlint:-options -encoding UTF-8 -d $out/classes $(find $here/src -name '*.java')
$tools/d8 --min-api 25 --lib $jar --output $out/dex $(find $out/classes -name '*.class')
(cd $out/dex && zip -q ../unsigned.apk classes.dex)
$tools/zipalign -f -p 4 $out/unsigned.apk $out/aligned.apk
$tools/apksigner sign --ks $HOME/.android/debug.keystore --ks-pass pass:android --key-pass pass:android \
    --ks-key-alias androiddebugkey --out $out/utsuripanel.apk $out/aligned.apk
echo $out/utsuripanel.apk

if [[ ${1:-} == --install ]]; then
    adb install -r $out/utsuripanel.apk
    adb shell am start -n app.utsuripanel/.PanelActivity
fi
