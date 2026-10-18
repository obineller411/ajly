#!/bin/bash
# 门锁开门 iOS 打包脚本 —— 只能在 macOS 上运行（需装好 Xcode 和 Flutter）
# 用法：cd door_lock && chmod +x build_ipa.sh && ./build_ipa.sh
# 产物：build/门锁开门-unsigned.ipa（未签名）
# 后续：用 Sideloadly / AltStore 填自己的 Apple ID 签名后安装到 iPhone
set -e
cd "$(dirname "$0")"

flutter pub get
flutter build ipa --release --no-codesign

# 从 xcarchive 里取出 .app 打成未签名 IPA
rm -rf build/ipa_payload build/门锁开门-unsigned.ipa
mkdir -p build/ipa_payload/Payload
cp -R build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app \
      build/ipa_payload/Payload/
cd build/ipa_payload
zip -qry ../门锁开门-unsigned.ipa Payload
cd ../..

echo ""
echo "打包完成: build/门锁开门-unsigned.ipa"
echo "签名安装: 用 Sideloadly(电脑) 或 AltStore(手机) 加载此 IPA，"
echo "          登录自己的 Apple ID 即可签名安装（免费 Apple ID 7 天有效）。"
