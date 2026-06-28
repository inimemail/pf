#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/pure-port-forward"
RULE_FILE="$BASE_DIR/rules.db"
APPLY_SCRIPT="$BASE_DIR/apply.sh"
SERVICE_FILE="/etc/systemd/system/pure-port-forward.service"
NFT_CONF="$BASE_DIR/rules.nft"
NFT_TABLE="ppf_nat"
SYSCTL_CONF="/etc/sysctl.d/99-pure-port-forward.conf"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
BOLD="\033[1m"
DIM="\033[2m"
NC="\033[0m"

umask 077

ok() { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err() { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }

line() {
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

header() {
  clear
  line
  echo -e "${BOLD}${CYAN}$1${NC}"
  line
  echo
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 运行"
    echo "示例：sudo bash $0"
    exit 1
  fi
}

init_storage() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"
  touch "$RULE_FILE"
  chmod 600 "$RULE_FILE"
}

pause() {
  echo
  read -rp "按回车继续..." _ || true
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_pkg_manager() {
  if has_cmd apt-get; then
    echo "apt"
  elif has_cmd dnf; then
    echo "dnf"
  elif has_cmd yum; then
    echo "yum"
  else
    echo "unknown"
  fi
}

install_deps() {
  local missing=()

  for cmd in nft sysctl systemctl getent ss awk sed grep jq; do
    if ! has_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi

  warn "检测到缺少依赖：${missing[*]}"

  local pm
  pm="$(detect_pkg_manager)"

  case "$pm" in
    apt)
      info "正在自动安装依赖..."
      apt-get update -y
      apt-get install -y nftables iproute2 procps systemd jq
      ;;
    dnf)
      info "正在自动安装依赖..."
      dnf install -y nftables iproute procps-ng systemd jq
      ;;
    yum)
      info "正在自动安装依赖..."
      yum install -y nftables iproute procps-ng systemd jq
      ;;
    *)
      err "无法识别包管理器，请手动安装：nftables iproute2/procps/systemd jq"
      exit 1
      ;;
  esac

  systemctl enable --now nftables >/dev/null 2>&1 || true

  local still_missing=0
  for cmd in nft sysctl systemctl getent ss awk sed grep jq; do
    if ! has_cmd "$cmd"; then
      err "仍然缺少命令：$cmd"
      still_missing=1
    fi
  done

  if [[ "$still_missing" = 1 ]]; then
    exit 1
  fi
}

trim() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 ))
}

normalize_port() {
  local p="$1"
  printf '%d' "$((10#$p))"
}

