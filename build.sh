#!/usr/bin/env bash
# 岛上书店 · 构建脚本
#
# 这台机器有三个特殊之处，全部环境变量都是必需的，缺一个就构建失败：
#   1. 默认不开代理     → 构建走国内镜像（pub 镜像 + ~/.gradle/init.gradle 里的阿里云源）
#   2. 用户名是中文「无名客」   → PUB_CACHE 必须挪到英文路径，否则 ninja 编不了 C++
#   3. 项目路径含中文           → android.overridePathCheck=true
#
# 用法：
#   ./build.sh                # debug APK（走镜像）
#   ./build.sh release        # release APK（体积小很多）
#   NO_MIRROR=1 ./build.sh    # 走官方源（需要先开代理，用于镜像缺包时排查）
#
# 什么时候需要开代理：某个依赖在镜像上找不到（pub 报 404、Gradle 报 Could not
# resolve），或者要拉 iOS/CocoaPods 相关资源时。开完用 NO_MIRROR=1 重跑。

set -e

export PATH="/d/develop/flutter/bin:$PATH"
export ANDROID_HOME="D:\\develop\\android-sdk"
export ANDROID_SDK_ROOT="D:\\develop\\android-sdk"

if [ "$NO_MIRROR" = "1" ]; then
  # 直连模式：不设镜像变量，走 pub.dev / storage.googleapis.com
  # 注意 ~/.gradle/init.gradle 也会读这个变量，自动跳过阿里云源
  echo ">>> 直连模式（NO_MIRROR=1），请确认代理已开启"
  unset PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL
else
  export PUB_HOSTED_URL=https://pub.flutter-io.cn
  export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
fi

# 关键：默认缓存在 C:\Users\无名客\... ，中文路径会让 CMake/ninja 报
# "文件名、目录名或卷标语法不正确"
export PUB_CACHE="D:\\develop\\pub_cache"

cd "$(dirname "$0")"

MODE="${1:-debug}"
echo ">>> 构建 $MODE APK ..."
flutter build apk "--$MODE"

OUT="build/app/outputs/flutter-apk"
echo ""
echo ">>> 产物："
ls -lh "$OUT"/*.apk 2>/dev/null || echo "（没有找到 apk，看看上面的报错）"
