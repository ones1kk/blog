#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 \"Title Here\" [draft]"
  exit 1
fi

title="$1"
mode="${2:-post}"

# Resolve repo root so output paths are consistent regardless of cwd.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)

# Simple slug: lowercase, replace spaces with hyphens, strip non-alnum/hyphen.
slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

# Date format: YYYY-MM-DD
if command -v gdate >/dev/null 2>&1; then
  today=$(gdate +%F)
  year=$(gdate +%Y)
else
  today=$(date +%F)
  year=$(date +%Y)
fi

if [ "$mode" = "draft" ]; then
  base_dir="${repo_root}/drafts/${today}"
else
  base_dir="${repo_root}/posts/${year}/${today}"
fi

mkdir -p "${base_dir}"

seq=1
while :; do
  seq_dir=$(printf '%02d' "${seq}")
  post_dir="${base_dir}/${seq_dir}"
  if [ ! -e "${post_dir}" ]; then
    break
  fi
  seq=$((seq + 1))
done

mkdir -p "${post_dir}/assets"

cat <<EOM > "${post_dir}/index.md"
---
title: "${title}"
slug: "${slug}"
date: "${today}"
tags: ["devlog"]
status: "draft" # draft | published
summary: ""
cover: "./assets/cover.png"
---

# ${title}

본문을 작성하세요.

<br> 

오탈자 및 오류 내용을 댓글 또는 메일로 알려주시면, 검토 후 조치하겠습니다.
EOM

printf 'Created: %s\n' "${post_dir}/index.md"
