#!/usr/bin/env bash
# ==============================================================================
# demo.sh —— 基于 Token 投票治理管理 Bank 资金：完整多选民演示（真实 anvil 链）
#
# 为什么用 shell + cast 编排，而不是 forge script：
#   1. 治理流程跨区块（votingDelay / votingPeriod），forge script 里的 vm.roll
#      是模拟专用 cheatcode，无法随 --broadcast 上链；本脚本用
#      `cast rpc anvil_mine <n>` 在各阶段之间真实推进区块。
#   2. 多选民投票：每张选票必须由选民本人发出（按 msg.sender 计票），
#      `cast send --private-key <选民私钥>` 天然支持多账户各自签名，
#      不受 forge script 单一 broadcast 账户限制。
#
# 演示流程：
#   阶段 0  准备本地链（复用已运行的 anvil，否则自启临时 anvil，退出时回收）
#   阶段 1  部署 VoteToken / Governor / Bank，国库注资 10 ETH
#   阶段 2  分发治理代币给 alice / bob / carol，四账户各自 delegate(self)
#   阶段 3  提案 1（通过）：deployer 发起「从 Bank 提 1 ETH 给 alice」
#           → alice 赞成 / bob 赞成 / carol 弃权 → 推进区块过投票期
#           → carol（任意人）执行 → alice 到账 1 ETH
#   阶段 4  提案 2（否决）：bob 发起，仅 carol 赞成（10k < quorum 40k）
#           → Defeated → execute 正确 revert，国库资金安全
#
# 运行：bash test/vote-govern/demo.sh        （默认端口 8546，可用 PORT=xxx 覆盖）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

# ==================== 配置 ====================
PORT="${PORT:-8546}"
RPC_URL="http://127.0.0.1:${PORT}"

# anvil 默认账户私钥（本地演示用，切勿用于真实网络）
PK_DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # anvil #0
PK_ALICE=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d      # anvil #1
PK_BOB=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a       # anvil #2
PK_CAROL=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6     # anvil #3

# 地址直接由私钥推导，避免手抄地址与私钥错配
DEPLOYER=$(cast wallet address --private-key "$PK_DEPLOYER")
ALICE=$(cast wallet address --private-key "$PK_ALICE")
BOB=$(cast wallet address --private-key "$PK_BOB")
CAROL=$(cast wallet address --private-key "$PK_CAROL")

# 治理参数（与 test/vote-govern/VoteGovern.t.sol 保持一致）
INITIAL_SUPPLY=$(cast to-wei 1000000) # 1,000,000 VGT
VOTING_DELAY=1                        # 1 块后开始投票
VOTING_PERIOD=10                      # 投票持续 10 块
QUORUM_NUM=4                          # 4% => quorum = 40,000 VGT
BANK_FUND=10ether                     # 国库初始注资

# ==================== 辅助函数 ====================
banner() { printf '\n\033[1;36m================ %s ================\033[0m\n' "$1"; }
info() { printf '\033[1;32m[+]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[!] 失败：%s\033[0m\n' "$1" >&2; exit 1; }

# send_tx <私钥> <目标合约> <签名> [参数...] —— 发交易；失败打印定位信息并返回非零
# 注：普通调用下 set -e 会中止脚本；若包在 if 条件中（如预期 revert 场景）则由调用方处理
send_tx() {
  if ! cast send --private-key "$1" --rpc-url "$RPC_URL" "$2" "$3" "${@:4}" >/dev/null; then
    printf '\033[1;33m[i] 交易失败：%s @ %s\033[0m\n' "$3" "$2" >&2
    return 1
  fi
}

# call_hex <合约> <签名> [参数...] —— 只读调用，返回原始 hex
call_hex() {
  cast call "$1" "$2" "${@:3}" --rpc-url "$RPC_URL"
}

# call_uint <合约> <签名> [参数...] —— 只读调用，返回 uint 十进制
call_uint() {
  call_hex "$@" | cast to-dec
}

# mine <块数> —— 真实推进区块
mine() {
  cast rpc anvil_mine "$1" --rpc-url "$RPC_URL" >/dev/null
}