valid_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  (( ${#name} <= 40 )) || return 1
  [[ "$name" != *"|"* ]] || return 1
  [[ ! "$name" =~ [[:cntrl:]] ]] || return 1
}

is_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local a b c d
  IFS='.' read -r a b c d <<< "$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$n >= 0 && 10#$n <= 255 )) || return 1
  done
}

is_domain() {
  local host="${1:-}"
  [[ "$host" == "localhost" ]] && return 0
  (( ${#host} >= 1 && ${#host} <= 253 )) || return 1
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || return 1
  [[ "$host" != *".."* ]] || return 1

  local label
  IFS='.' read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [[ -n "$label" ]] || return 1
    (( ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

valid_host() {
  local host="${1:-}"
  [[ -n "$host" ]] || return 1
  [[ "$host" != *" "* && "$host" != *"|"* && "$host" != *"/"* ]] || return 1
  [[ ! "$host" =~ [[:cntrl:]] ]] || return 1
  is_ipv4 "$host" || is_domain "$host"
}

parse_dest() {
  local dest host dport
  dest="$(trim "${1:-}")"

  [[ "$dest" != http://* && "$dest" != https://* ]] || return 2
  [[ "$dest" =~ ^([^:[:space:]]+):([0-9]{1,5})$ ]] || return 1

  host="${BASH_REMATCH[1]}"
  dport="${BASH_REMATCH[2]}"

  valid_host "$host" || return 3
  valid_port "$dport" || return 4

  dport="$(normalize_port "$dport")"
  printf '%s|%s|%s:%s\n' "$host" "$dport" "$host" "$dport"
}

resolve_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" | awk '{print $1; exit}'
}

line_count() {
  grep -cv '^[[:space:]]*$' "$RULE_FILE" || true
}

port_in_rules() {
  local port="$1"
  awk -F'|' -v p="$port" '$2 == p { found=1 } END { exit !found }' "$RULE_FILE"
}

port_in_file() {
  local port="$1"
  local file="$2"
  [[ -s "$file" ]] || return 1
  awk -F'|' -v p="$port" '$2 == p { found=1 } END { exit !found }' "$file"
}

port_in_system() {
  local port="$1"
  ss -H -lntup 2>/dev/null | awk -v port="$port" '
    {
      addr=$5
      if (addr ~ ":" port "$" || addr ~ "\\]:" port "$") found=1
    }
    END { exit !found }
  '
}

show_port_owner() {
  local port="$1"
  ss -H -lntup 2>/dev/null | awk -v port="$port" '
    {
      addr=$5
      if (addr ~ ":" port "$" || addr ~ "\\]:" port "$") print
    }
  ' || true
}

check_listen_port_available() {
  local port="$1"

  if ! valid_port "$port"; then
    err "监听端口不合法：$port，范围必须是 1-65535"
    return 1
  fi

  if port_in_rules "$port"; then
    err "端口 $port 已存在于转发规则里"
    return 1
  fi

  if port_in_system "$port"; then
    err "端口 $port 已被系统进程占用"
    show_port_owner "$port"
    return 1
  fi

  return 0
}

backup_rules() {
  local backup="$BASE_DIR/rules.db.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$RULE_FILE" "$backup" 2>/dev/null || true
  chmod 600 "$backup" 2>/dev/null || true
  printf '%s' "$backup"
}

restore_rules() {
  local backup="${1:-}"
  if [[ -n "$backup" && -f "$backup" ]]; then
    cp -a "$backup" "$RULE_FILE"
    chmod 600 "$RULE_FILE" 2>/dev/null || true
  fi
}

print_rules() {
  echo -e "${CYAN}📋 当前端口转发规则：${NC}"
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    warn "暂无规则"
    return
  fi

  printf "%s\n" "序号  名称                  本地监听                  目标"
  printf "%s\n" "----  --------------------  ------------------------  ---------------------------"

  local i=1 name listen_port dest
  while IFS='|' read -r name listen_port dest; do
    [[ -z "${listen_port:-}" || -z "${dest:-}" ]] && continue
    printf "%-5s %-21s %-25s %s\n" "[$i]" "$name" "0.0.0.0:$listen_port" "$dest"
    i=$((i + 1))
  done < "$RULE_FILE"
}

parse_json_line() {
  local raw="$1"
  local name listen_port dest dest_type parsed host dport norm_dest

  if ! echo "$raw" | jq -e . >/dev/null 2>&1; then
    return 1
  fi

  name="$(echo "$raw" | jq -r '.name // empty')"
  listen_port="$(echo "$raw" | jq -r '.listen_port // empty')"

  dest_type="$(echo "$raw" | jq -r '.dest | type')"
  if [[ "$dest_type" == "array" ]]; then
    dest="$(echo "$raw" | jq -r '.dest[0] // empty')"
  elif [[ "$dest_type" == "string" ]]; then
    dest="$(echo "$raw" | jq -r '.dest // empty')"
  else
    dest=""
  fi

  name="$(trim "$name")"
  listen_port="$(trim "$listen_port")"
  dest="$(trim "$dest")"

  valid_name "$name" || return 2
  valid_port "$listen_port" || return 3
  listen_port="$(normalize_port "$listen_port")"

  parsed="$(parse_dest "$dest")" || return 4
  IFS='|' read -r host dport norm_dest <<< "$parsed"

  echo "$name|$listen_port|$norm_dest"
}

make_apply_script() {
  cat > "$APPLY_SCRIPT" <<EOF2
#!/usr/bin/env bash
set -euo pipefail

RULE_FILE="$RULE_FILE"
NFT_CONF="$NFT_CONF"
NFT_TABLE="$NFT_TABLE"
SYSCTL_CONF="$SYSCTL_CONF"

resolve_ipv4() {
  getent ahostsv4 "\$1" | awk '{print \$1; exit}'
}

valid_port() {
  local p="\${1:-}"
  [[ "\$p" =~ ^[0-9]{1,5}\$ ]] && (( 10#\$p >= 1 && 10#\$p <= 65535 ))
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
printf 'net.ipv4.ip_forward=1\n' > "\$SYSCTL_CONF" 2>/dev/null || true

TMP_CONF="\$(mktemp)"
OLD_CONF="\$(mktemp)"
HAD_OLD=0
cleanup() {
  rm -f "\$TMP_CONF" "\$OLD_CONF"
}
trap cleanup EXIT

if nft list table ip "\$NFT_TABLE" > "\$OLD_CONF" 2>/dev/null; then
  HAD_OLD=1
fi

{
  echo "add table ip \$NFT_TABLE"
  echo "add chain ip \$NFT_TABLE prerouting { type nat hook prerouting priority dstnat; policy accept; }"
  echo "add chain ip \$NFT_TABLE postrouting { type nat hook postrouting priority srcnat; policy accept; }"

  if [[ -s "\$RULE_FILE" ]]; then
    while IFS='|' read -r name listen_port dest; do
      [[ -z "\${listen_port:-}" || -z "\${dest:-}" ]] && continue

      host="\${dest%:*}"
      dport="\${dest##*:}"

      if ! valid_port "\$listen_port" || ! valid_port "\$dport"; then
        echo "# 跳过：\$name -> \$dest，端口不合法"
        continue
      fi

      ip="\$(resolve_ipv4 "\$host" || true)"
      if [[ -z "\$ip" ]]; then
        echo "# 跳过：\$name -> \$dest，解析失败"
        continue
      fi

      echo "add rule ip \$NFT_TABLE prerouting tcp dport \$listen_port dnat to \$ip:\$dport"
      echo "add rule ip \$NFT_TABLE prerouting udp dport \$listen_port dnat to \$ip:\$dport"
      echo "add rule ip \$NFT_TABLE postrouting ip daddr \$ip tcp dport \$dport masquerade"
      echo "add rule ip \$NFT_TABLE postrouting ip daddr \$ip udp dport \$dport masquerade"
      echo "# 已构建规则：\$name  0.0.0.0:\$listen_port -> \$ip:\$dport"
    done < "\$RULE_FILE"
  fi
} > "\$TMP_CONF"

nft -c -f "\$TMP_CONF"

if nft list table ip "\$NFT_TABLE" >/dev/null 2>&1; then
  nft delete table ip "\$NFT_TABLE"
fi

if ! nft -f "\$TMP_CONF"; then
  echo "应用 nftables 规则失败，正在尝试回滚旧规则..." >&2
  if [[ "\$HAD_OLD" = 1 ]]; then
    nft -f "\$OLD_CONF" || true
  fi
  exit 1
fi

install -m 600 "\$TMP_CONF" "\$NFT_CONF"
echo "✅ nftables 规则已应用"
EOF2

  chmod 700 "$APPLY_SCRIPT"
}

make_service() {
  cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=Pure Port Forward (nftables backend)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$APPLY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable pure-port-forward >/dev/null 2>&1 || true
}

apply_rules() {
  make_apply_script
  make_service

  if ! "$APPLY_SCRIPT"; then
    return 1
  fi

  systemctl restart pure-port-forward >/dev/null 2>&1 || true
  return 0
}

confirm_default_yes() {
  local prompt="$1"
  local ans
  read -rp "$prompt [Y/n]: " ans || return 1
  ans="$(trim "$ans")"
  [[ -z "$ans" || "$ans" =~ ^[Yy]$ || "$ans" =~ ^[Yy][Ee][Ss]$ ]]
}

ask_name() {
  local __var="$1"
  local value
  while true; do
    echo -ne "${BOLD}🏷️  名称${NC}${DIM}（1-40字，不能包含 |，回车取消）${NC}: "
    read -r value || return 1
    value="$(trim "$value")"

    if [[ -z "$value" ]]; then
      warn "已取消"
      return 1
    fi

    if valid_name "$value"; then
      printf -v "$__var" '%s' "$value"
      return 0
    fi

    err "名称不合法：不能为空，不能超过 40 字，不能包含 | 或控制字符"
  done
}

ask_listen_port() {
  local __var="$1"
  local value
  while true; do
    echo -ne "${BOLD}🎧 本地监听端口${NC}${DIM}（1-65535，不能被占用，回车取消）${NC}: "
    read -r value || return 1
    value="$(trim "$value")"

    if [[ -z "$value" ]]; then
      warn "已取消"
      return 1
    fi

    if valid_port "$value"; then
      value="$(normalize_port "$value")"
      if check_listen_port_available "$value"; then
        printf -v "$__var" '%s' "$value"
        return 0
      fi
    else
      err "端口不合法：请输入 1-65535 的数字"
    fi
  done
}

ask_dest() {
  local __var="$1"
  local value parsed host dport norm_dest ip code
  while true; do
    echo -ne "${BOLD}🎯 目标地址${NC}${DIM}（格式 host:port，只支持 IPv4/域名，回车取消）${NC}: "
    read -r value || return 1
    value="$(trim "$value")"

    if [[ -z "$value" ]]; then
      warn "已取消"
      return 1
    fi

    set +e
    parsed="$(parse_dest "$value")"
    code=$?
    set -e

    case "$code" in
      0)
        IFS='|' read -r host dport norm_dest <<< "$parsed"
        ip="$(resolve_ipv4 "$host" || true)"
        if [[ -z "$ip" ]]; then
          err "目标解析失败：$host"
          continue
        fi
        info "已解析：$host -> $ip"
        printf -v "$__var" '%s' "$norm_dest"
        return 0
        ;;
      2)
        err "不要带 http:// 或 https://，这里只填 host:port，例如：node1.example.com:443"
        ;;
      3)
        err "目标 host 不合法，只支持 IPv4 或域名，例如：1.2.3.4:443 / node.example.com:443"
        ;;
      4)
        err "目标端口不合法，范围必须是 1-65535"
        ;;
      *)
        err "目标格式错误，必须是 host:port，例如：1.2.3.4:443"
        ;;
    esac
  done
}

add_one() {
  header "➕ 添加单条端口转发"
  echo -e "${DIM}说明：本地监听端口会同时转发 TCP 和 UDP。${NC}"
  echo

  local name listen_port dest backup
  ask_name name || return
  ask_listen_port listen_port || return
  ask_dest dest || return

  echo
  line
  echo -e "${BOLD}请确认添加：${NC}"
  echo "名称：$name"
  echo "监听：0.0.0.0:$listen_port"
  echo "目标：$dest"
  line

  if ! confirm_default_yes "确认添加吗？"; then
    warn "已取消"
    return
  fi

  backup="$(backup_rules)"
  printf '%s|%s|%s\n' "$name" "$listen_port" "$dest" >> "$RULE_FILE"

  if ! apply_rules; then
    restore_rules "$backup"
    apply_rules >/dev/null 2>&1 || true
    err "添加失败，已回滚规则文件"
    return
  fi

  ok "添加成功：$name  0.0.0.0:$listen_port -> $dest"
}

import_many() {
  header "📥 快捷导入多条"
  echo "支持一行一个 JSON："
  echo -e "${DIM}{\"dest\":[\"node1.example.com:46379\"],\"listen_port\":22086,\"name\":\"测试\"}${NC}"
  echo -e "${DIM}{\"dest\":[\"198.51.100.1:38765\"],\"listen_port\":38765,\"name\":\"云端代理\"}${NC}"
  echo
  warn "粘贴完成后，单独输入 EOF 回车结束"
  echo

  local tmp_raw tmp_valid
  tmp_raw="$(mktemp)"
  tmp_valid="$(mktemp)"

  while IFS= read -r line_in; do
    [[ "$line_in" == "EOF" ]] && break
    [[ -z "$(trim "$line_in")" ]] && continue
    echo "$line_in" >> "$tmp_raw"
  done

  if [[ ! -s "$tmp_raw" ]]; then
    rm -f "$tmp_raw" "$tmp_valid"
    err "没有输入内容"
    return
  fi

  local added=0 skipped=0 raw parsed name listen_port dest host dport ip

  while IFS= read -r raw; do
    if ! parsed="$(parse_json_line "$raw")"; then
      err "跳过：格式/名称/端口/目标不合法：$raw"
      skipped=$((skipped + 1))
      continue
    fi

    IFS='|' read -r name listen_port dest <<< "$parsed"

    if port_in_rules "$listen_port" || port_in_file "$listen_port" "$tmp_valid"; then
      warn "跳过：监听端口重复：$listen_port"
      skipped=$((skipped + 1))
      continue
    fi

    if port_in_system "$listen_port"; then
      warn "跳过：端口已被系统占用：$listen_port"
      show_port_owner "$listen_port"
      skipped=$((skipped + 1))
      continue
    fi

    host="${dest%:*}"
    dport="${dest##*:}"
    ip="$(resolve_ipv4 "$host" || true)"
    if [[ -z "$ip" ]]; then
      err "跳过：目标解析失败：$dest"
      skipped=$((skipped + 1))
      continue
    fi

    printf '%s|%s|%s\n' "$name" "$listen_port" "$dest" >> "$tmp_valid"
    ok "预导入：$name  0.0.0.0:$listen_port -> $dest"
    added=$((added + 1))
  done < "$tmp_raw"

  rm -f "$tmp_raw"

  echo
  line
  echo -e "${BOLD}导入预览：成功 $added 条，跳过 $skipped 条${NC}"
  line

  if (( added == 0 )); then
    rm -f "$tmp_valid"
    warn "没有可导入的有效规则"
    return
  fi

  if ! confirm_default_yes "确认导入这 $added 条规则吗？"; then
    rm -f "$tmp_valid"
    warn "已取消"
    return
  fi

  local backup
  backup="$(backup_rules)"
  cat "$tmp_valid" >> "$RULE_FILE"
  rm -f "$tmp_valid"

  if ! apply_rules; then
    restore_rules "$backup"
    apply_rules >/dev/null 2>&1 || true
    err "导入失败，已回滚规则文件"
    return
  fi

  ok "导入完成：成功 $added 条，跳过 $skipped 条"
}

delete_one() {
  header "🗑️ 删除单条规则"
  print_rules
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    return
  fi

  local num total old tmp backup
  total="$(line_count)"

  read -rp "输入要删除的序号（回车取消）: " num
  num="$(trim "$num")"

  if [[ -z "$num" ]]; then
    warn "已取消"
    return
  fi

  if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > total )); then
    err "序号不存在：$num"
    return
  fi

  old="$(sed -n "${num}p" "$RULE_FILE")"
  warn "即将删除：$old"
  if ! confirm_default_yes "确认删除吗？"; then
    warn "已取消"
    return
  fi

  backup="$(backup_rules)"
  tmp="$(mktemp)"
  awk -v n="$num" 'NR != n' "$RULE_FILE" > "$tmp"
  mv "$tmp" "$RULE_FILE"
  chmod 600 "$RULE_FILE" 2>/dev/null || true

  if ! apply_rules; then
    restore_rules "$backup"
    apply_rules >/dev/null 2>&1 || true
    err "删除失败，已回滚规则文件"
    return
  fi

  ok "已删除：$old"
}

delete_many() {
  header "🧹 批量删除规则"
  print_rules
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    return
  fi

  echo "示例：1 3 5 或 1,3,5"
  local nums total n tmp backup
  read -rp "输入要删除的序号（回车取消）: " nums
  nums="$(trim "$(echo "$nums" | tr ',' ' ')")"

  if [[ -z "$nums" ]]; then
    warn "已取消"
    return
  fi

  total="$(line_count)"
  for n in $nums; do
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > total )); then
      err "序号不合法：$n"
      return
    fi
  done

  warn "即将删除序号：$nums"
  if ! confirm_default_yes "确认批量删除吗？"; then
    warn "已取消"
    return
  fi

  backup="$(backup_rules)"
  tmp="$(mktemp)"
  awk -v list="$nums" '
    BEGIN {
      split(list, arr, " ")
      for (i in arr) del[arr[i]] = 1
    }
    !(NR in del)
  ' "$RULE_FILE" > "$tmp"

  mv "$tmp" "$RULE_FILE"
  chmod 600 "$RULE_FILE" 2>/dev/null || true

  if ! apply_rules; then
    restore_rules "$backup"
    apply_rules >/dev/null 2>&1 || true
    err "批量删除失败，已回滚规则文件"
    return
  fi

  ok "批量删除完成"
}

delete_all() {
  header "🚨 删除全部规则"
  print_rules
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    return
  fi

  warn "这是危险操作，会清空所有端口转发规则。"
  local ok_text backup
  read -rp "确认删除全部规则？请输入 YES 确认: " ok_text

  if [[ "$ok_text" != "YES" ]]; then
    warn "已取消"
    return
  fi

  backup="$(backup_rules)"
  : > "$RULE_FILE"
  chmod 600 "$RULE_FILE" 2>/dev/null || true

  if ! apply_rules; then
    restore_rules "$backup"
    apply_rules >/dev/null 2>&1 || true
    err "清空失败，已回滚规则文件"
    return
  fi

  ok "已删除全部规则"
}

delete_menu() {
  while true; do
    header "🗑️ 删除管理"
    echo "1. 删除单条"
    echo "2. 删除多条"
    echo "3. 删除全部"
    echo "0. 返回上级"
    line
    read -rp "请选择: " choice

    case "$choice" in
      1) delete_one; pause ;;
      2) delete_many; pause ;;
      3) delete_all; pause ;;
      0) return ;;
      *) err "无效选择"; pause ;;
    esac
  done
}

