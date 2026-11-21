# MapX

一个极简 iPhone 地图与基础导航项目，使用 SwiftUI + Apple MapKit，无账号、无广告、无后端，不需要地图 API Key。

## 已实现（仍需实机验证）
- 全屏地图、定位、地点搜索
- 驾车路线与可用备选路线
- 前台 GPS 跟随、下一步转向提示、中文语音播报
- 偏离原路线且定位足够可靠时请求重新规划
- 规划时可选 MapKit 实际返回的路线。导航时显示转向、估算剩余时间和距离。当前版本无可靠的桥上／桥下校正能力。

## 重要限制
- Apple MapKit 的 `MKDirections` 不提供强制走桥上或桥下的 API，也不提供道路层级/高程匹配。这一版本不能真正修正多层立交的 GPS 匹配。
- 基础导航是实验性功能，尚未完成实车验证、复杂立交校验及长时间可靠性测试；正式驾驶请优先使用成熟导航软件。
- 暂不支持 CarPlay、后台持续导航、车道级指引及离线导航。
- 仅在有网络且 MapKit 地图服务可用的地区进行搜索和规划。

## 构建
需要 macOS、Xcode 与 XcodeGen。

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project MapX.xcodeproj -scheme MapX -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions 会编译模拟器版本和 iPhone 版本，上传 **未签名的** `MapX-unsigned.ipa`。该 IPA 不能直接安装，需要使用有效证书重新签名后安装。

MapX 是独立项目，与 Google 或 Apple 无关联。
