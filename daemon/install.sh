#!/bin/zsh
# Builds UtsuriPanel.app into /Applications and (re)installs its LaunchAgent:
# started at login, restarted if it crashes (not after Quit).
# Log: ~/Library/Logs/utsuripanel.log.
#   install.sh             build, install, (re)start
#   install.sh --uninstall stop it, remove the LaunchAgent and the app
set -euo pipefail

here=${0:A:h}
label=app.utsuripanel
app=/Applications/UtsuriPanel.app
plist=$HOME/Library/LaunchAgents/$label.plist
domain=gui/$(id -u)

launchctl bootout $domain/$label 2>/dev/null || true
pkill -x utsuripanel 2>/dev/null || true
if [[ ${1:-} == --uninstall ]]; then
    rm -rf $plist $app
    echo "removed $label"
    exit 0
fi

config=${here:h}/config.json
if [[ ! -e $config ]]; then
    cp ${here:h}/config.example.json $config
    echo "created $config from the example: put your servers in it"
fi
defaults write $label config $config

swift build -c release --package-path $here
rm -rf $app
mkdir -p $app/Contents/MacOS
cp $here/.build/release/utsuripanel $app/Contents/MacOS/
cp $here/Info.plist $app/Contents/
codesign --force --sign - $app

cat > $plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$app/Contents/MacOS/utsuripanel</string>
        <string>$config</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/utsuripanel.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/utsuripanel.log</string>
</dict>
</plist>
EOF

launchctl bootstrap $domain $plist
echo "installed $app"