export_rules() {
  header "📤 导出规则"

  if [[ ! -s "$RULE_FILE" ]]; then
    warn "暂无规则"
    return
  fi

  echo -e "${DIM}下面内容可直接用于“快捷导入多条”：${NC}"
  echo

  while IFS='|' read -r name listen_port dest; do
    [[ -z "${listen_port:-}" || -z "${dest:-}" ]] && continue
    jq -n --arg name "$name" --arg port "$listen_port" --arg dest "$dest" \
      '{dest: [$dest], listen_port: ($port|tonumber), name: $name}' -c
  done < "$RULE_FILE"
}

status_info() {
  header "📊 服务状态"
  echo -e "${CYAN}systemd 服务：${NC}"
  systemctl status pure-port-forward --no-pager -l || true

  echo
  print_rules

  echo
  echo -e "${CYAN}🔥 nftables NAT 规则（$NFT_TABLE）：${NC}"
  nft list table ip "$NFT_TABLE" 2>/dev/null || warn "未检测到规则表"

  echo
  echo -e "${CYAN}🧩 IPv4 转发：${NC}"
  sysctl net.ipv4.ip_forward 2>/dev/null || true
}

uninstall_all() {
  header "🚨 卸载 Pure Port Forward"
  warn "这是危险操作，会删除服务、规则、配置目录和本脚本生成的 nftables 表。"
  echo "不会删除 nftables 软件包，也不会动其他 nftables 表。"
  echo

  local ok_text
  read -rp "确认彻底卸载？请输入 YES 确认: " ok_text

  if [[ "$ok_text" != "YES" ]]; then
    warn "已取消"
    return
  fi

  systemctl disable --now pure-port-forward >/dev/null 2>&1 || true
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true

  rm -f "$SERVICE_FILE"
  rm -rf "$BASE_DIR"
  rm -f "$SYSCTL_CONF"

  systemctl daemon-reload

  ok "卸载完成，系统环境已清理。"
}