# 州名映射（Governor.ProposalState 枚举）
state_name() {
  case "$1" in
    0) echo "Pending" ;;
    1) echo "Active" ;;
    2) echo "Canceled" ;;
    3) echo "Defeated" ;;
    4) echo "Succeeded" ;;
    5) echo "Executed" ;;
    *) echo "Unknown($1)" ;;
  esac
}

# 部署 <bytecode> <构造签名> [构造参数...] —— 返回新合约地址
deploy() {
  local out addr
  out=$(cast send --private-key "$PK_DEPLOYER" --rpc-url "$RPC_URL" --create "$1" "$2" "${@:3}")
  addr=$(printf '%s\n' "$out" | awk '/^contractAddress/{print $2}')
  [ -n "$addr" ] || { printf '%s\n' "$out" | tail -20 >&2; fail "部署失败：receipt 中无 contractAddress"; }
  printf '%s' "$addr"
}

# ==================== 阶段 0：准备本地链 ====================
banner "阶段 0：准备本地链 (port ${PORT})"
STARTED_ANVIL=0
if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  info "复用已运行的本地链（假定其为 anvil 默认账户集）"
else
  info "启动临时 anvil ..."
  ANVIL_LOG="${TMPDIR:-/tmp}/vote-govern-anvil.log"
  anvil --port "$PORT" >"$ANVIL_LOG" 2>&1 &
  ANVIL_PID=$!
  STARTED_ANVIL=1
  for _ in $(seq 1 50); do
    cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1 && break
    sleep 0.2
  done
  cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1 || fail "anvil 未就绪（日志：${ANVIL_LOG}）"
