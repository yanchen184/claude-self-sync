#!/bin/bash
# claude-self-sync — 在自己的多台電腦間同步 ~/.claude
# Usage:
#   sync.sh push [--dry-run]    把本機推上 GitHub
#   sync.sh pull [--dry-run]    從 GitHub 拉下來覆蓋本機（pull 前自動備份）
#   sync.sh status              比對本機 vs repo 差異，不寫入
#
# 設計原則：
#   1. mempalace 不同步（架構衝突，見 docs）
#   2. .mcp.json 不同步（路徑各機不同），用 .mcp.json.example 作範本
#   3. push 前先確認 repo 是 up-to-date，避免覆蓋他機改動
#   4. pull 前自動備份本機可能被覆蓋的目錄（保留最近 3 份 tar.gz）
#   5. flock 防雙開
#   6. set -euo pipefail，任何失敗立即停

set -euo pipefail

# ============================================================
# 設定
# ============================================================
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CONFIG_REPO="${CONFIG_REPO:-$HOME/claude-config}"
SECRETS_REPO="${SECRETS_REPO:-$HOME/claude-secrets}"
LAUNCHAGENTS_DIR="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
BACKUP_DIR="${CLAUDE_DIR}/backups"
LOCK_DIR="/tmp/claude-self-sync.lock.d"

# 同步目錄清單（公開 → claude-config）
PUBLIC_DIRS=(skills agents commands rules scripts)

# 同步檔案清單（私密 → claude-secrets，含個資 / 設定）
SECRETS_FILES=(CLAUDE.md settings.json mempalace.yaml)

# 同步目錄清單（私密 → claude-secrets）
SECRETS_DIRS=(memory)

# Pull 前備份的目標（會被覆蓋的）
BACKUP_TARGETS=(memory CLAUDE.md settings.json skills commands agents rules scripts hooks)
BACKUP_KEEP=3

# 顏色
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'; C_RESET=$'\033[0m'
log()  { echo "${C_BLUE}[sync]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[ ok ]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[warn]${C_RESET} $*"; }
err()  { echo "${C_RED}[err ]${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# 偵測 rsync 種類：macOS 內建 openrsync 在某些情境會噴 "unlinkat: Directory not empty"，
# 是 cleanup 階段的非致命 warning，檔案實際有同步。我們過濾掉這類噪音。
RSYNC_FILTER='Directory not empty|skipping non-regular file'
rsync_quiet() {
  # 把 stderr 寫到暫存，過濾完再印
  # 用 || 接住 set -e；只有真錯誤（exit > 0 且非 unlinkat 噪音）才往上拋
  local errfile rc=0
  errfile=$(mktemp)
  command rsync "$@" 2>"$errfile" || rc=$?
  # 過濾噪音
  local filtered
  filtered=$(grep -vE "$RSYNC_FILTER" "$errfile" || true)
  [ -n "$filtered" ] && echo "$filtered" >&2
  rm -f "$errfile"
  # openrsync 在某些 unlinkat 情境會 exit 23 但檔案已傳完；
  # 若過濾後沒剩錯誤訊息，視同成功
  if [ "$rc" -ne 0 ] && [ -z "$filtered" ]; then
    return 0
  fi
  return $rc
}
detect_rsync() {
  if rsync --version 2>&1 | head -1 | grep -q openrsync; then
    log "偵測到 openrsync（macOS 內建），unlinkat 噪音將被過濾"
  fi
}

# ============================================================
# 共用：解析參數、取得鎖
# ============================================================
ACTION="${1:-pull}"; shift || true
DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --force|-f)   FORCE=1 ;;
    *) die "unknown arg: $arg" ;;
  esac
done

# rsync exclude（垃圾、nested git、本機快取）
RSYNC_EXCLUDES=(
  --exclude='.git'
  --exclude='.git/'
  --exclude='__pycache__'
  --exclude='*.pyc'
  --exclude='.DS_Store'
  --exclude='*.bak.*'
  --exclude='*.swp'
  --exclude='node_modules'
  --exclude='.venv'
  --exclude='venv'
)

# Push: add-only（不 --delete），保護其他機器推上去的東西不被本機誤刪
PUSH_OPTS=(-a "${RSYNC_EXCLUDES[@]}")
# Pull: 嚴格鏡像（--delete），repo 是 source of truth
PULL_OPTS=(-a --delete "${RSYNC_EXCLUDES[@]}")
if [ "$DRY_RUN" -eq 1 ]; then
  PUSH_OPTS+=(-n -v)
  PULL_OPTS+=(-n -v)
