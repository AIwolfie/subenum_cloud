#!/bin/bash

# ============================================
# Telegram Subdomain Bot (waits for file uploads)
# Commands:
#   /subenum -h
#   /subenum example.com
#   /subenum target.txt          -> bot waits for 'target.txt' upload
#   /httpx subdomains.txt        -> bot waits for 'subdomains.txt' upload
# ============================================

BOT_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
CHAT_ID="YOUR_TELEGRAM_CHAT_ID"        # e.g. -123456789 for a group
OFFSET=0

BASE_DIR="$HOME/subdomains"
UPLOADS_DIR="$BASE_DIR/uploads"
WAIT_DIR="$BASE_DIR/.wait"
mkdir -p "$BASE_DIR" "$UPLOADS_DIR" "$WAIT_DIR"

# ------------- Utilities -------------

send_msg() {
  local MSG="$1"
  for i in {1..3}; do
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
      -d chat_id="$CHAT_ID" \
      -d text="$MSG" >/dev/null && return 0
    sleep 2
  done
  echo "[!] Failed to send Telegram message: $MSG"
}

send_file() {
  local FILE="$1"
  if [[ ! -s "$FILE" ]]; then
    send_msg "⚠️ File '$FILE' is empty or missing, skipping upload."
    return
  fi
  for i in {1..3}; do
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
      -F chat_id="$CHAT_ID" \
      -F document=@"$FILE" >/dev/null && return 0
    sleep 2
  done
  echo "[!] Failed to upload file to Telegram: $FILE"
}

help_menu() {
  cat <<'EOF'
📘 Subdomain Bot Help

Usage:
/subenum <domain>        Run enumeration for a single domain
/subenum <file.txt>      Bot waits for that file upload, then runs enum for all domains in it
/httpx <file.txt>        Bot waits for that file upload, then runs httpx-toolkit only
/subenum -h              Show this help menu

Enum tools:
- subfinder (all, recursive)
- assetfinder
- amass (passive)
- alterx + dnsx
- crt.sh API
- anubis API
- github-subdomains

Results (per domain):
~/subdomains/<domain>/
- subfinder.txt, assetfinder.txt, amass.txt, alterx.txt, crtsh.txt, anubis.txt, github.txt
- final.txt (unique)
📦 A ZIP with all files is sent to Telegram with counts + total time.

Httpx mode:
/httpx subdomains.txt
- runs:  cat subdomains.txt | httpx-toolkit -ports 80,443,8080,8000,8888 -threads 200 > subdomains_alive.txt
- sends counts, time, and subdomains_alive.txt
EOF
}

# ------------- Waiting state (per chat) -------------

# State file format:
#   action=subenum|httpx
#   expected=target.txt
STATE_FILE="$WAIT_DIR/${CHAT_ID}.state"

set_wait_state() {
  local ACTION="$1"; local EXPECTED="$2"
  printf "action=%s\nexpected=%s\n" "$ACTION" "$EXPECTED" > "$STATE_FILE"
}

clear_wait_state() {
  rm -f "$STATE_FILE"
}

have_wait_state() {
  [[ -f "$STATE_FILE" ]]
}

get_state_val() {
  local KEY="$1"
  grep -E "^${KEY}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2-
}

# ------------- Helpers -------------

run_tool() {
  local CMD="$1"
  local OUT="$2"
  local TOOL
  TOOL="$(echo "$CMD" | awk '{print $1}')"

  if ! command -v "$TOOL" >/dev/null 2>&1; then
    echo "[!] $TOOL not installed" > "$OUT"
    return 1
  fi

  eval "$CMD" 2>/dev/null | sort -u > "$OUT"
  [[ ! -s "$OUT" ]] && echo "[!] No results from $TOOL" > "$OUT"
}

count_lines() {
  local FILE="$1"
  [[ -f "$FILE" ]] && grep -v '^\[!\]' "$FILE" | wc -l || echo 0
}

# ------------- Enum pipeline -------------

