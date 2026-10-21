# 姜小白里程计（drivemileage）

一个基于 HarmonyOS（鸿蒙）的**单机行车里程记录工具**，用于记录行驶里程与行车时间。数据完全保存在本地，无需联网，隐私安全。

## 功能特性

- **GPS 里程记录**：基于定位自动计算行车里程（Haversine 公式计算两点距离）
- **完整行程控制**：开始 / 暂停 / 恢复 / 结束，支持分段行程
- **行程自动存档**：App 被系统清理后重新打开，可恢复未完成的行程，里程不丢失
- **多维度统计**：日 / 周 / 月 / 年 里程统计
- **历史记录**：行程列表可查看与重命名
- **隐私保护**：首次启动需同意隐私协议；仅申请定位相关权限；数据仅存本机

## 技术栈

- HarmonyOS 5（API 26），仅支持 phone 设备
- ArkTS / ArkUI（声明式 UI）
- `@kit.LocationKit`：GPS 定位（前台 + 后台）
- `@kit.ArkData`：RelationalStore 本地数据库 + Preferences 偏好存储
- `@kit.BackgroundTasksKit`：后台定位运行

## 工程结构

```
drivemileage/
├── AppScope/                      # 应用级配置与图标资源
├── entry/                         # 主模块
│   └── src/main/ets/
│       ├── entryability/          # 入口 Ability
│       ├── entrybackupability/    # 备份扩展
│       ├── pages/Index.ets        # 主页面：行程控制 + 统计 + 历史记录
│       ├── common/DbHelper.ets    # 本地数据库封装（DriveRecord）
│       └── utils/DistanceUtil.ets # 距离计算工具（Haversine 公式）
├── hvigor/                        # 构建配置
├── build-profile.json5
└── oh-package.json5
```

## 构建运行

1. 使用 **DevEco Studio** 打开本工程
2. 等待依赖同步完成（ohpm install）
3. 连接 HarmonyOS 手机（API 26+），点击 **Run** 运行

正式包构建：菜单 Build → Build App(s)，产物输出到 `build/outputs/default/`。

## 版本信息

| 项 | 值 |
| --- | --- |
| 版本 | V1.1.0 |
| versionCode | 1010000 |
| versionName | 1.1.0 |
| 包名 | `com.hou.drivemileage` |
| 设备类型 | phone |

## 隐私说明

- 本应用为**单机应用，无任何联网功能**，数据全部存储于本机
- 仅申请定位权限（前台 + 后台）用于计算行驶里程，不做任何收集与上传