fi

acquire_lock() {
  # 跨平台 mutex：mkdir 是 atomic，比 flock 更通用（macOS 沒內建 flock）
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local lock_pid
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "?")
    # 若 pid 還活著就放棄；不然視為殘留鎖，清掉重試
    if [ "$lock_pid" != "?" ] && kill -0 "$lock_pid" 2>/dev/null; then
      die "另一個 sync 正在跑（pid=${lock_pid}, lock=${LOCK_DIR}）"
    fi
    warn "發現殘留鎖（pid $lock_pid 已死），清掉繼續"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || die "無法建立 lock: $LOCK_DIR"
  fi
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
}

require_repos() {
  [ -d "$CONFIG_REPO/.git" ]  || die "找不到 $CONFIG_REPO（git clone 你的 claude-config）"
  [ -d "$SECRETS_REPO/.git" ] || die "找不到 $SECRETS_REPO（git clone 你的 claude-secrets）"
}

# ============================================================
# 品質檢查（push 前用）
# ============================================================
quality_check() {
  log "品質快檢…"
  local issues=0
  local f
  # 空 skill / 過短 skill
  while IFS= read -r f; do
    local lines
    lines=$(wc -l < "$f" | tr -d ' ')
    if [ "$lines" -lt 20 ]; then
      warn "過短 skill (<20 行): ${f#$CLAUDE_DIR/}  ($lines 行)"
      issues=$((issues+1))
    fi
  done < <(find "$CLAUDE_DIR/skills" -name "SKILL.md" 2>/dev/null)

  # 空 command
  while IFS= read -r f; do
    local lines
    lines=$(wc -l < "$f" | tr -d ' ')
    if [ "$lines" -lt 3 ]; then
      warn "空 command (<3 行): ${f#$CLAUDE_DIR/}"
      issues=$((issues+1))
    fi
  done < <(find "$CLAUDE_DIR/commands" -name "*.md" 2>/dev/null)

  if [ "$issues" -eq 0 ]; then
    ok "品質檢查通過"
  else
    warn "找到 $issues 個問題（不阻擋 push，但建議修）"
  fi
}

