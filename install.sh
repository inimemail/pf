#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/pure-port-forward"
RULE_FILE="$BASE_DIR/rules.db"
APPLY_SCRIPT="$BASE_DIR/apply.sh"
SERVICE_FILE="/etc/systemd/system/pure-port-forward.service"
NFT_CONF="$BASE_DIR/rules.nft"

NFT_TABLE="ppf_nat"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m"

mkdir -p "$BASE_DIR"
touch "$RULE_FILE"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 运行${NC}"
    exit 1
  fi
}

pause() {
  echo
  read -rp "按回车继续..."
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

  echo -e "${YELLOW}检测到缺少依赖：${missing[*]}${NC}"

  local pm
  pm="$(detect_pkg_manager)"

  case "$pm" in
    apt)
      echo -e "${CYAN}正在自动安装依赖...${NC}"
      apt-get update -y
      apt-get install -y nftables iproute2 procps systemd jq
      ;;
    dnf)
      echo -e "${CYAN}正在自动安装依赖...${NC}"
      dnf install -y nftables iproute procps-ng systemd jq
      ;;
    yum)
      echo -e "${CYAN}正在自动安装依赖...${NC}"
      yum install -y nftables iproute procps-ng systemd jq
      ;;
    *)
      echo -e "${RED}无法识别包管理器，请手动安装：nftables iproute2/procps/systemd jq${NC}"
      exit 1
      ;;
  esac

  systemctl enable --now nftables >/dev/null 2>&1 || true

  local still_missing=0
  for cmd in nft sysctl systemctl getent ss awk sed grep jq; do
    if ! has_cmd "$cmd"; then
      echo -e "${RED}仍然缺少命令：$cmd${NC}"
      still_missing=1
    fi
  done

  if [[ "$still_missing" = 1 ]]; then
    exit 1
  fi
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
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

port_in_system() {
  local port="$1"

  if ss -lntup 2>/dev/null | awk -v p=":$port" '
    NR > 1 {
      if ($5 ~ p "$") found=1
      if ($5 ~ p ",") found=1
    }
    END { exit !found }
  '; then
    return 0
  fi

  return 1
}

port_usable_or_rule_owned() {
  local port="$1"

  if port_in_rules "$port"; then
    return 1
  fi

  if port_in_system "$port"; then
    return 1
  fi

  return 0
}

check_listen_port_available() {
  local port="$1"

  if ! valid_port "$port"; then
    echo -e "${RED}监听端口不合法：$port${NC}"
    return 1
  fi

  if port_in_rules "$port"; then
    echo -e "${RED}端口 $port 已存在于转发规则里${NC}"
    return 1
  fi

  if port_in_system "$port"; then
    echo -e "${RED}端口 $port 已被系统进程占用：${NC}"
    ss -lntup 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
    return 1
  fi

  return 0
}

print_rules() {
  echo -e "${CYAN}当前端口转发规则：${NC}"
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    echo -e "${YELLOW}暂无规则${NC}"
    return
  fi

  local i=1
  while IFS='|' read -r name listen_port dest; do
    [[ -z "${listen_port:-}" || -z "${dest:-}" ]] && continue
    printf "%-4s %-18s 0.0.0.0:%-8s -> %s\n" "[$i]" "$name" "$listen_port" "$dest"
    i=$((i + 1))
  done < "$RULE_FILE"
}

parse_json_line() {
  local raw="$1"
  local name listen_port dest dest_type

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

  [[ -n "$name" && -n "$listen_port" && -n "$dest" ]] || return 1
  
  echo "$name|$listen_port|$dest"
}

