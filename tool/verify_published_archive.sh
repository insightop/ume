#!/usr/bin/env bash
# 发布后归档验证（release smoke test）。
#
# 目的：从 pub.dev 拉取【刚发布的归档】，验证
#   1) 它的 pubspec 不含 `workspace:` 键；且
#   2) 下游以【依赖】方式使用它时，pub 解析正常。
#
# 为什么需要它：`tool/check_workspace_layout.dart` 在发布【前】拦截根因，但
# `dart pub publish` 校验的是工作区、打包用的却是 `.pubignore` 过滤后的列表，
# 二者可能不一致。2.0.8 就是这样逃过全部检查发布的。发布无法撤回，
# 因此这里对【真实产物】做最后一道验证 —— 失败即告警，便于立刻补发版本。
#
# ⚠️ 不要把归档解包后【直接】在归档目录里跑 `dart pub deps`：归档里的成员包
#    带 `resolution: workspace`，而归档本身不含 workspace 根，pub 会报
#    "found no workspace root including it in parent directories"。那是测试方式
#    错了，不是包有问题 —— 真实下游是把它当【依赖】，而不是独立包。
#
# 用法：tool/verify_published_archive.sh <包名> <版本>
#   tool/verify_published_archive.sh ume 2.0.9
set -euo pipefail

PKG="${1:?用法: $0 <包名> <版本>}"
VERSION="${2:?用法: $0 <包名> <版本>}"
DART="${DART:-dart}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# pub.dev 索引有延迟；重试若干次。
for attempt in 1 2 3 4 5; do
  if curl -fsSL -o archive.tar.gz \
      "https://pub.dev/api/archives/${PKG}-${VERSION}.tar.gz"; then
    break
  fi
  if [ "$attempt" = 5 ]; then
    echo "::error::无法从 pub.dev 拉取 ${PKG}-${VERSION} 归档"
    exit 1
  fi
  echo "  等待 pub.dev 索引 ${PKG} ${VERSION}（第 ${attempt} 次重试）..."
  sleep 15
done

mkdir extracted
tar xzf archive.tar.gz -C extracted

# 1) 归档的 pubspec 绝不能带 `workspace:` —— 这是击穿下游的直接原因。
#    该键指向的成员目录若不在归档内，下游读这个 pubspec 时就会硬失败。
if grep -qE '^workspace:' extracted/pubspec.yaml; then
  echo "::error::${PKG} ${VERSION} 归档的 pubspec 含 \`workspace:\` 键，会击穿下游 pub 解析"
  sed -n '/^workspace:/,/^[a-z]/p' extracted/pubspec.yaml
  exit 1
fi

# 2) 以【下游依赖】的方式使用它：新建一个消费者包依赖该版本，再构建 package graph。
#    这正是 2.0.8 踩雷的代码路径（pub 会用同一套校验读取依赖的 pubspec）。
mkdir consumer
cd consumer
cat > pubspec.yaml <<EOF
name: verify_consumer
publish_to: none
environment:
  sdk: ">=3.11.0 <4.0.0"

dependencies:
  ${PKG}: ${VERSION}
EOF

if ! "$DART" pub get >get.log 2>&1; then
  echo "::error::${PKG} ${VERSION} 无法被下游解析（dart pub get 失败）："
  cat get.log
  exit 1
fi

# `dart pub deps` 会加载每个依赖的 pubspec 并构建 package graph，
# 与下游实际踩雷的代码路径一致。
if ! "$DART" pub deps >/dev/null 2>deps.err; then
  echo "::error::${PKG} ${VERSION} 作为依赖时 \`dart pub deps\` 失败："
  cat deps.err
  exit 1
fi

echo "✅ ${PKG} ${VERSION} 归档验证通过（无 workspace: 键；作为下游依赖 pub 解析正常）"