# ============================================================
# 兩 repo 是否落後 remote（解 B4 + E1）
# ============================================================
check_remote_uptodate() {
  log "檢查 repo 是否落後 remote（避免覆蓋他機改動）…"
  local repo behind
  for repo in "$CONFIG_REPO" "$SECRETS_REPO"; do
    git -C "$repo" fetch -q origin 2>/dev/null || warn "$repo: fetch 失敗（離線?）"
    behind=$(git -C "$repo" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
    if [ "$behind" -gt 0 ]; then
      err "$repo 落後 remote $behind 個 commit"
      err "→ 請先 /sync pull 把他機改動拉下來，再 push"
      die "中止 push"
    fi
  done
  ok "兩 repo 都是 up-to-date"
}

# ============================================================
# Pull 預掃：列出會被刪的檔案，保護未 push 的本機工作
# ============================================================
preflight_pull_deletes() {
  log "預掃 pull 將刪除的本機檔案…"
  local d deletes=""
  # 對每個目錄做 rsync --dry-run --delete，抓 deleting 行
  for d in "${PUBLIC_DIRS[@]}"; do
    [ -d "$CONFIG_REPO/$d" ] && [ -d "$CLAUDE_DIR/$d" ] || continue
    local out
    out=$(rsync -a --delete -n -i "${RSYNC_EXCLUDES[@]}" \
      "$CONFIG_REPO/$d/" "$CLAUDE_DIR/$d/" 2>&1 | grep -E '^\*deleting' || true)
    [ -n "$out" ] && deletes+="[$d]"$'\n'"$out"$'\n'
  done
  for d in "${SECRETS_DIRS[@]}" agent-memory; do
    [ -d "$SECRETS_REPO/$d" ] && [ -d "$CLAUDE_DIR/$d" ] || continue
    local out
    out=$(rsync -a --delete -n -i "${RSYNC_EXCLUDES[@]}" \
      "$SECRETS_REPO/$d/" "$CLAUDE_DIR/$d/" 2>&1 | grep -E '^\*deleting' || true)
    [ -n "$out" ] && deletes+="[$d]"$'\n'"$out"$'\n'
  done

  if [ -z "$deletes" ]; then
    ok "沒有檔案會被刪除"
    return 0
  fi

  warn "Pull 將刪除以下本機檔案（不在 repo 裡，可能是你還沒 push 的工作）："
  echo "$deletes" | sed 's/^/  /'
  if [ "$FORCE" -eq 1 ]; then
    warn "--force 指定，繼續 pull（已備份到 tarball）"
  else
    err "中止 pull。選項："
    err "  1. 先 push: $0 push"
    err "  2. 確認可棄: $0 pull --force"
    die "(已備份到 $BACKUP_DIR)"
  fi
}

# ============================================================
# Pull 前備份（解 S1）
# ============================================================
backup_before_pull() {
  mkdir -p "$BACKUP_DIR"
  local stamp tarball=$BACKUP_DIR/sync-pull-$(date +%Y%m%d-%H%M%S).tar.gz
  log "備份本機可能被覆蓋的內容 → $tarball"
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "(dry-run) 跳過實際備份"
  else
    local existing=()
    for t in "${BACKUP_TARGETS[@]}"; do
      [ -e "$CLAUDE_DIR/$t" ] && existing+=("$t")
    done
    if [ ${#existing[@]} -gt 0 ]; then
      tar -czf "$tarball" -C "$CLAUDE_DIR" "${existing[@]}" 2>/dev/null
      ok "備份完成 $(du -h "$tarball" | cut -f1)"
    else
      warn "沒東西要備份（首次 pull?）"
    fi
  fi
  # 只保留最近 N 份（用 find 不會被 glob 失敗炸到，pipefail 友善）
  find "$BACKUP_DIR" -maxdepth 1 -name 'sync-pull-*.tar.gz' -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | tail -n +$((BACKUP_KEEP+1)) \
    | xargs -I{} rm -f "{}" || true
}

# ============================================================
# 清掉 dest repo 裡歷史殘留的垃圾（exclude pattern 對應的東西）
# 為什麼必要：舊版 sync 沒 exclude，把 .git/__pycache__/.DS_Store 推上去；
# 新版 exclude 了這些，但 dest 殘留還在 → rsync 嘗試更新 parent dir 時
# 撞 unlinkat 錯誤。所以 push 前要先清。
# ============================================================
clean_repo_garbage() {
  [ "$DRY_RUN" -eq 1 ] && { log "(dry-run) 跳過清 repo 殘留垃圾"; return 0; }
  local repo
  for repo in "$CONFIG_REPO" "$SECRETS_REPO"; do
    find "$repo" -depth \
      \( -name '__pycache__' -o -name '*.pyc' -o -name '.DS_Store' \
         -o -name '*.bak.*' -o -name '*.swp' -o -name 'node_modules' \
         -o -name '.venv' -o -name 'venv' \) \
      -not -path "$repo/.git/*" \
      -exec rm -rf {} + 2>/dev/null || true
    # nested .git（不是 repo 自己的）
    find "$repo" -mindepth 2 -name '.git' -not -path "$repo/.git/*" \
      -exec rm -rf {} + 2>/dev/null || true
  done
}

# ============================================================
# Push: 本機 → repo
# ============================================================
do_push() {
  detect_rsync
  acquire_lock
  require_repos
  check_remote_uptodate
  quality_check
  clean_repo_garbage

  log "Push: 本機 → repo（dry-run=${DRY_RUN}）"

  # claude-config: 公開的 skills/agents/commands/rules/scripts
  local d
  for d in "${PUBLIC_DIRS[@]}"; do
    if [ -d "$CLAUDE_DIR/$d" ]; then
      mkdir -p "$CONFIG_REPO/$d"
      rsync_quiet "${PUSH_OPTS[@]}" "$CLAUDE_DIR/$d/" "$CONFIG_REPO/$d/"
    fi
  done

  # hooks: 只同步 hooks.json，不含 binary / sound 包
  if [ -f "$CLAUDE_DIR/hooks/hooks.json" ]; then
    mkdir -p "$CONFIG_REPO/hooks"
    rsync_quiet -a $([ "$DRY_RUN" -eq 1 ] && echo "-n -v") \
      "$CLAUDE_DIR/hooks/hooks.json" "$CONFIG_REPO/hooks/hooks.json"
  fi

  # claude-secrets: CLAUDE.md / memory / settings.json
  local f
  for f in "${SECRETS_FILES[@]}"; do
    if [ -f "$CLAUDE_DIR/$f" ]; then
      rsync_quiet -a $([ "$DRY_RUN" -eq 1 ] && echo "-n -v") \
        "$CLAUDE_DIR/$f" "$SECRETS_REPO/$f"
    fi
  done
  for d in "${SECRETS_DIRS[@]}"; do
    if [ -d "$CLAUDE_DIR/$d" ]; then
      mkdir -p "$SECRETS_REPO/$d"
      rsync_quiet "${PUSH_OPTS[@]}" "$CLAUDE_DIR/$d/" "$SECRETS_REPO/$d/"
    fi
  done

  # .mcp.json → 寫成 example（不直接同步，避免跨機路徑炸）
  if [ -f "$CLAUDE_DIR/.mcp.json" ] && [ "$DRY_RUN" -eq 0 ]; then
    cp "$CLAUDE_DIR/.mcp.json" "$SECRETS_REPO/.mcp.json.example"
    ok ".mcp.json → secrets/.mcp.json.example（範本，新機需手動編輯）"
  fi

  # agent-memory（opt-in: 存在才同步）
  if [ -d "$CLAUDE_DIR/agent-memory" ]; then
    mkdir -p "$SECRETS_REPO/agent-memory"
    rsync_quiet "${PUSH_OPTS[@]}" "$CLAUDE_DIR/agent-memory/" "$SECRETS_REPO/agent-memory/"
  fi

  # services + launchd plist（opt-in）
  if [ -d "$CLAUDE_DIR/services" ]; then
    mkdir -p "$SECRETS_REPO/services"
    rsync_quiet "${PUSH_OPTS[@]}" \
      --exclude='.env' --exclude='*.log' \
      "$CLAUDE_DIR/services/" "$SECRETS_REPO/services/"

    local svc_dir svc_name plist
    for svc_dir in "$CLAUDE_DIR/services"/*/; do
      [ -d "$svc_dir" ] || continue
      svc_name=$(basename "$svc_dir")
      for plist in "$LAUNCHAGENTS_DIR"/*.plist; do
        [ -f "$plist" ] || continue
        if grep -q "$svc_name" "$plist" 2>/dev/null; then
          mkdir -p "$SECRETS_REPO/services/$svc_name/launchd"
          if [ "$DRY_RUN" -eq 0 ]; then
            cp "$plist" "$SECRETS_REPO/services/$svc_name/launchd/"
          fi
        fi
      done
    done
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    warn "(dry-run) 跳過 git commit / push"
    return 0
  fi

  # Commit + push 兩個 repo
  local repo
  for repo in "$CONFIG_REPO" "$SECRETS_REPO"; do
    if ! git -C "$repo" diff --cached --quiet 2>/dev/null \
       || ! git -C "$repo" diff --quiet \
       || [ -n "$(git -C "$repo" ls-files -o --exclude-standard)" ]; then
      git -C "$repo" add -A
      git -C "$repo" commit -m "sync: from $(hostname -s) on $(date +%Y-%m-%d)" >/dev/null
      git -C "$repo" push -q
      ok "$repo: pushed"
    else
      log "$repo: 沒變化"
    fi
  done

  ok "Push 完成"
}

# ============================================================
# Pull: repo → 本機
# ============================================================
do_pull() {
  detect_rsync
  acquire_lock
  require_repos

  log "Pull: 拉 remote → repo"
  local repo
  for repo in "$CONFIG_REPO" "$SECRETS_REPO"; do
    if [ "$DRY_RUN" -eq 1 ]; then
      git -C "$repo" fetch -q
      local behind
      behind=$(git -C "$repo" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
      log "$repo: 落後 $behind commit（dry-run 不 pull）"
    else
      git -C "$repo" pull -q --ff-only
      ok "$repo: pulled"
    fi
  done

  preflight_pull_deletes
  backup_before_pull

  log "Pull: repo → 本機（dry-run=${DRY_RUN}）"

  # claude-config → local（用 rsync --delete，repo 為權威）
  local d f
  for d in "${PUBLIC_DIRS[@]}"; do
    if [ -d "$CONFIG_REPO/$d" ]; then
      mkdir -p "$CLAUDE_DIR/$d"
      rsync_quiet "${PULL_OPTS[@]}" "$CONFIG_REPO/$d/" "$CLAUDE_DIR/$d/"
    fi
  done

  if [ -f "$CONFIG_REPO/hooks/hooks.json" ]; then
    mkdir -p "$CLAUDE_DIR/hooks"
    rsync_quiet -a $([ "$DRY_RUN" -eq 1 ] && echo "-n -v") \
      "$CONFIG_REPO/hooks/hooks.json" "$CLAUDE_DIR/hooks/hooks.json"
  fi

  # claude-secrets → local
  for f in "${SECRETS_FILES[@]}"; do
    if [ -f "$SECRETS_REPO/$f" ]; then
      rsync_quiet -a $([ "$DRY_RUN" -eq 1 ] && echo "-n -v") \
        "$SECRETS_REPO/$f" "$CLAUDE_DIR/$f"
    fi
  done
  for d in "${SECRETS_DIRS[@]}"; do
    if [ -d "$SECRETS_REPO/$d" ]; then
      mkdir -p "$CLAUDE_DIR/$d"
      rsync_quiet "${PULL_OPTS[@]}" "$SECRETS_REPO/$d/" "$CLAUDE_DIR/$d/"
    fi
  done

  # agent-memory
  if [ -d "$SECRETS_REPO/agent-memory" ]; then
    mkdir -p "$CLAUDE_DIR/agent-memory"
    rsync_quiet "${PULL_OPTS[@]}" "$SECRETS_REPO/agent-memory/" "$CLAUDE_DIR/agent-memory/"
  fi

  # services（不覆蓋本機 .env / *.log / launchd 子目錄）
  if [ -d "$SECRETS_REPO/services" ]; then
    mkdir -p "$CLAUDE_DIR/services"
    rsync_quiet -a $([ "$DRY_RUN" -eq 1 ] && echo "-n -v") \
      --exclude='.env' --exclude='*.log' --exclude='launchd' \
      "$SECRETS_REPO/services/" "$CLAUDE_DIR/services/"

    # plist 從 secrets/services/<name>/launchd/ 安裝到 ~/Library/LaunchAgents/
    local plist_dir
    for plist_dir in "$SECRETS_REPO/services"/*/launchd; do
      [ -d "$plist_dir" ] || continue
      if [ "$DRY_RUN" -eq 0 ]; then
        cp "$plist_dir"/*.plist "$LAUNCHAGENTS_DIR/" 2>/dev/null || true
      else
        ls "$plist_dir"/*.plist 2>/dev/null | while read -r p; do
          log "(dry-run) would install plist: $(basename "$p")"
        done
      fi
    done
  fi

  # .mcp.json: 不覆蓋本機，只提示有沒有新 example
  if [ -f "$SECRETS_REPO/.mcp.json.example" ] && [ ! -f "$CLAUDE_DIR/.mcp.json" ]; then
    warn "本機沒 .mcp.json，但 secrets repo 有範本："
    warn "  cp $SECRETS_REPO/.mcp.json.example $CLAUDE_DIR/.mcp.json"
    warn "  然後改裡面的絕對路徑成本機的"
  fi

  ok "Pull 完成"
  log "提醒："
  log "  - mempalace MCP 不在同步範圍（pip 套件）。新機需 pip install mempalace"
  log "  - .mcp.json 各機獨立配置（範本在 secrets/.mcp.json.example）"
  log "  - 新 plist 載入：launchctl load -w ~/Library/LaunchAgents/<name>.plist"
}

# ============================================================
# Status: 顯示差異不寫入
# ============================================================
do_status() {
  require_repos
  log "本機 vs config repo 差異："
  local d
  for d in "${PUBLIC_DIRS[@]}"; do
    if [ -d "$CLAUDE_DIR/$d" ] && [ -d "$CONFIG_REPO/$d" ]; then
      diff -rq "$CLAUDE_DIR/$d" "$CONFIG_REPO/$d" 2>/dev/null | head -10 || true
    fi
  done
  log "本機 vs secrets repo 差異："
  local f
  for f in "${SECRETS_FILES[@]}"; do
    if [ -f "$CLAUDE_DIR/$f" ] && [ -f "$SECRETS_REPO/$f" ]; then
      diff -q "$CLAUDE_DIR/$f" "$SECRETS_REPO/$f" 2>/dev/null || true
    fi
  done
  for d in "${SECRETS_DIRS[@]}"; do
    if [ -d "$CLAUDE_DIR/$d" ] && [ -d "$SECRETS_REPO/$d" ]; then
      diff -rq "$CLAUDE_DIR/$d" "$SECRETS_REPO/$d" 2>/dev/null | head -10 || true
    fi
  done
}

# ============================================================
# Dispatch
# ============================================================
case "$ACTION" in
  push)   do_push ;;
  pull)   do_pull ;;
  status) do_status ;;
  *)      die "Usage: $0 {push|pull|status} [--dry-run]" ;;
esac
