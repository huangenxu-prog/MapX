# MapX

简洁的 iPhone 地图与基础驾车导航 App。采用 SwiftUI + Apple MapKit，无广告、无需账号，也不需要地图 API Key。

## 功能（1.0 build 6）

- 地图定位、搜索地址、路线预览、备选路线
- 导航时地图自动跟随，用户手动拖动后约 9 秒自动恢复；返回前台重新跟随
- 导航期间持续获取后台 GPS 位置；锁屏时仍尝试按新位置推送转向提醒
- 中文语音提示，可在导航页一键静音／开启；偏好保存在设备本地
- 最近选择的目的地保留 12 条；点击搜索框查看，长按最近目的地可设为「家」或「公司」
- 使用坐标、GPS 精度、行进进度和连续定位结果判断接近终点；满足条件时自动结束导航
- 用户主动结束导航或到达终点后取消后台定位、清理当前路线

## 后台导航实现与限制

iOS 的 `UIBackgroundModes` 开启了 `location` 和 `audio`，Core Location 的 `allowsBackgroundLocationUpdates` 仅在**用户主动启动导航之后**设为 true。正常浏览地图、结束导航以及在后台没有导航时不会继续请求高频定位。

`AVAudioSession` 仅在实际语音播报时激活（voicePrompt + duckOthers），播报结束后释放音频会话。通知、电话及蓝牙连接的实际行为需要在设备上验证。

- 这**不是完整成熟的导航引擎**。系统可能在强制关闭 App、定位权限撤销、低电量等情况下停止相关活动。不能保证后台重启或实时语音绝对可靠
- 每次进入 App 后仍需主动开始导航；不会在启动时自动恢复一趟未完成的导航
- 语音提示、偏航重算和到达判断尚未完成实车可靠性验证；不应代替成熟导航产品作为唯一驾驶指引
- MapKit 不公开独立的「桥上／桥下」道路层级匹配能力，本项目不能保证校正立交上下层位置
- 未实现 CarPlay、车道级指引、离线导航或后台运行状态下的完整实时 UI 绘制
- 本地最近目的地保存在 UserDefaults，不主动同步或上传；系统备份可能包含应用偏好数据
- 仅支持网络和 MapKit 相关服务可用的区域

## 建议的实机验证

1. 开启定位，搜索目的地并选择路线
2. 启动导航，在前台验证 GPS 跟随、文字与语音转向提示
3. 关闭语音再开启，确认当次有效，重启应用后偏好仍保留
4. 锁屏行驶一段路，确认 GPS 回调以及语音提示在设备环境下有效（切勿边驾驶边操作设备）
5. 恢复前台后手动拖动地图，观察自动恢复跟随
6. 选择并保存常用目的地，关闭重启 App 验证本地记录
7. 近终点缓慢行驶时检查自动结束，或手动结束导航，确认 GPS 后台活动不再持续

## 构建

macOS + Xcode + XcodeGen：

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project MapX.xcodeproj -scheme MapX -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions 会进行模拟器和 iPhone 编译，检查生成的 Info.plist 是否包含后台定位与音频模式，并上传 **未签名** `MapX-unsigned.ipa`。必须使用有效的证书和配置文件重新签名，才能在设备安装。

MapX 为独立开源学习项目，与 Google、Apple 无关联。