make_apply_script() {
  cat > "$APPLY_SCRIPT" <<EOF2
#!/usr/bin/env bash
set -euo pipefail

RULE_FILE="$RULE_FILE"
NFT_CONF="$NFT_CONF"
NFT_TABLE="$NFT_TABLE"

resolve_ipv4() {
  getent ahostsv4 "\$1" | awk '{print \$1; exit}'
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

echo "add table ip \$NFT_TABLE" > "\$NFT_CONF"
echo "flush table ip \$NFT_TABLE" >> "\$NFT_CONF"
echo "add chain ip \$NFT_TABLE prerouting { type nat hook prerouting priority dstnat; policy accept; }" >> "\$NFT_CONF"
echo "add chain ip \$NFT_TABLE postrouting { type nat hook postrouting priority srcnat; policy accept; }" >> "\$NFT_CONF"

if [[ -s "\$RULE_FILE" ]]; then
  while IFS='|' read -r name listen_port dest; do
    [[ -z "\${listen_port:-}" || -z "\${dest:-}" ]] && continue

    host="\${dest%:*}"
    dport="\${dest##*:}"
    ip="\$(resolve_ipv4 "\$host" || true)"

    if [[ -z "\$ip" ]]; then
      echo "跳过：\$name -> \$dest，解析失败"
      continue
    fi

    echo "add rule ip \$NFT_TABLE prerouting tcp dport \$listen_port dnat to \$ip:\$dport" >> "\$NFT_CONF"
    echo "add rule ip \$NFT_TABLE prerouting udp dport \$listen_port dnat to \$ip:\$dport" >> "\$NFT_CONF"
    
    echo "add rule ip \$NFT_TABLE postrouting ip daddr \$ip tcp dport \$dport masquerade" >> "\$NFT_CONF"
    echo "add rule ip \$NFT_TABLE postrouting ip daddr \$ip udp dport \$dport masquerade" >> "\$NFT_CONF"

    echo "已构建规则：\$name  0.0.0.0:\$listen_port -> \$ip:\$dport"
  done < "\$RULE_FILE"
fi

nft -f "\$NFT_CONF"
EOF2

  chmod +x "$APPLY_SCRIPT"
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

  systemctl daemon-reload
  systemctl enable pure-port-forward >/dev/null 2>&1 || true
}

apply_rules() {
  make_apply_script
  make_service
  "$APPLY_SCRIPT"
  systemctl restart pure-port-forward >/dev/null 2>&1 || true
}

add_one() {
  clear
  echo -e "${CYAN}添加单条端口转发${NC}"
  echo

  read -rp "名称: " name
  read -rp "本地监听端口: " listen_port
  read -rp "目标 host:port: " dest

  if [[ -z "$name" || -z "$listen_port" || -z "$dest" ]]; then
    echo -e "${RED}名称、监听端口、目标不能为空${NC}"
    return
  fi

  check_listen_port_available "$listen_port" || return

  if [[ "$dest" != *:* ]]; then
    echo -e "${RED}目标格式必须是 host:port${NC}"
    return
  fi

  local host dport ip
  host="${dest%:*}"
  dport="${dest##*:}"

  if ! valid_port "$dport"; then
    echo -e "${RED}目标端口不合法：$dport${NC}"
    return
  fi

  ip="$(resolve_ipv4 "$host" || true)"
  if [[ -z "$ip" ]]; then
    echo -e "${RED}目标解析失败：$host${NC}"
    return
  fi

  echo "$name|$listen_port|$dest" >> "$RULE_FILE"
  apply_rules

  echo -e "${GREEN}添加成功：$name  0.0.0.0:$listen_port -> $dest${NC}"
}

import_many() {
  clear
  echo -e "${CYAN}快捷导入多条${NC}"
  echo
  # 【深度修改】使用标准的 RFC 测试地址，彻底阻断您的真实数据泄露风险
  echo "支持一行一个："
  echo '{"dest":["node1.example.com:46379"],"listen_port":22086,"name":"测试"}'
  echo '{"dest":["198.51.100.1:38765"],"listen_port":38765,"name":"云端代理"}'
  echo
  echo -e "${YELLOW}粘贴完成后，单独输入 EOF 回车结束${NC}"
  echo

  local tmp
  tmp="$(mktemp)"

  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    [[ -z "$line" ]] && continue
    echo "$line" >> "$tmp"
  done

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo -e "${RED}没有输入内容${NC}"
    return
  fi

  local added=0
  local skipped=0

  while IFS= read -r raw; do
    local parsed name listen_port dest host dport ip

    if ! parsed="$(parse_json_line "$raw")"; then
      echo -e "${RED}跳过，格式错误：$raw${NC}"
      skipped=$((skipped + 1))
      continue
    fi

    IFS='|' read -r name listen_port dest <<< "$parsed"

    if ! valid_port "$listen_port"; then
      echo -e "${RED}跳过，监听端口不合法：$listen_port${NC}"
      skipped=$((skipped + 1))
      continue
    fi

    if port_in_rules "$listen_port"; then
      echo -e "${YELLOW}跳过，端口已存在于转发规则：$listen_port${NC}"
      skipped=$((skipped + 1))
      continue
    fi

    if port_in_system "$listen_port"; then
      echo -e "${YELLOW}跳过，端口已被系统占用：$listen_port${NC}"
      ss -lntup 2>/dev/null | grep -E "[:.]${listen_port}[[:space:]]" || true
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$dest" != *:* ]]; then
      echo -e "${RED}跳过，目标格式错误：$dest${NC}"
      skipped=$((skipped + 1))
      continue
    fi

    host="${dest%:*}"
    dport="${dest##*:}"

    if ! valid_port "$dport"; then
      echo -e "${RED}跳过，目标端口不合法：$dest${NC}"
      skipped=$((skipped + 1))
      continue
    fi

    ip="$(resolve_ipv4 "$host" || true)"
    if [[ -z "$ip" ]]; then
      echo -e "${RED}跳过，目标解析失败：$dest${NC}"
      skipped=$((skipped + 1))
      continue
    fi

    echo "$name|$listen_port|$dest" >> "$RULE_FILE"
    echo -e "${GREEN}导入：$name  0.0.0.0:$listen_port -> $dest${NC}"
    added=$((added + 1))
  done < "$tmp"

  rm -f "$tmp"

  apply_rules
  echo
  echo -e "${GREEN}导入完成：成功 $added 条，跳过 $skipped 条${NC}"
}

delete_one() {
  clear
  print_rules
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    return
  fi

  read -rp "输入要删除的序号: " num

  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}请输入数字序号${NC}"
    return
  fi

  local total
  total="$(line_count)"

  if (( num < 1 || num > total )); then
    echo -e "${RED}序号不存在${NC}"
    return
  fi

  local old
  old="$(sed -n "${num}p" "$RULE_FILE")"

  local tmp
  tmp="$(mktemp)"
  awk -v n="$num" 'NR != n' "$RULE_FILE" > "$tmp"
  mv "$tmp" "$RULE_FILE"

  apply_rules
  echo -e "${GREEN}已删除：$old${NC}"
}