fi
cleanup() {
  if [ "$STARTED_ANVIL" = "1" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    info "已停止临时 anvil"
  fi
}
trap cleanup EXIT
info "链就绪，当前块高 $(cast block-number --rpc-url "$RPC_URL")"

# ==================== 阶段 1：部署三合约 + 国库注资 ====================
banner "阶段 1：部署 VoteToken / Governor / Bank 并注资国库"
forge build >/dev/null 2>&1 || fail "forge build 失败"

VT_CODE=$(forge inspect src/vote-govern/VoteToken.sol:VoteToken bytecode)
GV_CODE=$(forge inspect src/vote-govern/Governor.sol:Governor bytecode)
BK_CODE=$(forge inspect src/vote-govern/Bank.sol:Bank bytecode)

TOKEN=$(deploy "$VT_CODE" "constructor(uint256)" "$INITIAL_SUPPLY")
info "VoteToken 部署于 ${TOKEN}"
GOV=$(deploy "$GV_CODE" "constructor(address,uint256,uint256,uint256)" "$TOKEN" "$VOTING_DELAY" "$VOTING_PERIOD" "$QUORUM_NUM")
info "Governor  部署于 ${GOV}"
BANK=$(deploy "$BK_CODE" "constructor(address)" "$GOV")
info "Bank      部署于 ${BANK} (admin = Governor)"

# 国库注资：直接向 Bank 转账（触发 receive()）
cast send --private-key "$PK_DEPLOYER" --rpc-url "$RPC_URL" "$BANK" --value "$BANK_FUND" >/dev/null
info "国库注资 10 ETH，当前余额 $(cast balance "$BANK" --ether --rpc-url "$RPC_URL") ETH"

# 部署后立即校验 admin 关系（统一小写比较，避免大小写格式差异）
ADMIN_HEX=$(call_hex "$BANK" "admin()")
ADMIN_ADDR=$(cast abi-decode "a()(address)" "$ADMIN_HEX" | awk '{print $1}')
ADMIN_LC=$(printf '%s' "$ADMIN_ADDR" | tr '[:upper:]' '[:lower:]')
GOV_LC=$(printf '%s' "$GOV" | tr '[:upper:]' '[:lower:]')
[ "$ADMIN_LC" = "$GOV_LC" ] || fail "Bank.admin(${ADMIN_LC}) != Governor(${GOV_LC})"
info "校验通过：Bank.admin == Governor"

# ==================== 阶段 2：分发代币 + 多选民委托 ====================
banner "阶段 2：分发治理代币，多选民各自委托"
AMT_ALICE=$(cast to-wei 100000)  # 100,000 VGT
AMT_BOB=$(cast to-wei 100000)    # 100,000 VGT
AMT_CAROL=$(cast to-wei 10000)   # 10,000 VGT

send_tx "$PK_DEPLOYER" "$TOKEN" "transfer(address,uint256)" "$ALICE" "$AMT_ALICE"
send_tx "$PK_DEPLOYER" "$TOKEN" "transfer(address,uint256)" "$BOB" "$AMT_BOB"
send_tx "$PK_DEPLOYER" "$TOKEN" "transfer(address,uint256)" "$CAROL" "$AMT_CAROL"

# 四账户显式 delegate(self)（演示委托；未显式委托时也默认自委托）
send_tx "$PK_DEPLOYER" "$TOKEN" "delegate(address)" "$DEPLOYER"
send_tx "$PK_ALICE" "$TOKEN" "delegate(address)" "$ALICE"
send_tx "$PK_BOB" "$TOKEN" "delegate(address)" "$BOB"
send_tx "$PK_CAROL" "$TOKEN" "delegate(address)" "$CAROL"

info "当前投票权（getCurrentVotes）："
printf '    deployer = %s VGT\n' "$(cast from-wei "$(call_uint "$TOKEN" "getCurrentVotes(address)" "$DEPLOYER")")"
printf '    alice    = %s VGT\n' "$(cast from-wei "$(call_uint "$TOKEN" "getCurrentVotes(address)" "$ALICE")")"
printf '    bob      = %s VGT\n' "$(cast from-wei "$(call_uint "$TOKEN" "getCurrentVotes(address)" "$BOB")")"
printf '    carol    = %s VGT\n' "$(cast from-wei "$(call_uint "$TOKEN" "getCurrentVotes(address)" "$CAROL")")"

# ==================== 阶段 3：提案 1（预期通过并执行） ====================
banner "阶段 3：提案 1 —— 从 Bank 提 1 ETH 给 alice（预期通过）"

# 组装提案动作：调用 Bank.withdraw(alice, 1 ether)
WD1=$(cast calldata "withdraw(address,uint256)" "$ALICE" "1ether")
send_tx "$PK_DEPLOYER" "$GOV" \
  "propose(address[],uint256[],bytes[],string)" \
  "[$BANK]" "[0]" "[$WD1]" "Treasury: withdraw 1 ETH to alice"

PID1=$(call_uint "$GOV" "proposalCount()")
info "提案 ID=${PID1}，快照块=$(call_uint "$GOV" "proposalSnapshot(uint256)" "$PID1")，截止块=$(call_uint "$GOV" "proposalDeadline(uint256)" "$PID1")"
info "提案后状态：$(state_name "$(call_uint "$GOV" "state(uint256)" "$PID1")")"

# 推进 votingDelay + 1 块，进入投票期
mine "$((VOTING_DELAY + 1))"
info "推进区块后状态：$(state_name "$(call_uint "$GOV" "state(uint256)" "$PID1")")"

# 多选民各自签名投票：alice 赞成(1)、bob 赞成(1)、carol 弃权(2)
info "alice  投票 赞成(1) ..."
send_tx "$PK_ALICE" "$GOV" "castVote(uint256,uint8)" "$PID1" 1
info "bob    投票 赞成(1) ..."
send_tx "$PK_BOB" "$GOV" "castVote(uint256,uint8)" "$PID1" 1
info "carol  投票 弃权(2) ..."
send_tx "$PK_CAROL" "$GOV" "castVote(uint256,uint8)" "$PID1" 2

# 显示计票与法定人数（abi-decode 逐行输出 赞成/反对/弃权）
TALLY_HEX=$(call_hex "$GOV" "getProposalTally(uint256)" "$PID1")
TALLY_OUT=$(cast abi-decode "t()(uint256,uint256,uint256)" "$TALLY_HEX" | awk '{print $1}')
FOR_V=$(printf '%s\n' "$TALLY_OUT" | sed -n 1p)
AGN_V=$(printf '%s\n' "$TALLY_OUT" | sed -n 2p)
ABS_V=$(printf '%s\n' "$TALLY_OUT" | sed -n 3p)
info "计票：赞成 $(cast from-wei "$FOR_V") / 反对 $(cast from-wei "$AGN_V") / 弃权 $(cast from-wei "$ABS_V") VGT"
info "法定人数要求（quorumVotes）：$(cast from-wei "$(call_uint "$GOV" "quorumVotes(uint256)" "$PID1")") VGT"

# 推进区块过投票期（endBlock + 1）
mine "$((VOTING_PERIOD + 2))"
S1=$(call_uint "$GOV" "state(uint256)" "$PID1")
info "投票期结束，状态：$(state_name "$S1")"
[ "$S1" = "4" ] || fail "提案 1 应为 Succeeded(4)，实际 $S1"

# 任意人（carol）执行提案 —— Governor 以 Bank.admin 身份调用 Bank.withdraw
ALICE_BEFORE=$(cast balance "$ALICE" --rpc-url "$RPC_URL")
BANK_BEFORE=$(cast balance "$BANK" --rpc-url "$RPC_URL")
info "carol 执行提案（执行无需权限，任何人可触发）..."
send_tx "$PK_CAROL" "$GOV" "execute(uint256)" "$PID1"

ALICE_AFTER=$(cast balance "$ALICE" --rpc-url "$RPC_URL")
BANK_AFTER=$(cast balance "$BANK" --rpc-url "$RPC_URL")
DIFF_ALICE=$(echo "$ALICE_AFTER - $ALICE_BEFORE" | bc)
DIFF_BANK=$(echo "$BANK_AFTER - $BANK_BEFORE" | bc)
[ "$DIFF_ALICE" = "1000000000000000000" ] || fail "alice 应到账 1 ETH，实际差值 $DIFF_ALICE wei"
[ "$DIFF_BANK" = "-1000000000000000000" ] || fail "国库应减少 1 ETH，实际差值 $DIFF_BANK wei"
info "✓ alice 到账 1 ETH（$(cast from-wei "$DIFF_ALICE") ETH），国库余额 $(cast from-wei "$BANK_AFTER") ETH"
info "执行后状态：$(state_name "$(call_uint "$GOV" "state(uint256)" "$PID1")")"

# ==================== 阶段 4：提案 2（预期否决） ====================
banner "阶段 4：提案 2 —— 仅 carol 小额赞成，quorum 不足（预期否决）"

WD2=$(cast calldata "withdraw(address,uint256)" "$BOB" "1ether")
send_tx "$PK_BOB" "$GOV" \
  "propose(address[],uint256[],bytes[],string)" \
  "[$BANK]" "[0]" "[$WD2]" "Treasury: withdraw 1 ETH to bob"

PID2=$(call_uint "$GOV" "proposalCount()")
info "提案 ID=${PID2}（提案者 bob，拥有投票权可通过校验）"

mine "$((VOTING_DELAY + 1))"
info "仅 carol 投赞成（10k VGT < quorum 40k VGT）..."
send_tx "$PK_CAROL" "$GOV" "castVote(uint256,uint8)" "$PID2" 1

mine "$((VOTING_PERIOD + 2))"
S2=$(call_uint "$GOV" "state(uint256)" "$PID2")
info "投票期结束，状态：$(state_name "$S2")"
[ "$S2" = "3" ] || fail "提案 2 应为 Defeated(3)，实际 $S2"

# 执行 Defeated 提案应 revert
BANK_BEFORE2=$(cast balance "$BANK" --rpc-url "$RPC_URL")
if send_tx "$PK_ALICE" "$GOV" "execute(uint256)" "$PID2" 2>/dev/null; then
  fail "Defeated 提案不应可执行"
else
  info "✓ execute 正确 revert（Defeated 不可执行），国库资金安全"
fi
BANK_AFTER2=$(cast balance "$BANK" --rpc-url "$RPC_URL")
[ "$BANK_BEFORE2" = "$BANK_AFTER2" ] || fail "国库余额不应变化"

# ==================== 总结 ====================
banner "演示完成：多选民投票治理 Bank 资金"
printf 'VoteToken : %s\n' "$TOKEN"
printf 'Governor  : %s\n' "$GOV"
printf 'Bank      : %s（admin=Governor）\n' "$BANK"
printf '提案 %s ：Succeeded -> Executed，alice 收到 1 ETH\n' "$PID1"
printf '提案 %s ：Defeated（quorum 不足），国库分文未动\n' "$PID2"
printf '国库余额 ：%s ETH\n' "$(cast balance "$BANK" --ether --rpc-url "$RPC_URL")"
info "完整链路：propose -> (多选民) castVote -> anvil_mine -> execute -> Bank.withdraw"