menu() {
  while true; do
    header "🚀 纯端口转发管理"
    echo -e "${BOLD}1.${NC} 📋 查看规则"
    echo -e "${BOLD}2.${NC} ➕ 添加单条"
    echo -e "${BOLD}3.${NC} 📥 快捷导入多条"
    echo -e "${BOLD}4.${NC} 🗑️ 删除管理"
    echo -e "${BOLD}5.${NC} 🔄 重新应用规则"
    echo -e "${BOLD}6.${NC} 📤 导出规则"
    echo -e "${BOLD}7.${NC} 📊 查看状态"
    echo -e "${BOLD}8.${NC} 🚨 卸载"
    echo -e "${BOLD}0.${NC} 👋 退出"
    line
    read -rp "请选择: " choice

    case "$choice" in
      1) header "📋 查看规则"; print_rules; pause ;;
      2) add_one; pause ;;
      3) import_many; pause ;;
      4) delete_menu ;;
      5)
        header "🔄 重新应用规则"
        if apply_rules; then
          ok "已重新应用规则"
        else
          err "规则应用失败，请查看上面的错误"
        fi
        pause
        ;;
      6) export_rules; pause ;;
      7) status_info; pause ;;
      8) uninstall_all; pause ;;
      0) exit 0 ;;
      *) err "无效选择"; pause ;;
    esac
  done
}

need_root
init_storage
install_deps
make_apply_script
make_service
apply_rules || warn "首次应用规则失败，请进入菜单查看状态或检查 nftables"
menu
