#!/bin/sh
# DouyinHelperLite — 一键构建（需 Theos 环境）
# 用法: ./build.sh
#   输出: ../debs/com.xuuz.douyinhelper.lite_*.deb
set -e
cd "$(dirname "$0")"
export THEOS=${THEOS:-~/theos}

if [ ! -d "$THEOS" ]; then
    echo "找不到 Theos：$THEOS"
    echo "装一个："
    echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)\""
    exit 1
fi

make clean >/dev/null 2>&1 || true
make package FINAL=1

mkdir -p ../debs
cp packages/*.deb ../debs/ 2>/dev/null || true
ls -la ../debs/*.deb 2>/dev/null | tail -3
echo "构建完成：com.xuuz.douyinhelper.lite"
