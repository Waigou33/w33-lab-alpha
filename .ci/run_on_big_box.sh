#!/usr/bin/env bash
# 128 核大机器上的一键编译 + 基准脚本（无第三方依赖，只用系统工具）
# 用法： bash run_on_big_box.sh [patch|nopatch]
set -uo pipefail

MODE="${1:-patch}"
WORK="${WORK:-$HOME/seekdb_build}"
LOG="$HOME/fts_run.log"
REPO="https://github.com/Waigou33/w33-lab-alpha.git"
BRANCH="perf/fts-ab"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

{
log "=== step 0: 环境 ==="
nproc; free -g | head -2; df -h "$HOME" | tail -1

log "=== step 1: 依赖 ==="
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq binutils build-essential ccache cpio rpm rpm2cpio \
      libaio-dev libncurses-dev libtool-bin m4 wget curl patchelf >/dev/null 2>&1 \
    && log "apt ok" || log "apt 安装失败（可能已装齐，继续）"
fi
for t in gcc g++ make cmake git python3 ccache; do
  printf '  %-8s %s\n' "$t" "$(command -v $t 2>/dev/null || echo MISSING)"
done

log "=== step 2: 源码 ==="
if [ ! -d "$WORK/.git" ]; then
  rm -rf "$WORK"
  git clone --depth 1 -b "$BRANCH" "$REPO" "$WORK" || { log "clone 失败"; exit 2; }
fi
cd "$WORK" || exit 2
git fetch --depth 1 origin "$BRANCH" >/dev/null 2>&1 || true
git reset --hard "origin/$BRANCH" >/dev/null 2>&1 || git reset --hard HEAD
git log --oneline -1

if [ "$MODE" = "patch" ]; then
  log "打补丁 .ci/perf.patch"
  if git apply --check .ci/perf.patch 2>/dev/null; then
    git apply .ci/perf.patch && log "PATCH_OK"
  else
    log "PATCH_SKIP（补丁已是当前状态或打不上）"
    git diff --stat | tail -5
  fi
else
  log "基线模式：不打补丁"
fi
git diff --stat | tail -8

log "=== step 3: init deps ==="
timeout 3600 bash ./build.sh init 2>&1 | tail -3

log "=== step 4: configure ==="
timeout 1800 bash ./build.sh release -DOB_USE_CCACHE=ON -DNEED_PARSER_CACHE=OFF 2>&1 | tail -5

log "=== step 5: 编译（$(nproc) 并发）==="
SECONDS=0
timeout 7200 cmake --build build_release --target seekdb -j"$(nproc)" 2>&1 | tail -12
log "编译耗时 ${SECONDS}s"
ls -l build_release/src/observer/seekdb 2>/dev/null || { log "二进制不存在，编译失败"; exit 3; }
build_release/src/observer/seekdb -V 2>&1 | head -2

log "=== step 6: 起库 ==="
W="$HOME/fts_work"; rm -rf "$W"; mkdir -p "$W"
cp build_release/src/observer/seekdb "$W/observer" && chmod +x "$W/observer"
cd "$W" || exit 3
(./observer > observer.log 2>&1 &)
for _ in $(seq 1 180); do [ -f run/seekdb.pid ] && break; sleep 1; done
if [ ! -f run/seekdb.pid ]; then log "observer 未启动"; tail -60 observer.log; exit 4; fi
log "observer pid=$(cat run/seekdb.pid)"

CLIENT="$(find "$WORK/deps/3rd" -maxdepth 8 -path '*/bin/obclient' -type f -print -quit 2>/dev/null)"
[ -n "$CLIENT" ] || { log "找不到 obclient"; exit 4; }
chmod +x "$CLIENT" 2>/dev/null
export LD_LIBRARY_PATH="$(dirname "$CLIENT")/../lib:${LD_LIBRARY_PATH:-}"
export MYSQL="$CLIENT -h127.0.0.1 -P2881 -uroot -N -s -A --default-character-set=utf8mb4"
export MYSQL_VERBOSE="$CLIENT -h127.0.0.1 -P2881 -uroot -A --default-character-set=utf8mb4"
for _ in $(seq 1 120); do $CLIENT -h127.0.0.1 -P2881 -uroot -A -e 'SELECT 1;' >/dev/null 2>&1 && break; sleep 1; done
$CLIENT -h127.0.0.1 -P2881 -uroot -A -e 'SELECT 1;' || { log "SQL 不可用"; exit 4; }

log "=== step 7: 官方基准（SKIP_LOAD=0，两轮）==="
for r in 1 2; do
  log "---- round $r ----"
  LABEL="bigbox-$MODE-r$r" OUTPUT="$HOME/report_$MODE.txt" \
  SKIP_LOAD=0 ROWS=20000 BATCH=500 ROUNDS=3000 QUERY_ROUNDS=200 SAMPLES=3 WARMUP=30 \
    timeout 3600 bash "$WORK/tools/benchmark/fts_large_bench.sh" 2>&1 | tail -30
  log "score round $r:"
  python3 "$WORK/tools/benchmark/fts_large_bench_score.py" "$HOME/report_$MODE.txt" 2>&1 | head -30
done

log "=== step 8: 收尾 ==="
[ -f run/seekdb.pid ] && kill "$(cat run/seekdb.pid)" 2>/dev/null
log "REPORT: $HOME/report_$MODE.txt   LOG: $LOG"
} 2>&1 | tee -a "$LOG"
