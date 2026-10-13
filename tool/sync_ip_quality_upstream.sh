#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(git branch --show-current)" != "ip-quality" ]]; then
  echo "请先切换到 ip-quality 分支。" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "请先提交或保存当前修改，再同步官方代码。" >&2
  exit 1
fi
git fetch upstream --tags
git merge --no-edit "${1:-upstream/main}"
git config submodule.core/Clash.Meta.url https://github.com/chen08209/Clash.Meta.git
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
echo "上游已合并。请重新构建并验证，再发布自己的版本。"