run_enum() {
  local INPUT="$1"
  local DOMAINS

  if [[ -f "$INPUT" ]]; then
    DOMAINS="$(tr -d '\r' < "$INPUT" | sed '/^$/d')"
  else
    DOMAINS="$INPUT"
  fi

  for domain in $DOMAINS; do
    local START END DURATION OUT_DIR ZIP
    START=$(date +%s)
    OUT_DIR="$BASE_DIR/$domain"
    mkdir -p "$OUT_DIR"
    send_msg "🚀 Starting subdomain enum for $domain"

    run_tool "subfinder -d $domain -all -recursive -silent" "$OUT_DIR/subfinder.txt"
    run_tool "assetfinder -subs-only $domain" "$OUT_DIR/assetfinder.txt"
    run_tool "amass enum -d $domain -passive -silent" "$OUT_DIR/amass.txt"
    run_tool "alterx -pp word=/usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt -d $domain | dnsx -silent" "$OUT_DIR/alterx.txt"

    # crt.sh
    if command -v jq >/dev/null 2>&1; then
      curl -s "https://crt.sh/?q=%25.$domain&output=json" \
        | jq -r '.[].name_value' 2>/dev/null \
        | sed 's/\*\.//g' | sort -u > "$OUT_DIR/crtsh.txt"
    else
      curl -s "https://crt.sh/?q=%25.$domain" \
        | grep -Eo "[a-zA-Z0-9._-]+\.$domain" | sort -u > "$OUT_DIR/crtsh.txt"
    fi

    # anubis
    if command -v jq >/dev/null 2>&1; then
      curl -s "https://jldc.me/anubis/subdomains/$domain" \
        | jq -r '.[]' 2>/dev/null | sort -u > "$OUT_DIR/anubis.txt"
    else
      curl -s "https://jldc.me/anubis/subdomains/$domain" \
        | grep -Eo "[a-zA-Z0-9._-]+\.$domain" | sort -u > "$OUT_DIR/anubis.txt"
    fi

    run_tool "github-subdomains -d $domain | grep -Eo \"([a-zA-Z0-9_-]+\\.)+$domain\"" "$OUT_DIR/github.txt"

    # Merge safely
    find "$OUT_DIR" -type f -name "*.txt" -exec cat {} + 2>/dev/null \
      | grep -v '^\[!\]' | sort -u > "$OUT_DIR/final.txt"

    local SUBF ASSET AMASS ALTERX CRT ANUBIS GITHUB FINAL
    SUBF=$(count_lines "$OUT_DIR/subfinder.txt")
    ASSET=$(count_lines "$OUT_DIR/assetfinder.txt")
    AMASS=$(count_lines "$OUT_DIR/amass.txt")
    ALTERX=$(count_lines "$OUT_DIR/alterx.txt")
    CRT=$(count_lines "$OUT_DIR/crtsh.txt")
    ANUBIS=$(count_lines "$OUT_DIR/anubis.txt")
    GITHUB=$(count_lines "$OUT_DIR/github.txt")
    FINAL=$(count_lines "$OUT_DIR/final.txt")

    END=$(date +%s)
    DURATION=$((END - START))

    ZIP="$BASE_DIR/${domain}_subdomains.zip"
    if ! zip -j -q "$ZIP" "$OUT_DIR"/*.txt; then
      send_msg "⚠️ Failed to create ZIP for $domain"
      continue
    fi

    local REPORT
    REPORT=$(cat <<EOR
📊 Subdomain Report for $domain

🔹 subfinder: $SUBF
🔹 assetfinder: $ASSET
🔹 amass: $AMASS
🔹 alterx: $ALTERX
🔹 crt.sh: $CRT
🔹 anubis: $ANUBIS
🔹 github: $GITHUB

📦 Final unique subdomains: $FINAL
⏱️ Time taken: ${DURATION}s
EOR
)
    send_msg "$REPORT"
    send_file "$ZIP"
  done
}

# ------------- Httpx-only pipeline -------------

run_httpx() {
  local INPUT="$1"
  if [[ ! -f "$INPUT" ]]; then
    send_msg "❌ File '$INPUT' not found on server."
    return
  fi

  if ! command -v httpx-toolkit >/dev/null 2>&1; then
    send_msg "❌ httpx-toolkit not installed."
    return
  fi

  local START END DURATION TOTAL ALIVE OUT_FILE
  START=$(date +%s)
  TOTAL=$(wc -l < "$INPUT" | tr -d ' ')
  send_msg "🌐 Running httpx-toolkit on $TOTAL subdomains from $(basename "$INPUT") ..."

  OUT_FILE="$(dirname "$INPUT")/subdomains_alive.txt"

  # User-specified exact command:
  # cat subdomain.txt | httpx-toolkit -ports 80,443,8080,8000,8888 -threads 200 > subdomains_alive.txt
  cat "$INPUT" | httpx-toolkit -ports 80,443,8080,8000,8888 -threads 200 > "$OUT_FILE"

  ALIVE=$(wc -l < "$OUT_FILE" | tr -d ' ')
  END=$(date +%s)
  DURATION=$((END - START))

  local REPORT
  REPORT=$(cat <<EOR
🌐 Httpx Scan Complete

📥 Input subdomains: $TOTAL
✅ Alive subdomains: $ALIVE
⏱️ Time taken: ${DURATION}s
📄 Output file: subdomains_alive.txt
EOR
)
  send_msg "$REPORT"
  send_file "$OUT_FILE"
}

# ------------- Telegram file download -------------

download_document() {
  local FILE_ID="$1"
  local FILE_NAME="$2"
  local DEST_PATH="$UPLOADS_DIR/$FILE_NAME"

  # Get file path from Telegram
  local FILE_INFO FILE_PATH
  FILE_INFO=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getFile?file_id=$FILE_ID")
  FILE_PATH=$(echo "$FILE_INFO" | jq -r '.result.file_path // empty')

  if [[ -z "$FILE_PATH" || "$FILE_PATH" == "null" ]]; then
    send_msg "⚠️ Could not resolve file path for '$FILE_NAME'."
    return 1
  fi

  # Download actual file
  curl -s -o "$DEST_PATH" "https://api.telegram.org/file/bot$BOT_TOKEN/$FILE_PATH" || return 1
  echo "$DEST_PATH"
  return 0
}

# ------------- Main listener -------------

send_msg "🤖 Subdomain Bot is live. Send /subenum -h for help."

while true; do
  UPDATES=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$OFFSET")
  COUNT=$(echo "$UPDATES" | jq '.result | length')
  if (( COUNT > 0 )); then
    for i in $(seq 0 $((COUNT-1))); do
      UPDATE=$(echo "$UPDATES" | jq ".result[$i]")
      UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
      OFFSET=$((UPDATE_ID + 1))

      FROM_CHAT=$(echo "$UPDATE" | jq -r '.message.chat.id // empty')
      # Only react to our configured chat
      if [[ -n "$FROM_CHAT" && "$FROM_CHAT" != "$CHAT_ID" ]]; then
        continue
      fi

      TEXT=$(echo "$UPDATE" | jq -r '.message.text // .message.caption // empty')
      DOC_ID=$(echo "$UPDATE" | jq -r '.message.document.file_id // empty')
      DOC_NAME=$(echo "$UPDATE" | jq -r '.message.document.file_name // empty')

      # Handle commands
      if [[ -n "$TEXT" ]]; then
        if [[ "$TEXT" == "/subenum -h" ]]; then
          send_msg "$(help_menu)"

        elif [[ "$TEXT" == /subenum* ]]; then
          # Either /subenum <domain> OR /subenum <file.txt>
          read -r _cmd arg <<<"$TEXT"
          if [[ -z "$arg" ]]; then
            send_msg "❌ Usage:\n/subenum <domain>\n/subenum <file.txt>"
          elif [[ "$arg" == *.txt ]]; then
            # Expect a file upload next
            set_wait_state "subenum" "$arg"
            send_msg "📥 Send the file '$arg' now. I will start enumeration as soon as I receive it."
          else
            # Single domain mode
            run_enum "$arg"
          fi

        elif [[ "$TEXT" == /httpx* ]]; then
          # /httpx <file.txt>
          read -r _cmd arg <<<"$TEXT"
          if [[ -z "$arg" || "$arg" != *.txt ]]; then
            send_msg "❌ Usage: /httpx <file.txt>"
          else
            set_wait_state "httpx" "$arg"
            send_msg "📥 Send the file '$arg' now. I will start httpx as soon as I receive it."
          fi
        fi
      fi

      # Handle incoming document (file upload)
      if [[ -n "$DOC_ID" && -n "$DOC_NAME" ]]; then
        if have_wait_state; then
          ACTION=$(get_state_val "action")
          EXPECTED=$(get_state_val "expected")

          if [[ -n "$EXPECTED" && "$DOC_NAME" != "$EXPECTED" ]]; then
            send_msg "⚠️ Received '$DOC_NAME' but I'm waiting for '$EXPECTED'. Please resend the correct file."
            continue
          fi

          LOCAL_PATH=$(download_document "$DOC_ID" "$DOC_NAME") || {
            send_msg "❌ Failed to download '$DOC_NAME'. Try again."
            continue
          }

          SIZE=$(stat -c%s "$LOCAL_PATH" 2>/dev/null || echo 0)
          send_msg "✅ Received '$DOC_NAME' (${SIZE} bytes). Starting $ACTION ..."

          # Clear state before running job (so we can accept new commands while running)
          clear_wait_state

          if [[ "$ACTION" == "subenum" ]]; then
            run_enum "$LOCAL_PATH"
          elif [[ "$ACTION" == "httpx" ]]; then
            run_httpx "$LOCAL_PATH"
          else
            send_msg "⚠️ Unknown pending action '$ACTION'."
          fi
        else
          # No waiting state; just save the file (optional behavior)
          LOCAL_PATH=$(download_document "$DOC_ID" "$DOC_NAME") || true
          [[ -n "$LOCAL_PATH" ]] && send_msg "📎 Saved file '$DOC_NAME' to server."
        fi
      fi

    done
  fi
  sleep 5
done