delete_many() {
  clear
  print_rules
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    return
  fi

  echo "示例：1 3 5 或 1,3,5"
  read -rp "输入要删除的序号: " nums

  nums="$(echo "$nums" | tr ',' ' ')"

  if [[ -z "$nums" ]]; then
    echo -e "${RED}未输入序号${NC}"
    return
  fi

  local total
  total="$(line_count)"

  for n in $nums; do
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > total )); then
      echo -e "${RED}序号不合法：$n${NC}"
      return
    fi
  done

  local tmp
  tmp="$(mktemp)"

  awk -v list="$nums" '
    BEGIN {
      split(list, arr, " ")
      for (i in arr) del[arr[i]] = 1
    }
    !(NR in del)
  ' "$RULE_FILE" > "$tmp"

  mv "$tmp" "$RULE_FILE"

  apply_rules
  echo -e "${GREEN}批量删除完成${NC}"
}

delete_all() {
  clear
  print_rules
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    return
  fi

  read -rp "确认删除全部规则？输入 YES 确认: " ok

  if [[ "$ok" != "YES" ]]; then
    echo -e "${YELLOW}已取消${NC}"
    return
  fi

  : > "$RULE_FILE"
  apply_rules
  echo -e "${GREEN}已删除全部规则${NC}"
}

delete_menu() {
  while true; do
    clear
    echo -e "${CYAN}========== 删除管理 ==========${NC}"
    echo "1. 删除单条"
    echo "2. 删除多条"
    echo "3. 删除全部"
    echo "0. 返回上级"
    echo -e "${CYAN}==============================${NC}"
    read -rp "请选择: " choice

    case "$choice" in
      1) delete_one; pause ;;
      2) delete_many; pause ;;
      3) delete_all; pause ;;
      0) return ;;
      *) echo -e "${RED}无效选择${NC}"; pause ;;
    esac
  done
}

export_rules() {
  clear
  echo -e "${CYAN}导出为快捷导入格式：${NC}"
  echo

  if [[ ! -s "$RULE_FILE" ]]; then
    echo -e "${YELLOW}暂无规则${NC}"
    return
  fi

  while IFS='|' read -r name listen_port dest; do
    [[ -z "${listen_port:-}" || -z "${dest:-}" ]] && continue
    jq -n --arg name "$name" --arg port "$listen_port" --arg dest "$dest" \
      '{dest: [$dest], listen_port: ($port|tonumber), name: $name}' -c
  done < "$RULE_FILE"
}

status_info() {
  clear
  echo -e "${CYAN}服务状态：${NC}"
  systemctl status pure-port-forward --no-pager -l || true

  echo
  echo -e "${CYAN}当前规则：${NC}"
  print_rules

  echo
  echo -e "${CYAN}nftables 原生 NAT 规则 ($NFT_TABLE 表)：${NC}"
  nft list table ip "$NFT_TABLE" 2>/dev/null || echo -e "${YELLOW}未检测到规则表${NC}"
}

uninstall_all() {
  clear
  read -rp "确认彻底卸载并删除所有配置？输入 YES 确认: " ok

  if [[ "$ok" != "YES" ]]; then
    echo -e "${YELLOW}已取消${NC}"
    return
  fi

  systemctl disable --now pure-port-forward >/dev/null 2>&1 || true

  nft delete table ip "$NFT_TABLE" 2>/dev/null || true

  rm -f "$SERVICE_FILE"
  rm -rf "$BASE_DIR"

  systemctl daemon-reload

  echo -e "${GREEN}卸载完成，系统环境已洁净如初。${NC}"
}

menu() {
  while true; do
    clear
    echo -e "${CYAN}========== 纯端口转发管理 ==========${NC}"
    echo "1. 查看规则"
    echo "2. 添加单条"
    echo "3. 快捷导入多条"
    echo "4. 删除管理"
    echo "5. 重新应用规则"
    echo "6. 导出规则"
    echo "7. 查看状态"
    echo "8. 卸载"
    echo "0. 退出"
    echo -e "${CYAN}====================================${NC}"
    read -rp "请选择: " choice

    case "$choice" in
      1) clear; print_rules; pause ;;
      2) add_one; pause ;;
      3) import_many; pause ;;
      4) delete_menu ;;
      5) apply_rules; echo -e "${GREEN}已重新应用原子级规则${NC}"; pause ;;
      6) export_rules; pause ;;
      7) status_info; pause ;;
      8) uninstall_all; pause ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选择${NC}"; pause ;;
    esac
  done
}

need_root
install_deps
make_apply_script
make_service
apply_rules
menu
