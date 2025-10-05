#!/bin/bash

# Clear any stale state files on startup
if [[ -f "$STATE_FILE" || -f "$PID_FILE" ]]; then
  log "Found stale state or PID file, cleaning up..."
  rm -f "$STATE_FILE" "$PID_FILE" 2>/dev/null
  log "Stale state cleaned up."
fi

# Trap to clean up temporary files on exit or interruption
# trap 'rm -f tmpl_chunk_* nuclei_result_part_* "$STATE_FILE" "$PID_FILE" "$BASE_DIR/recon_results.html" 2>/dev/null; log "Script terminated, cleaned up temporary files."; exit' SIGINT SIGTERM EXIT
trap '
  log "Received SIGINT or SIGTERM, cleaning up..."
  rm -f tmpl_chunk_* nuclei_result_part_* "$STATE_FILE" "$PID_FILE" "$BASE_DIR/recon_results.html" 2>/dev/null
  if [[ -f "$STATE_FILE" || -f "$PID_FILE" ]]; then
    log "Warning: Failed to clean up some temporary files"
  else
    log "Successfully cleaned up temporary files"
  fi
  log "Script terminated."
  exit
' SIGINT SIGTERM EXIT

# Source configuration
CONFIG_FILE="$HOME/tele_auto/reconx/reconx.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
  PARALLEL_JOBS=$(echo -n "$PARALLEL_JOBS" | tr -d '\r\n\t ')
  if [[ -z "$PARALLEL_JOBS" || ! "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "[!] PARALLEL_JOBS is unset or invalid in $CONFIG_FILE, defaulting to 4" >&2
    export PARALLEL_JOBS=4
  fi
else
  echo "[!] Configuration file $CONFIG_FILE not found" >&2
  exit 1
fi

# Initialize directories and files
mkdir -p "$BASE_DIR" "$UPLOADS_DIR" "$WAIT_DIR"
LOG_FILE="$BASE_DIR/reconx.log"
PID_FILE="$WAIT_DIR/${CHAT_ID}.pid"
STATE_FILE="$WAIT_DIR/${CHAT_ID}.state"

# Default parallel jobs if not set in config
: "${PARALLEL_JOBS:=4}"

# ------------- Utilities -------------

log() {
  local MSG="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $MSG" >> "$LOG_FILE"
  echo "$MSG" >&2
}

send_msg() {
  local MSG="$1"
  local REPLY_MARKUP="$2"

  # Sanitize BOT_TOKEN and CHAT_ID
  BOT_TOKEN=$(echo -n "$BOT_TOKEN" | tr -d '\r\n\t ')
  CHAT_ID=$(echo -n "$CHAT_ID" | tr -d '\r\n\t ')

  # Validate inputs
  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    log "[!] BOT_TOKEN or CHAT_ID is not set"
    return 1
  fi

  log "DEBUG: BOT_TOKEN=${BOT_TOKEN}"
  log "DEBUG: CHAT_ID=${CHAT_ID}"
  log "DEBUG: Sending Telegram message: $MSG"

  for i in {1..3}; do
    local CURL_OUTPUT
    if [ -n "$REPLY_MARKUP" ]; then
      CURL_OUTPUT=$(curl -sS --max-time 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${MSG}" \
        --data-urlencode "reply_markup=${REPLY_MARKUP}" 2>&1)
    else
      CURL_OUTPUT=$(curl -sS --max-time 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${MSG}" 2>&1)
    fi
    if echo "$CURL_OUTPUT" | grep -q '"ok":true'; then
      log "DEBUG: Telegram message sent successfully"
      return 0
    fi
    log "DEBUG: curl attempt $i failed: $CURL_OUTPUT"
    sleep 2
  done

  log "[!] Failed to send Telegram message after 3 attempts: $MSG"
  log "[!] Final curl error: $CURL_OUTPUT"
  echo "[!] Failed to send Telegram message: $CURL_OUTPUT" >&2
  return 1
}

# send_msg() {
#   local MESSAGE="$1"
#   local encoded_message=$(echo -n "$MESSAGE" | jq -sRr @uri)
#   local response
#   log "DEBUG: Sending Telegram message: $MESSAGE"
#   response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
#     -d "chat_id=$CHAT_ID" \
#     --data-urlencode "text=$MESSAGE")
#   if echo "$response" | grep -q '"ok":true'; then
#     log "DEBUG: Telegram message sent successfully"
#   else
#     log "[!] Failed to send Telegram message: $response"
#     return 1
#   fi
# }

send_file() {
  local FILE="$1"
  if [[ ! -s "$FILE" ]]; then
    send_msg "⚠️ File '$FILE' is empty or missing, skipping upload."
    return 1
  fi
  for i in {1..3}; do
    curl -s --max-time 30 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
      -F chat_id="$CHAT_ID" \
      -F document=@"$FILE" >/dev/null && return 0
    sleep 2
  done
  log "[!] Failed to upload file to Telegram: $FILE"
  return 1
}

send_inline_keyboard() {
  local MSG="$1"
  local BUTTONS="$2"  # JSON array of button objects: [{"text":"Label","callback_data":"data"},...]
  local REPLY_MARKUP=$(jq -c -n --argjson buttons "$BUTTONS" '{"inline_keyboard": [$buttons]}')
  send_msg "$MSG" "$REPLY_MARKUP"
}

help_menu() {
  cat <<'EOF'
📘 ReconX Bot Help

Usage:
/reconx <domain> [-j jobs]           Run enumeration for a single domain (jobs: parallel processes)
/reconx <file.txt> [-j jobs]         Bot waits for file upload, then runs enum for all domains
/httpx <file.txt> [-threads num]     Bot waits for file upload, then runs httpx-toolkit
/nuclei urls.txt -t private|public|extra [-r rate] [-threads num] [-s severity] [-tags tags]
                                     Run nuclei with specified templates (rate: req/s, threads: concurrency)
/xss <domain>                        Run XSS hunting on a single domain
/xss <file.txt>                      Bot waits for file upload, then runs XSS hunting
/all <domain> [-j jobs]              Run full pipeline: enum → httpx → nuclei (ask for templates) → xss
/all <file.txt> [-j jobs]            Same for list of domains (merges subdomains)
/cancel                              Cancel the current running task
/status                              Check the status of the current task
/resources                           Show current CPU, memory, and disk usage
/reconx -h                           Show this help menu

Enum tools:
/reconx uses subfinder, assetfinder, amass, alterx+dnsx, crt.sh, github-subdomains
Results are saved in:
/home/reconx/<domain>/ with final.txt
📦 A ZIP with all files sent to Telegram

Httpx:
/httpx subdomains.txt [-threads num]
- Runs httpx-toolkit on file
- Sends alive subdomains, stats, and subdomains_alive.txt

Nuclei:
/nuclei urls.txt -t private|public|extra [-r rate] [-threads num]
- Splits templates into chunks of 500
- Splits results into 50 vulns per file
- Sends periodic progress updates
- Sends total vulns + time taken at the end

XSS:
/xss domain.com
/xss subdomains.txt
- Runs gau → gf xss → uro → Gxss → kxss
- Produces xss_output.txt (raw) + final_test_xss.txt (cleaned)
- Both files sent to Telegram

All:
/all domain.com
/all subdomains.txt
- Runs enum → httpx → nuclei (prompts for templates) → xss
- For files, merges all subdomains into master_final.txt before httpx
- Generates recon_results.html with all results (subdomains, alive, nuclei, XSS)
- Sends HTML file to Telegram
EOF
}

# ------------- Command Cancellation and Status -------------

cancel_task() {
  if [[ -f "$PID_FILE" ]]; then
    local PID=$(cat "$PID_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
      kill -TERM "$PID" 2>/dev/null
      log "Terminated task with PID $PID"
      send_msg "✅ Task cancelled successfully."
    else
      send_msg "⚠️ No running task found for PID $PID."
      log "No running task found for PID $PID"
    fi
    rm -f "$PID_FILE" 2>/dev/null
  else
    send_msg "⚠️ No running task to cancel."
    log "No PID file found for cancellation"
  fi
  clear_wait_state
}

get_resources() {
  local CPU=$(top -bn1 | head -n3 | grep "%Cpu" | awk '{print $2}' | cut -d. -f1)
  local MEM=$(free -m | awk '/Mem:/ {printf "%.1f/%.1fGB", $3/1024, $2/1024}')
  local DISK=$(df -h "$BASE_DIR" | awk 'NR==2 {print $4}')
  echo "CPU: ${CPU}% | Memory: $MEM | Disk Free: $DISK"
}

check_status() {
  local RESOURCES=$(get_resources)
  if [[ -f "$STATE_FILE" ]]; then
    local ACTION=$(get_state_val "action")
    local EXPECTED=$(get_state_val "expected")
    local MODE=$(get_state_val "mode")
    local ALIVE=$(get_state_val "alive")
    local DOMAINS=$(get_state_val "domains")
    local START_TIME=$(get_state_val "start_time")
    local ELAPSED=$(( $(date +%s) - START_TIME ))

    local STATUS="Current task: $ACTION"
    if [[ -n "$EXPECTED" ]]; then
      STATUS="$STATUS\nWaiting for file: $EXPECTED"
    fi
    if [[ "$ACTION" == "wait_nuclei_template" ]]; then
      STATUS="$STATUS\nWaiting for nuclei template selection (private, public, or extra)"
      STATUS="$STATUS\nDomains: $DOMAINS\nAlive file: $ALIVE"
    fi
    if [[ -f "$PID_FILE" ]]; then
      local PID=$(cat "$PID_FILE")
      STATUS="$STATUS\nPID: $PID\nElapsed time: ${ELAPSED}s\nResources: $RESOURCES"
    else
      STATUS="$STATUS\nResources: $RESOURCES"
    fi
    send_msg "$STATUS"
    log "Status check: $STATUS"
  else
    send_msg "ℹ️ No active tasks or waiting state.\nResources: $RESOURCES"
    log "No active tasks or waiting state"
  fi
}

# ------------- Waiting state (per chat) -------------

set_wait_state() {
  local ACTION="$1"
  shift
  > "$STATE_FILE"
  echo "action=$ACTION" >> "$STATE_FILE"
  echo "start_time=$(date +%s)" >> "$STATE_FILE"
  for param in "$@"; do
    echo "$param" >> "$STATE_FILE"
  done
}

clear_wait_state() {
  rm -f "$STATE_FILE" "$PID_FILE" 2>/dev/null
}

have_wait_state() {
  [[ -f "$STATE_FILE" ]]
}

get_state_val() {
  grep -E "^${1}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2-
}

# ------------- Helpers -------------

validate_domain() {
  local DOMAIN="$1"
  if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    send_msg "❌ Invalid domain: $DOMAIN"
    log "Invalid domain: $DOMAIN"
    return 1
  fi
  return 0
}

sanitize_filename() {
  local FILENAME="$1"
  echo "${FILENAME//[^a-zA-Z0-9._-]/}"
}

run_tool() {
  local CMD="$1"
  local OUT="$2"
  local TOOL
  TOOL="$(echo "$CMD" | awk '{print $1}')"

  if ! command -v "$TOOL" >/dev/null 2>&1; then
    log "[!] $TOOL not installed"
    send_msg "❌ $TOOL not installed, skipping."
    return 1
  fi

  for i in {1..3}; do
    eval "$CMD" 2>/dev/null | sort -u > "$OUT" && return 0
    log "[!] $TOOL failed attempt $i, retrying..."
    sleep 2
  done
  log "[!] $TOOL failed after 3 attempts"
  echo "[!] $TOOL failed after 3 attempts" > "$OUT"
  return 1
}

count_lines() {
  local FILE="$1"
  [[ -f "$FILE" ]] && grep -v '^\[!\]' "$FILE" | wc -l || echo 0
}

escape_html() {
  local CONTENT="$1"
  echo "$CONTENT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

# ------------- HTML Generation -------------

generate_html() {
  local DOMAINS="$1"
  local ALIVE="$2"
  local HTML_FILE="$BASE_DIR/recon_results.html"
  local SCAN_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

  > "$HTML_FILE"

  cat <<EOF > "$HTML_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Recon Results</title>
    <style>
        :root {
        --primary-bg: #1a1a1a; /* Dark gray for hacker vibe */
        --secondary-bg: #2a2a2a; /* Slightly lighter for containers */
        --text-color: #e0e0e0; /* Light gray for readability */
        --accent-color: #ff4d4d; /* Subtle red for highlights */
        --code-bg: #252526; /* Dark code background */
        --border-color: #3a3a3a; /* Subtle border */
        --button-bg: #005f99; /* Deep blue for buttons */
        --button-hover: #003d66; /* Darker blue on hover */
        --glow: 0 0 5px rgba(255, 77, 77, 0.5); /* Subtle red glow */
      }

      body {
        font-family: 'Roboto Mono', monospace; /* Monospaced, techy font */
        margin: 2vw;
        background: var(--primary-bg);
        color: var(--text-color);
        line-height: 1.6;
        font-size: clamp(14px, 2vw, 16px); /* Responsive font size */
      }

      h1 {
        color: var(--text-color);
        font-size: clamp(24px, 4vw, 28px);
        text-shadow: var(--glow);
        margin-bottom: 1.5rem;
      }

      h2, h3 {
        color: var(--text-color);
        font-size: clamp(18px, 3vw, 22px);
        margin-bottom: 1rem;
      }

      section {
        margin-bottom: 3vw;
        padding: 1.5vw;
        border-radius: 8px;
        background: var(--secondary-bg);
        box-shadow: var(--glow);
      }

      details {
        margin: 1.5vw 0;
        padding: 1vw;
        background: var(--secondary-bg);
        border: 1px solid var(--border-color);
        border-radius: 8px;
        transition: border-color 0.3s ease;
      }

      details:hover {
        border-color: var(--accent-color);
      }

      summary {
        cursor: pointer;
        font-weight: 600;
        color: var(--accent-color);
        font-size: clamp(14px, 2vw, 16px);
      }

      pre {
        background: var(--code-bg);
        padding: 1.5vw;
        border-radius: 8px;
        overflow-x: auto;
        max-height: 50vh; /* Responsive height */
        font-size: clamp(12px, 1.8vw, 14px);
        white-space: pre-wrap;
        word-break: break-word;
        border-left: 4px solid var(--accent-color);
      }

      button {
        padding: 0.8rem 1.5rem;
        margin-top: 1vw;
        background: var(--button-bg);
        color: var(--text-color);
        border: none;
        border-radius: 5px;
        cursor: pointer;
        font-family: 'Roboto Mono', monospace;
        font-size: clamp(12px, 1.8vw, 14px);
        transition: background 0.3s ease, box-shadow 0.3s ease;
      }

      button:hover {
        background: var(--button-hover);
        box-shadow: var(--glow);
      }

      input[type="text"] {
        padding: 0.8rem;
        width: 100%;
        max-width: min(90vw, 400px); /* Responsive max-width */
        margin-bottom: 1vw;
        background: var(--secondary-bg);
        color: var(--text-color);
        border: 1px solid var(--border-color);
        border-radius: 5px;
        font-family: 'Roboto Mono', monospace;
        font-size: clamp(12px, 1.8vw, 14px);
      }

      input[type="text"]:focus {
        outline: none;
        border-color: var(--accent-color);
        box-shadow: var(--glow);
      }

      p.empty {
        color: #888;
        font-style: italic;
        font-size: clamp(12px, 1.8vw, 14px);
      }

      /* Dark mode (optional, for toggle compatibility) */
      .dark-mode {
        background: var(--primary-bg);
        color: var(--text-color);
      }

      .dark-mode pre {
        background: var(--code-bg);
      }

      .dark-mode details {
        background: var(--secondary-bg);
        border-color: var(--border-color);
      }

      .dark-mode button {
        background: var(--button-bg);
      }

      .dark-mode button:hover {
        background: var(--button-hover);
        box-shadow: var(--glow);
      }

      .dark-mode .empty {
        color: #888;
      }

      /* Responsive adjustments */
      @media (max-width: 768px) {
        body {
          margin: 4vw;
          font-size: clamp(12px, 3vw, 14px);
        }

        h1 {
          font-size: clamp(20px, 5vw, 24px);
        }

        h2, h3 {
          font-size: clamp(16px, 4vw, 18px);
        }

        section {
          padding: 3vw;
        }

        details {
          padding: 2vw;
        }

        pre {
          padding: 2vw;
          max-height: 40vh;
        }

        button, input[type="text"] {
          padding: 0.6rem 1.2rem;
          font-size: clamp(11px, 2.5vw, 13px);
        }
      }

      @media (max-width: 480px) {
        body {
          margin: 5vw;
        }

        h1 {
          font-size: clamp(18px, 6vw, 20px);
        }

        section {
          margin-bottom: 5vw;
        }

        input[type="text"] {
          max-width: 95vw;
        }
      }
    </style>
    <script>
        function copyToClipboard(id) {
            var text = document.getElementById(id).innerText;
            navigator.clipboard.writeText(text).then(function() {
                alert('Copied to clipboard!');
            }, function(err) {
                alert('Failed to copy: ' + err);
            });
        }
        function searchSection(sectionId) {
            var input = document.getElementById('search-' + sectionId).value.toLowerCase();
            var preElements = document.querySelectorAll('#' + sectionId + ' pre');
            preElements.forEach(function(pre) {
                var text = pre.innerText.toLowerCase();
                pre.parentElement.style.display = text.includes(input) ? '' : 'none';
            });
        }
        function exportToCSV(id, filename) {
            var text = document.getElementById(id).innerText;
            var blob = new Blob([text], { type: 'text/csv' });
            var link = document.createElement('a');
            link.href = URL.createObjectURL(blob);
            link.download = filename;
            link.click();
        }
        function toggleDarkMode() {
            document.body.classList.toggle('dark-mode');
        }
    </script>
</head>
<body>
    <h1>Recon Results</h1>
    <p>Scan started: $SCAN_TIME</p>
    <button onclick="toggleDarkMode()">Toggle Dark Mode</button>

    <section id="subdomains">
        <h2>Subdomains</h2>
        <input type="text" id="search-subdomains" placeholder="Search subdomains..." onkeyup="searchSection('subdomains')">
EOF

  for domain in $DOMAINS; do
    local OUT_DIR="$BASE_DIR/$domain"
    [[ ! -d "$OUT_DIR" ]] && continue
    echo "        <h3>Domain: $domain</h3>" >> "$HTML_FILE"
    for source in subfinder assetfinder amass alterx crtsh github final; do
      local FILE="$OUT_DIR/${source}.txt"
      if [[ -s "$FILE" ]]; then
        local COUNT=$(count_lines "$FILE")
        local CONTENT=$(cat "$FILE")
        local ESCAPED_CONTENT=$(escape_html "$CONTENT")
        local ID="${domain}-${source}"
        cat <<EOF >> "$HTML_FILE"
        <details>
            <summary>$source ($COUNT)</summary>
            <pre id="$ID">$ESCAPED_CONTENT</pre>
            <button onclick="copyToClipboard('$ID')">Copy</button>
            <button onclick="exportToCSV('$ID', '$source-$domain.csv')">Export to CSV</button>
        </details>
EOF
      fi
    done
  done

  cat <<EOF >> "$HTML_FILE"
    </section>

    <section id="alive">
        <h2>Alive Subdomains</h2>
        <input type="text" id="search-alive" placeholder="Search alive subdomains..." onkeyup="searchSection('alive')">
EOF

  if [[ -s "$ALIVE" ]]; then
    local COUNT=$(count_lines "$ALIVE")
    local CONTENT=$(cat "$ALIVE")
    local ESCAPED_CONTENT=$(escape_html "$CONTENT")
    cat <<EOF >> "$HTML_FILE"
        <details>
            <summary>Alive Subdomains ($COUNT)</summary>
            <pre id="alive">$ESCAPED_CONTENT</pre>
            <button onclick="copyToClipboard('alive')">Copy</button>
            <button onclick="exportToCSV('alive', 'alive-subdomains.csv')">Export to CSV</button>
        </details>
EOF
  else
    echo "        <p class='empty'>No alive subdomains found.</p>" >> "$HTML_FILE"
  fi

  cat <<EOF >> "$HTML_FILE"
    </section>

    <section id="nuclei">
        <h2>Nuclei Results</h2>
        <input type="text" id="search-nuclei" placeholder="Search nuclei results..." onkeyup="searchSection('nuclei')">
EOF

  local IDX=1
  while [[ -f "$BASE_DIR/nuclei_result_part${IDX}.txt" ]]; do
    local FILE="$BASE_DIR/nuclei_result_part${IDX}.txt"
    local COUNT=$(count_lines "$FILE")
    local CONTENT=$(cat "$FILE")
    local ESCAPED_CONTENT=$(escape_html "$CONTENT")
    local ID="nuclei-$IDX"
    cat <<EOF >> "$HTML_FILE"
        <details>
            <summary>Part $IDX ($COUNT vulnerabilities)</summary>
            <pre id="$ID">$ESCAPED_CONTENT</pre>
            <button onclick="copyToClipboard('$ID')">Copy</button>
            <button onclick="exportToCSV('$ID', 'nuclei-part$IDX.csv')">Export to CSV</button>
        </details>
EOF
    IDX=$((IDX + 1))
  done
  if [[ $IDX -eq 1 ]]; then
    echo "        <p class='empty'>No nuclei results found.</p>" >> "$HTML_FILE"
  fi

  cat <<EOF >> "$HTML_FILE"
    </section>

    <section id="xss">
        <h2>XSS Results</h2>
        <input type="text" id="search-xss" placeholder="Search XSS results..." onkeyup="searchSection('xss')">
EOF

  for xss_file in xss_output.txt final_test_xss.txt; do
    local FILE="$BASE_DIR/xss/$xss_file"
    if [[ -s "$FILE" ]]; then
      local TITLE=$(echo "$xss_file" | sed 's/.txt$//; s/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
      local COUNT=$(count_lines "$FILE")
      local CONTENT=$(cat "$FILE")
      local ESCAPED_CONTENT=$(escape_html "$CONTENT")
      local ID=$(echo "$xss_file" | sed 's/.txt$//')
      cat <<EOF >> "$HTML_FILE"
        <details>
            <summary>$TITLE ($COUNT)</summary>
            <pre id="$ID">$ESCAPED_CONTENT</pre>
            <button onclick="copyToClipboard('$ID')">Copy</button>
            <button onclick="exportToCSV('$ID', '$xss_file.csv')">Export to CSV</button>
        </details>
EOF
    fi
  done
  if [[ ! -f "$BASE_DIR/xss/xss_output.txt" && ! -f "$BASE_DIR/xss/final_test_xss.txt" ]]; then
    echo "        <p class='empty'>No XSS results found.</p>" >> "$HTML_FILE"
  fi

  cat <<EOF >> "$HTML_FILE"
    </section>
</body>
</html>
EOF

  send_msg "📊 Full Recon Results HTML generated."
  send_file "$HTML_FILE"
}

# ------------- Enum pipeline -------------

# run_enum() {
#   local INPUT="$1"
#   local JOBS="$2"
#   local DOMAINS

#   # Ensure PARALLEL_JOBS is set
#   PARALLEL_JOBS=$(echo -n "$PARALLEL_JOBS" | tr -d '\r\n\t ')
#   if [[ -z "$PARALLEL_JOBS" || ! "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
#     log "[!] PARALLEL_JOBS is unset or invalid, defaulting to 4"
#     export PARALLEL_JOBS=4
#   fi

#   echo $$ > "$PID_FILE"
#   if [[ -f "$INPUT" ]]; then
#     DOMAINS=$(tr -d '\r' < "$INPUT" | sed '/^$/d' | grep -E '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
#   else
#     validate_domain "$INPUT" || return 1
#     DOMAINS="$INPUT"
#   fi

#   [[ -z "$DOMAINS" ]] && { send_msg "❌ No valid domains provided."; log "No valid domains provided"; return 1; }

#   local COUNT=$(echo "$DOMAINS" | grep -v '^$' | wc -l)
#   local INDEX=0

#   export -f run_tool validate_domain send_msg send_file count_lines log
#   export BOT_TOKEN CHAT_ID BASE_DIR
#   echo "$DOMAINS" | grep -v '^$' | parallel -j "${JOBS:-$PARALLEL_JOBS}" '
#     domain={}
#     [[ -z "$domain" ]] && { log "[!] Empty domain skipped"; exit; }
#     ((INDEX++))
#     validate_domain "$domain" || { log "[!] Invalid domain skipped: $domain"; exit; }
#     send_msg "🚀 Processing domain $INDEX/$COUNT: $domain"
#     log "Starting subdomain enumeration for $domain"
#     START=$(date +%s)
#     OUT_DIR="$BASE_DIR/$domain"
#     mkdir -p "$OUT_DIR"

#     run_tool "subfinder -d $domain -all -recursive -silent" "$OUT_DIR/subfinder.txt"
#     run_tool "assetfinder -subs-only $domain" "$OUT_DIR/assetfinder.txt"
#     run_tool "amass enum -d $domain -passive -silent -timeout 5" "$OUT_DIR/amass.txt"
#     run_tool "alterx -pp word=/usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt -d $domain | dnsx -silent" "$OUT_DIR/alterx.txt"

#     # crt.sh
#     if command -v jq >/dev/null 2>&1; then
#       curl -s --max-time 10 "https://crt.sh/?q=%25.$domain&output=json" \
#         | jq -r ".[].name_value" 2>/dev/null \
#         | sed "s/\*\.//g" | sort -u > "$OUT_DIR/crtsh.txt"
#     else
#       curl -s --max-time 10 "https://crt.sh/?q=%25.$domain" \
#         | grep -Eo "[a-zA-Z0-9._-]+\.$domain" | sort -u > "$OUT_DIR/crtsh.txt"
#     fi

#     run_tool "github-subdomains -d $domain -t ~/go/bin/.tokens | grep -Eo \"([a-zA-Z0-9_-]+\\.)+$domain\"" "$OUT_DIR/github.txt"

#     # Merge safely with debugging
#     log "DEBUG: Merging files in $OUT_DIR to $OUT_DIR/final.txt"
#     find "$OUT_DIR" -type f -name "*.txt" -exec ls -l {} \; 2>/dev/null | while read -r line; do
#       log "DEBUG: Found file: $line"
#     done
#     touch "$OUT_DIR/final.txt"
#     chmod 644 "$OUT_DIR/final.txt"
#     cat "$OUT_DIR"/*.txt 2>/dev/null | grep -v "^\[!\]" | sort -u > "$OUT_DIR/final.txt"
#     if [[ ! -s "$OUT_DIR/final.txt" ]]; then
#       log "[!] Final merge is empty for $domain"
#       send_msg "⚠️ Warning: final.txt is empty for $domain"
#       ls -l "$OUT_DIR"/*.txt 2>/dev/null | while read -r line; do
#         log "DEBUG: File contents for $line"
#         cat "$(echo "$line" | awk '{print $NF}')" | while read -r content; do
#           log "DEBUG: Content: $content"
#         done
#       done
#     else
#       log "DEBUG: Merged $(count_lines "$OUT_DIR/final.txt") subdomains into $OUT_DIR/final.txt"
#     fi

#     SUBF=$(count_lines "$OUT_DIR/subfinder.txt")
#     ASSET=$(count_lines "$OUT_DIR/assetfinder.txt")
#     AMASS=$(count_lines "$OUT_DIR/amass.txt")
#     ALTERX=$(count_lines "$OUT_DIR/alterx.txt")
#     CRT=$(count_lines "$OUT_DIR/crtsh.txt")
#     GITHUB=$(count_lines "$OUT_DIR/github.txt")
#     FINAL=$(count_lines "$OUT_DIR/final.txt")

#     END=$(date +%s)
#     DURATION=$((END - START))

#     ZIP="$BASE_DIR/${domain}_subdomains.zip"
#     if ! zip -j -q "$ZIP" "$OUT_DIR"/*.txt 2>/dev/null; then
#       send_msg "⚠️ Failed to create ZIP for $domain"
#       log "Failed to create ZIP for $domain"
#       exit
#     fi

#     REPORT=$(cat <<EOR
# 📊 Subdomain Report for $domain

# 🔹 subfinder: $SUBF
# 🔹 assetfinder: $ASSET
# 🔹 amass: $AMASS
# 🔹 alterx: $ALTERX
# 🔹 crt.sh: $CRT
# 🔹 github: $GITHUB

# 📦 Final unique subdomains: $FINAL
# ⏱️ Time taken: ${DURATION}s
# EOR
# )
#     send_msg "$REPORT"
#     send_file "$ZIP"
#   '
#   rm -f "$PID_FILE" 2>/dev/null
# }

run_enum() {
  local INPUT="$1"
  local JOBS="$2"
  local DOMAINS

  # Ensure PARALLEL_JOBS is set
  PARALLEL_JOBS=$(echo -n "$PARALLEL_JOBS" | tr -d '\r\n\t ')
  if [[ -z "$PARALLEL_JOBS" || ! "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    log "[!] PARALLEL_JOBS is unset or invalid, defaulting to 4"
    export PARALLEL_JOBS=4
  fi

  echo $$ > "$PID_FILE"
  if [[ -f "$INPUT" ]]; then
    DOMAINS=$(tr -d '\r' < "$INPUT" | sed '/^$/d' | grep -E '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
  else
    validate_domain "$INPUT" || return 1
    DOMAINS="$INPUT"
  fi

  [[ -z "$DOMAINS" ]] && { send_msg "❌ No valid domains provided."; log "No valid domains provided"; return 1; }

  local COUNT=$(echo "$DOMAINS" | grep -v '^$' | wc -l | tr -d ' ')
  local INDEX=0

  export -f run_tool validate_domain send_msg send_file count_lines log
  export BOT_TOKEN CHAT_ID BASE_DIR COUNT
  echo "$DOMAINS" | grep -v '^$' | parallel -j "${JOBS:-$PARALLEL_JOBS}" --eta --progress '
    domain={}
    [[ -z "$domain" ]] && { log "[!] Empty domain skipped"; exit; }
    INDEX=$((INDEX + 1))
    validate_domain "$domain" || { log "[!] Invalid domain skipped: $domain"; exit; }
    send_msg "🚀 Processing domain $INDEX/$COUNT: $domain"
    log "Starting subdomain enumeration for $domain"
    START=$(date +%s)
    OUT_DIR="$BASE_DIR/$domain"
    mkdir -p "$OUT_DIR"

    run_tool "subfinder -d $domain -all -recursive -silent" "$OUT_DIR/subfinder.txt"
    run_tool "assetfinder -subs-only $domain" "$OUT_DIR/assetfinder.txt"
    run_tool "amass enum -d $domain -passive -silent -timeout 5" "$OUT_DIR/amass.txt"
    run_tool "alterx -pp word=/usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt -d $domain | dnsx -silent" "$OUT_DIR/alterx.txt"

    # crt.sh
    if command -v jq >/dev/null 2>&1; then
      curl -s --max-time 10 "https://crt.sh/?q=%25.$domain&output=json" \
        | jq -r ".[].name_value" 2>/dev/null \
        | sed "s/\*\.//g" | sort -u > "$OUT_DIR/crtsh.txt"
    else
      curl -s --max-time 10 "https://crt.sh/?q=%25.$domain" \
        | grep -Eo "[a-zA-Z0-9._-]+\.$domain" | sort -u > "$OUT_DIR/crtsh.txt"
    fi

    run_tool "github-subdomains -d $domain -t ~/go/bin/.tokens | grep -Eo \"([a-zA-Z0-9_-]+\\.)+$domain\"" "$OUT_DIR/github.txt"

    # Merge safely with debugging
    log "DEBUG: Merging files in $OUT_DIR to $OUT_DIR/final.txt"
    find "$OUT_DIR" -type f -name "*.txt" -exec ls -l {} \; 2>/dev/null | while read -r line; do
      log "DEBUG: Found file: $line"
    done
    touch "$OUT_DIR/final.txt"
    chmod 644 "$OUT_DIR/final.txt"
    cat "$OUT_DIR"/*.txt 2>/dev/null | grep -v "^\[!\]" | sort -u > "$OUT_DIR/final.txt"
    if [[ ! -s "$OUT_DIR/final.txt" ]]; then
      log "[!] Final merge is empty for $domain"
      send_msg "⚠️ Warning: final.txt is empty for $domain"
      ls -l "$OUT_DIR"/*.txt 2>/dev/null | while read -r line; do
        log "DEBUG: File contents for $line"
        cat "$(echo "$line" | awk '{print $NF}')" | while read -r content; do
          log "DEBUG: Content: $content"
        done
      done
    else
      log "DEBUG: Merged $(count_lines "$OUT_DIR/final.txt") subdomains into $OUT_DIR/final.txt"
    fi

    SUBF=$(count_lines "$OUT_DIR/subfinder.txt")
    ASSET=$(count_lines "$OUT_DIR/assetfinder.txt")
    AMASS=$(count_lines "$OUT_DIR/amass.txt")
    ALTERX=$(count_lines "$OUT_DIR/alterx.txt")
    CRT=$(count_lines "$OUT_DIR/crtsh.txt")
    GITHUB=$(count_lines "$OUT_DIR/github.txt")
    FINAL=$(count_lines "$OUT_DIR/final.txt")

    END=$(date +%s)
    DURATION=$((END - START))

    ZIP="$BASE_DIR/${domain}_subdomains.zip"
    if ! zip -j -q "$ZIP" "$OUT_DIR"/*.txt 2>/dev/null; then
      send_msg "⚠️ Failed to create ZIP for $domain"
      log "Failed to create ZIP for $domain"
      exit
    fi

    REPORT=$(cat <<EOR
📊 Subdomain Report for $domain

🔹 subfinder: $SUBF
🔹 assetfinder: $ASSET
🔹 amass: $AMASS
🔹 alterx: $ALTERX
🔹 crt.sh: $CRT
🔹 github: $GITHUB

📦 Final unique subdomains: $FINAL
⏱️ Time taken: ${DURATION}s
EOR
)
    send_msg "$REPORT"
    send_file "$ZIP"
  '
  rm -f "$PID_FILE" 2>/dev/null
}

# ------------- Httpx pipeline -------------

run_httpx() {
  local INPUT="$1"
  local THREADS="$2"
  if [[ ! -f "$INPUT" ]]; then
    send_msg "❌ File '$INPUT' not found on server."
    log "File $INPUT not found"
    return 1
  fi

  if ! command -v httpx >/dev/null 2>&1; then
    send_msg "❌ httpx not installed."
    log "httpx not installed"
    return 1
  fi

  echo $$ > "$PID_FILE"
  local START END DURATION TOTAL ALIVE OUT_FILE
  START=$(date +%s)
  TOTAL=$(wc -l < "$INPUT" | tr -d ' ')
  send_msg "🌐 Running httpx on $TOTAL subdomains from $(basename "$INPUT") ..."
  log "Running httpx on $TOTAL subdomains from $INPUT"

  OUT_FILE="$(dirname "$INPUT")/subdomains_alive.txt"

  httpx -l "$INPUT" -ports 80,443,8080,8000,8888 ${THREADS:+-c "$THREADS"} -silent -o "$OUT_FILE" 2>> "$LOG_FILE"

  ALIVE=$(count_lines "$OUT_FILE")
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
  rm -f "$PID_FILE" 2>/dev/null
}

# ------------- Nuclei -------------

run_nuclei() {
  local INPUT="$1"; local MODE="$2"; local RATE_LIMIT=""; local THREADS=""
  shift 2
  local SEVERITY=""; local TAGS=""

  # Parse optional args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s) SEVERITY="$2"; shift 2;;
      -tags) TAGS="$2"; shift 2;;
      -r) RATE_LIMIT="$2"; shift 2;;
      -threads) THREADS="$2"; shift 2;;
      *) shift;;
    esac
  done

  if [[ ! -f "$INPUT" ]]; then
    send_msg "❌ Input file '$INPUT' not found."
    log "Input file $INPUT not found"
    return 1
  fi

  echo $$ > "$PID_FILE"
  local start_time=$(date +%s)
  local result_file="$BASE_DIR/nuclei_result.log"
  > "$result_file"

  case "$MODE" in
    private) templates="$PRIVATE_TEMPLATES" ;;
    public)  templates="$NUCLEI_DEFAULT_TEMPLATES" ;;
    extra)   templates="$NUCLEI_EXTRA_TEMPLATES" ;;
    *) send_msg "❌ Unknown mode: $MODE"; log "Unknown nuclei mode: $MODE"; return 1 ;;
  esac

  [[ ! -d "$templates" ]] && { send_msg "❌ Templates dir $templates not found"; log "Templates dir $templates not found"; return 1; }

  send_msg "🚀 Starting nuclei scan on $(basename "$INPUT") (mode=$MODE severity=$SEVERITY tags=$TAGS rate=$RATE_LIMIT threads=$THREADS)"
  log "Starting nuclei scan on $INPUT (mode=$MODE severity=$SEVERITY tags=$TAGS rate=$RATE_LIMIT threads=$THREADS)"

  # Split templates into chunks of 500
  mapfile -t templates_list < <(find "$templates" -type f -name "*.yaml" 2>/dev/null)
  [[ ${#templates_list[@]} -eq 0 ]] && { send_msg "❌ No templates found in $templates"; log "No templates found in $templates"; return 1; }
  split -l 500 <(printf "%s\n" "${templates_list[@]}") tmpl_chunk_ 2>/dev/null

  # Split input file into chunks of 1000 URLs
  local INPUT_DIR="$BASE_DIR/nuclei_input_chunks"
  mkdir -p "$INPUT_DIR"
  split -l 1000 "$INPUT" "$INPUT_DIR/input_chunk_" 2>/dev/null
  mapfile -t input_chunks < <(find "$INPUT_DIR" -type f -name "input_chunk_*" 2>/dev/null)
  [[ ${#input_chunks[@]} -eq 0 ]] && { send_msg "❌ Failed to create input chunks"; log "Failed to create input chunks"; return 1; }

  local TOTAL_URLS=$(count_lines "$INPUT")
  local TOTAL_CHUNKS=${#input_chunks[@]}
  local CURRENT_CHUNK=0
  local TOTAL_TEMPLATES=${#templates_list[@]}
  local CURRENT_TEMPLATE=0
  local last_report_time=$start_time
  local vuln_count=0

  for chunk in tmpl_chunk_*; do
    [[ ! -f "$chunk" ]] && continue
    for input_chunk in "${input_chunks[@]}"; do
      [[ ! -f "$input_chunk" ]] && continue
      ((CURRENT_CHUNK++))
      log "Processing input chunk $CURRENT_CHUNK/$TOTAL_CHUNKS: $input_chunk"
      while read -r template_path; do
        ((CURRENT_TEMPLATE++))
        [[ ! -f "$template_path" ]] && continue
        log "Scanning template $CURRENT_TEMPLATE/$TOTAL_TEMPLATES on chunk $CURRENT_CHUNK/$TOTAL_CHUNKS"

        # --- FIXED nuclei output capture (no JSON) ---
        TMP_NUC_OUT="$BASE_DIR/nuclei_tmp_output.log"
        rm -f "$TMP_NUC_OUT"
        nuclei -l "$input_chunk" -t "$template_path" \
          ${SEVERITY:+-severity "$SEVERITY"} \
          ${TAGS:+-tags "$TAGS"} \
          ${RATE_LIMIT:+-rate-limit "$RATE_LIMIT"} \
          ${THREADS:+-c "$THREADS"} \
          -silent -o "$TMP_NUC_OUT" 2>>"$LOG_FILE" || true

        if [[ -s "$TMP_NUC_OUT" ]]; then
          awk '
          {
            line = $0
            # Pattern: [severity] host -> templateID (template name)
            if (match(line, /^\[([a-zA-Z]+)\][[:space:]]+([^[:space:]]+).*?([A-Za-z0-9._-]+)\s*\((.*)\)$/, m)) {
              sev = m[1]; host = m[2]; tid = m[3]; tname = m[4];
              printf("%s\t%s\t%s\t%s\n", sev, tname, tid, host); next
            }
            # Pattern: host | templateID | template name
            if (match(line, /^([^|]+)\|\s*([^|]+)\|\s*(.+)$/, m2)) {
              host = gensub(/^[[:space:]]+|[[:space:]]+$/, "", "g", m2[1]);
              tid  = gensub(/^[[:space:]]+|[[:space:]]+$/, "", "g", m2[2]);
              tname = gensub(/^[[:space:]]+|[[:space:]]+$/, "", "g", m2[3]);
              printf("UNKNOWN\t%s\t%s\t%s\n", tname, tid, host); next
            }
            # Fallback raw line
            printf("RAW\t%s\t-\t%s\n", substr(line,1,80), line)
          }' "$TMP_NUC_OUT" >> "$result_file" 2>>"$LOG_FILE" || cat "$TMP_NUC_OUT" >> "$result_file"
          rm -f "$TMP_NUC_OUT"
        fi
        # --- END nuclei fix ---

        # Send hourly report
        local current_time=$(date +%s)
        if (( current_time - last_report_time >= 3600 )); then
          local new_vulns=$(count_lines "$result_file")
          local resources=$(get_resources)
          local elapsed=$((current_time - start_time))
          local REPORT=$(cat <<EOR
📊 Nuclei Progress Report
⏱️ Elapsed: ${elapsed}s
📄 URLs: $TOTAL_URLS (chunk $CURRENT_CHUNK/$TOTAL_CHUNKS)
🛠️ Templates: $CURRENT_TEMPLATE/$TOTAL_TEMPLATES
🔎 Vulnerabilities: $new_vulns
📈 Resources: $resources
EOR
)
          send_msg "$REPORT"
          log "Sent hourly report: $REPORT"
          last_report_time=$current_time
          vuln_count=$new_vulns
        fi
      done < "$chunk"
    done
    rm -f "$chunk" 2>/dev/null
  done

  rm -rf "$INPUT_DIR" 2>/dev/null

  # Pretty print results
  awk -F'\t' '{
    printf("[%s] %s → %s\nTemplate: %s\nMatcher: %s\nExtracted: %s\n\n",
      toupper($1), $2, $4, $3, $5, $6);
  }' "$result_file" > "$BASE_DIR/nuclei_pretty.txt" 2>>"$LOG_FILE"

  split -l 50 "$BASE_DIR/nuclei_pretty.txt" nuclei_result_part_ 2>/dev/null
  idx=1
  for part in nuclei_result_part_*; do
    [[ ! -s "$part" ]] && continue
    mv "$part" "$BASE_DIR/nuclei_result_part${idx}.txt" 2>/dev/null
    send_file "$BASE_DIR/nuclei_result_part${idx}.txt"
    idx=$((idx+1))
  done

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local total=$(count_lines "$result_file")

  send_msg "✅ Nuclei scan completed.
🕒 Time taken: ${duration}s
🔎 Total vulns: $total"
  log "Nuclei scan completed: $total vulns in ${duration}s"
  rm -f "$PID_FILE" 2>/dev/null
}


# ------------- Telegram file download -------------

download_document() {
  local FILE_ID="$1"
  local FILE_NAME="$2"
  FILE_NAME=$(sanitize_filename "$FILE_NAME")
  local DEST_PATH="$UPLOADS_DIR/$FILE_NAME"

  # Get file path from Telegram
  local FILE_INFO FILE_PATH
  FILE_INFO=$(curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/getFile?file_id=$FILE_ID")
  FILE_PATH=$(echo "$FILE_INFO" | jq -r '.result.file_path // empty')

  if [[ -z "$FILE_PATH" || "$FILE_PATH" == "null" ]]; then
    send_msg "⚠️ Could not resolve file path for '$FILE_NAME'."
    log "Could not resolve file path for $FILE_NAME"
    return 1
  fi

  # Download actual file
  curl -s --max-time 30 -o "$DEST_PATH" "https://api.telegram.org/file/bot$BOT_TOKEN/$FILE_PATH" || {
    send_msg "❌ Failed to download '$FILE_NAME'."
    log "Failed to download $FILE_NAME"
    return 1
  }
  echo "$DEST_PATH"
  return 0
}

# ------------- XSS pipeline -------------

# run_xss() {
#   local SUB_ALIVE="$1"
#   local domain=$(basename "$(dirname "$SUB_ALIVE")")
#   local xss_dir="/root/subdomains/$domain/xss"
#   local xss_output="$xss_dir/xss_results.txt"
#   local xss_input_chunks="$xss_dir/xss_input_chunks"
#   local gau_temp="$xss_dir/gau_temp.txt"
#   : > "$xss_output"
#   mkdir -p "$xss_dir" "$xss_input_chunks"
#   send_msg "🚀 Starting XSS hunting on $SUB_ALIVE"
#   log "Starting XSS hunting on $SUB_ALIVE"
#   local total_lines=$(wc -l < "$SUB_ALIVE")
#   if [[ ! -s "$SUB_ALIVE" || $total_lines -eq 0 ]]; then
#     send_msg "❌ No subdomains found in $SUB_ALIVE, skipping XSS hunting..."
#     log "No subdomains found in $SUB_ALIVE, skipping XSS hunting"
#     return
#   fi
#   local chunk_size=$(( (total_lines + PARALLEL_JOBS - 1) / PARALLEL_JOBS ))
#   if [[ $chunk_size -eq 0 ]]; then
#     chunk_size=1
#   fi
#   split -l "$chunk_size" -a 2 -d "$SUB_ALIVE" "$xss_input_chunks/xss_chunk_"
#   local chunk_files=("$xss_input_chunks/xss_chunk_"*)
#   local total_chunks=${#chunk_files[@]}
#   local chunk_num=0
#   for chunk_file in "${chunk_files[@]}"; do
#     ((chunk_num++))
#     local gau_output="$xss_dir/gau_chunk_$chunk_num.txt"
#     : > "$gau_output"
#     if [[ ! -s "$chunk_file" ]]; then
#       log "Chunk $chunk_num is empty, skipping..."
#       continue
#     fi
#     log "Processing XSS chunk $chunk_num/$total_chunks: $chunk_file"
#     while IFS= read -r subdomain; do
#       if [[ -n "$subdomain" ]]; then
#         log "Running gau on $subdomain (chunk $chunk_num)"
#         gau "$subdomain" > "$gau_temp" 2>/dev/null
#         if [[ -s "$gau_temp" ]]; then
#           log "gau completed for $subdomain (chunk $chunk_num)"
#           cat "$gau_temp" >> "$gau_output"
#         else
#           log "gau produced empty output for $subdomain (chunk $chunk_num)"
#         fi
#       fi
#     done < "$chunk_file"
#     if [[ ! -s "$gau_output" ]]; then
#       log "No URLs found for chunk $chunk_num after gau, skipping further processing"
#       continue
#     fi
#     local gf_output="$xss_dir/gf_xss_chunk_$chunk_num.txt"
#     local kxss_output="$xss_dir/kxss_chunk_$chunk_num.txt"
#     local gxss_output="$xss_dir/gxss_chunk_$chunk_num.txt"
#     log "Running gf xss on chunk $chunk_num"
#     gf xss < "$gau_output" | sort -u > "$gf_output"
#     if [[ -s "$gf_output" ]]; then
#       log "Running kxss on chunk $chunk_num"
#       kxss -i "$gf_output" -o "$kxss_output" 2>/dev/null
#       if [[ -s "$kxss_output" ]]; then
#         log "Running Gxss on chunk $chunk_num"
#         Gxss -i "$kxss_output" -o "$gxss_output" 2>/dev/null
#         if [[ -s "$gxss_output" ]]; then
#           log "Appending Gxss results to $xss_output for chunk $chunk_num"
#           cat "$gxss_output" >> "$xss_output"
#         else
#           log "No Gxss results for chunk $chunk_num"
#         fi
#       else
#         log "No kxss results for chunk $chunk_num"
#       fi
#     else
#       log "No gf xss results for chunk $chunk_num"
#     fi
#   done
#   if [[ -s "$xss_output" ]]; then
#     local total_xss=$(wc -l < "$xss_output")
#     send_msg "✅ XSS hunting completed for $domain\n🕒 Time taken: ${SECONDS}s\n🔎 Total XSS findings: $total_xss\n📄 Output file: $xss_output"
#     log "XSS hunting completed for $domain, $total_xss findings in $xss_output"
#   else
#     send_msg "❌ No XSS findings for $domain"
#     log "No XSS findings for $domain"
#   fi
#   rm -rf "$xss_input_chunks" "$gau_temp"
# }

run_xss() {
  local SUB_ALIVE="$1"
  local domain=$(basename "$(dirname "$SUB_ALIVE")")
  local xss_dir="/root/subdomains/$domain/xss"
  local xss_output="$xss_dir/xss_results.txt"
  local xss_input_chunks="$xss_dir/xss_input_chunks"
  local gau_temp="$xss_dir/gau_temp.txt"
  : > "$xss_output"
  mkdir -p "$xss_dir" "$xss_input_chunks"
  send_msg "🚀 Starting XSS hunting on $SUB_ALIVE"
  log "Starting XSS hunting on $SUB_ALIVE"
  local total_lines=$(wc -l < "$SUB_ALIVE")
  if [[ ! -s "$SUB_ALIVE" || $total_lines -eq 0 ]]; then
    send_msg "❌ No subdomains found in $SUB_ALIVE, skipping XSS hunting..."
    log "No subdomains found in $SUB_ALIVE, skipping XSS hunting"
    return
  fi
  local chunk_size=$(( (total_lines + PARALLEL_JOBS - 1) / PARALLEL_JOBS ))
  if [[ $chunk_size -eq 0 ]]; then
    chunk_size=1
  fi
  split -l "$chunk_size" -a 2 -d "$SUB_ALIVE" "$xss_input_chunks/xss_chunk_"
  local chunk_files=("$xss_input_chunks/xss_chunk_"*)
  local total_chunks=${#chunk_files[@]}
  local chunk_num=0
  for chunk_file in "${chunk_files[@]}"; do
    ((chunk_num++))
    local gau_output="$xss_dir/gau_chunk_$chunk_num.txt"
    : > "$gau_output"
    if [[ ! -s "$chunk_file" ]]; then
      log "Chunk $chunk_num is empty, skipping..."
      send_msg "⚠️ Chunk $chunk_num is empty, skipping..."
      continue
    fi
    log "Processing XSS chunk $chunk_num/$total_chunks: $chunk_file"
    while IFS= read -r subdomain; do
      if [[ -n "$subdomain" ]]; then
        log "Running gau on $subdomain (chunk $chunk_num)"
        gau "$subdomain" > "$gau_temp" 2>/dev/null
        if [[ -s "$gau_temp" ]]; then
          log "gau completed for $subdomain (chunk $chunk_num)"
          cat "$gau_temp" >> "$gau_output"
        else
          log "gau produced empty output for $subdomain (chunk $chunk_num)"
        fi
      fi
    done < "$chunk_file"
    if [[ ! -s "$gau_output" ]]; then
      log "No URLs found for chunk $chunk_num after gau, skipping further processing"
      continue
    fi
    local gf_output="$xss_dir/gf_xss_chunk_$chunk_num.txt"
    local kxss_output="$xss_dir/kxss_chunk_$chunk_num.txt"
    local gxss_output="$xss_dir/gxss_chunk_$chunk_num.txt"
    log "Running gf xss on chunk $chunk_num"
    gf xss < "$gau_output" | sort -u > "$gf_output"
    if [[ -s "$gf_output" ]]; then
      log "Running kxss on chunk $chunk_num"
      kxss -i "$gf_output" -o "$kxss_output" 2>/dev/null
      if [[ -s "$kxss_output" ]]; then
        log "Running Gxss on chunk $chunk_num"
        Gxss -i "$kxss_output" -o "$gxss_output" 2>/dev/null
        if [[ -s "$gxss_output" ]]; then
          log "Appending Gxss results to $xss_output for chunk $chunk_num"
          cat "$gxss_output" >> "$xss_output"
        else
          log "No Gxss results for chunk $chunk_num"
        fi
      else
        log "No kxss results for chunk $chunk_num"
      fi
    else
      log "No gf xss results for chunk $chunk_num"
    fi
  done
  if [[ -s "$xss_output" ]]; then
    local total_xss=$(wc -l < "$xss_output")
    send_msg "✅ XSS hunting completed for $domain\n🕒 Time taken: ${SECONDS}s\n🔎 Total XSS findings: $total_xss\n📄 Output file: $xss_output"
    log "XSS hunting completed for $domain, $total_xss findings in $xss_output"
  else
    send_msg "❌ No XSS findings for $domain"
    log "No XSS findings for $domain"
  fi
  rm -rf "$xss_input_chunks" "$gau_temp"
}


# ------------- Main listener -------------

send_msg "🤖 ReconX Bot is live. Send /reconx -h for help."
log "ReconX Bot started"

# handle_update() {
#   local UPDATE="$1"
#   local UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
#   OFFSET=$((UPDATE_ID + 1))

#   local FROM_CHAT=$(echo "$UPDATE" | jq -r '.message.chat.id // .callback_query.from.id // empty')
#   local CALLBACK_DATA=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
#   # Only react to our configured chat
#   if [[ -n "$FROM_CHAT" && "$FROM_CHAT" != "$CHAT_ID" ]]; then
#     return
#   fi

#   local TEXT=$(echo "$UPDATE" | jq -r '.message.text // .message.caption // empty')
#   local DOC_ID=$(echo "$UPDATE" | jq -r '.message.document.file_id // empty')
#   local DOC_NAME=$(echo "$UPDATE" | jq -r '.message.document.file_name // empty')

#   # Handle callback queries from inline keyboards
#   if [[ -n "$CALLBACK_DATA" ]]; then
#     local ACTION=$(get_state_val "action")
#     case "$CALLBACK_DATA" in
#       reconx_single)
#         if [[ "$ACTION" == "wait_reconx_type" ]]; then
#           clear_wait_state
#           send_msg "📝 Please enter a single domain (e.g., example.com):"
#           set_wait_state "reconx_single_input"
#         fi
#         ;;
#       reconx_file)
#         if [[ "$ACTION" == "wait_reconx_type" ]]; then
#           clear_wait_state
#           send_msg "📥 Please send a .txt file with domains (e.g., domains.txt):"
#           set_wait_state "reconx_file_input"
#         fi
#         ;;
#       all_single)
#         if [[ "$ACTION" == "wait_all_type" ]]; then
#           clear_wait_state
#           send_msg "📝 Please enter a single domain (e.g., example.com):"
#           set_wait_state "all_single_input"
#         fi
#         ;;
#       all_file)
#         if [[ "$ACTION" == "wait_all_type" ]]; then
#           clear_wait_state
#           send_msg "📥 Please send a .txt file with domains (e.g., domains.txt):"
#           set_wait_state "all_file_input"
#         fi
#         ;;
#       cancel)
#         cancel_task
#         ;;
#     esac
#     # Answer the callback query to remove the "loading" state
#     curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" \
#       -d callback_query_id="$(echo "$UPDATE" | jq -r '.callback_query.id')" >/dev/null
#     return
#   fi

#   # Handle waiting for text response (e.g., for /all nuclei template or reconx inputs)
#   if have_wait_state && [[ -n "$TEXT" ]]; then
#     local ACTION=$(get_state_val "action")
#     if [[ "$ACTION" == "wait_nuclei_template" ]]; then
#       # Parse the response
#       local args=($TEXT)
#       local mode="" severity="" tags="" rate_limit="" threads=""
#       local i=0
#       while [[ $i -lt ${#args[@]} ]]; do
#         local arg="${args[i]}"
#         case "$arg" in
#           private|public|extra) mode="$arg" ;;
#           -s) ((i++)); severity="${args[i]}" ;;
#           -tags) ((i++)); tags="${args[i]}" ;;
#           -r) ((i++)); rate_limit="${args[i]}" ;;
#           -threads) ((i++)); threads="${args[i]}" ;;
#           /*) send_msg "⚠️ Command detected while waiting. Canceling."; log "Command detected while waiting, canceling"; clear_wait_state; return ;;
#           *) send_msg "⚠️ Invalid option: $arg. Try again."; log "Invalid option: $arg"; return ;;
#         esac
#         ((i++))
#       done

#       if [[ -z "$mode" ]]; then
#         send_msg "⚠️ Please specify private, public, or extra. Try again."
#         log "No nuclei mode specified"
#         return
#       fi

#       local alive=$(get_state_val "alive")
#       local domains=$(get_state_val "domains")
#       if [[ ! -f "$alive" || ! -s "$alive" ]]; then
#         send_msg "❌ Internal error: alive file not found or empty."
#         log "Alive file $alive not found or empty"
#         clear_wait_state
#         return
#       fi

#       clear_wait_state
#       run_nuclei "$alive" "$mode" ${severity:+-s "$severity"} ${tags:+-tags "$tags"} ${rate_limit:+-r "$rate_limit"} ${threads:+-threads "$threads"} &
#       echo $! > "$PID_FILE"
#       wait $!
#       run_xss "$alive" &
#       echo $! > "$PID_FILE"
#       wait $!
#       generate_html "$domains" "$alive"
#       return
#     elif [[ "$ACTION" == "reconx_single_input" ]]; then
#       validate_domain "$TEXT" || return
#       local jobs=$(get_state_val "jobs")
#       clear_wait_state
#       run_enum "$TEXT" "$jobs" &
#       echo $! > "$PID_FILE"
#       return
#     elif [[ "$ACTION" == "reconx_file_input" ]]; then
#       if [[ "$TEXT" != *.txt ]]; then
#         send_msg "❌ Please specify a .txt file (e.g., domains.txt)."
#         log "Invalid file input: $TEXT"
#         return
#       fi
#       local jobs=$(get_state_val "jobs")
#       clear_wait_state
#       set_wait_state "reconx" "expected=$TEXT" ${jobs:+"jobs=$jobs"}
#       send_msg "📥 Send the file '$TEXT' now. I will start enumeration as soon as I receive it."
#       log "Waiting for file $TEXT for /reconx"
#       return
#     elif [[ "$ACTION" == "all_single_input" ]]; then
#       validate_domain "$TEXT" || return
#       local jobs=$(get_state_val "jobs")
#       clear_wait_state
#       run_enum "$TEXT" "$jobs" &
#       echo $! > "$PID_FILE"
#       wait $!
#       local master_final="$BASE_DIR/$TEXT/final.txt"
#       if [[ ! -s "$master_final" ]]; then
#         send_msg "⚠️ No subdomains found, stopping /all."
#         log "No subdomains found for $TEXT, stopping /all"
#         rm -f "$PID_FILE" 2>/dev/null
#         return
#       fi
#       run_httpx "$master_final" &
#       echo $! > "$PID_FILE"
#       wait $!
#       local alive="$BASE_DIR/$TEXT/subdomains_alive.txt"
#       if [[ ! -s "$alive" ]]; then
#         send_msg "⚠️ No alive subdomains, skipping nuclei and xss."
#         log "No alive subdomains for $TEXT, stopping /all"
#         rm -f "$PID_FILE" 2>/dev/null
#         return
#       fi
#       send_msg "Which nuclei templates to use? Reply with: private, public, or extra\nOptionally add: -s critical,high -tags xss,sqli -r 100 -threads 50"
#       log "Prompting for nuclei templates for $TEXT"
#       set_wait_state "wait_nuclei_template" "alive=$alive" "domains=$TEXT"
#       return
#     elif [[ "$ACTION" == "all_file_input" ]]; then
#       if [[ "$TEXT" != *.txt ]]; then
#         send_msg "❌ Please specify a .txt file (e.g., domains.txt)."
#         log "Invalid file input: $TEXT"
#         return
#       fi
#       local jobs=$(get_state_val "jobs")
#       clear_wait_state
#       set_wait_state "all" "expected=$TEXT" ${jobs:+"jobs=$jobs"}
#       send_msg "📥 Send the file '$TEXT' now. I will start full recon as soon as I receive it."
#       log "Waiting for file $TEXT for /all"
#       return
#     fi
#   fi

#   # Handle commands
#   if [[ -n "$TEXT" ]]; then
#     if [[ "$TEXT" == "/reconx -h" ]]; then
#       send_msg "$(help_menu)"

#     elif [[ "$TEXT" == "/cancel" ]]; then
#       cancel_task

#     elif [[ "$TEXT" == "/status" ]]; then
#       check_status

#     elif [[ "$TEXT" == "/resources" ]]; then
#       local RESOURCES=$(get_resources)
#       send_msg "📊 System Resources\n$RESOURCES"
#       log "Reported resources: $RESOURCES"

#     elif [[ "$TEXT" == /reconx* ]]; then
#       local args=(${TEXT#/reconx })
#       local arg="" jobs=""
#       for ((i=0; i<${#args[@]}; i++)); do
#         case "${args[i]}" in
#           -j) jobs="${args[i+1]}"; ((i++)) ;;
#           *) if [[ -z "$arg" ]]; then arg="${args[i]}"; fi ;;
#         esac
#       done
#       if [[ -z "$arg" ]]; then
#         send_inline_keyboard "📘 Select /reconx action:" '[
#           {"text":"Single Domain","callback_data":"reconx_single"},
#           {"text":"Upload File","callback_data":"reconx_file"},
#           {"text":"Cancel","callback_data":"cancel"}
#         ]'
#         set_wait_state "wait_reconx_type" ${jobs:+"jobs=$jobs"}
#         log "Prompting for /reconx type selection"
#       elif [[ "$arg" == *.txt ]]; then
#         set_wait_state "reconx" "expected=$arg" ${jobs:+"jobs=$jobs"}
#         send_msg "📥 Send the file '$arg' now. I will start enumeration as soon as I receive it."
#         log "Waiting for file $arg for /reconx"
#       else
#         run_enum "$arg" "$jobs" &
#         echo $! > "$PID_FILE"
#       fi

#     elif [[ "$TEXT" == /httpx* ]]; then
#       local args=(${TEXT#/httpx })
#       local arg="" threads=""
#       for ((i=0; i<${#args[@]}; i++)); do
#         case "${args[i]}" in
#           -threads) threads="${args[i+1]}"; ((i++)) ;;
#           *) if [[ -z "$arg" ]]; then arg="${args[i]}"; fi ;;
#         esac
#       done
#       if [[ -z "$arg" || "$arg" != *.txt ]]; then
#         send_msg "❌ Usage: /httpx <file.txt> [-threads num]"
#         log "Invalid /httpx usage"
#       else
#         set_wait_state "httpx" "expected=$arg" ${threads:+"threads=$threads"}
#         send_msg "📥 Send the file '$arg' now. I will start httpx as soon as I receive it."
#         log "Waiting for file $arg for /httpx"
#       fi

#     elif [[ "$TEXT" == /nuclei* ]]; then
#       local args=(${TEXT#/nuclei })
#       local file="" mode="" severity="" tags="" rate_limit="" threads=""
#       for ((i=0; i<${#args[@]}; i++)); do
#         case "${args[i]}" in
#           -t) mode="${args[i+1]}"; ((i++)) ;;
#           -s) severity="${args[i+1]}"; ((i++)) ;;
#           -tags) tags="${args[i+1]}"; ((i++)) ;;
#           -r) rate_limit="${args[i+1]}"; ((i++)) ;;
#           -threads) threads="${args[i+1]}"; ((i++)) ;;
#           *) if [[ -z "$file" ]]; then file="${args[i]}"; fi ;;
#         esac
#       done
#       if [[ -z "$file" || "$file" != *.txt || -z "$mode" ]]; then
#         send_msg "❌ Usage: /nuclei urls.txt -t private|public|extra [-s severity] [-tags tags] [-r rate] [-threads num]"
#         log "Invalid /nuclei usage"
#       else
#         set_wait_state "nuclei" "expected=$file" "mode=$mode" ${severity:+"severity=$severity"} ${tags:+"tags=$tags"} ${rate_limit:+"rate_limit=$rate_limit"} ${threads:+"threads=$threads"}
#         send_msg "📥 Send the file '$file' now. I will start nuclei ($mode) when received."
#         log "Waiting for file $file for /nuclei"
#       fi

#     elif [[ "$TEXT" == /xss* ]]; then
#       read -r _cmd arg <<<"$TEXT"
#       if [[ -z "$arg" ]]; then
#         send_msg "❌ Usage:\n/xss <domain>\n/xss <file.txt>"
#         log "Invalid /xss usage"
#       elif [[ "$arg" == *.txt ]]; then
#         set_wait_state "xss" "expected=$arg"
#         send_msg "📥 Send the file '$arg' now. I will start XSS hunting as soon as I receive it."
#         log "Waiting for file $arg for /xss"
#       else
#         run_xss "$arg" &
#         echo $! > "$PID_FILE"
#       fi

#     elif [[ "$TEXT" == /all* ]]; then
#       local args=(${TEXT#/all })
#       local arg="" jobs=""
#       for ((i=0; i<${#args[@]}; i++)); do
#         case "${args[i]}" in
#           -j) jobs="${args[i+1]}"; ((i++)) ;;
#           *) if [[ -z "$arg" ]]; then arg="${args[i]}"; fi ;;
#         esac
#       done
#       if [[ -z "$arg" ]]; then
#         send_inline_keyboard "📘 Select /all action:" '[
#           {"text":"Single Domain","callback_data":"all_single"},
#           {"text":"Upload File","callback_data":"all_file"},
#           {"text":"Cancel","callback_data":"cancel"}
#         ]'
#         set_wait_state "wait_all_type" ${jobs:+"jobs=$jobs"}
#         log "Prompting for /all type selection"
#       elif [[ "$arg" == *.txt ]]; then
#         set_wait_state "all" "expected=$arg" ${jobs:+"jobs=$jobs"}
#         send_msg "📥 Send the file '$arg' now. I will start full recon as soon as I receive it."
#         log "Waiting for file $arg for /all"
#       else
#         run_enum "$arg" "$jobs" &
#         echo $! > "$PID_FILE"
#         wait $!
#         local master_final="$BASE_DIR/$arg/final.txt"
#         if [[ ! -s "$master_final" ]]; then
#           send_msg "⚠️ No subdomains found, stopping /all."
#           log "No subdomains found for $arg, stopping /all"
#           rm -f "$PID_FILE" 2>/dev/null
#           return
#         fi
#         run_httpx "$master_final" &
#         echo $! > "$PID_FILE"
#         wait $!
#         local alive="$BASE_DIR/$arg/subdomains_alive.txt"
#         if [[ ! -s "$alive" ]]; then
#           send_msg "⚠️ No alive subdomains, skipping nuclei and xss."
#           log "No alive subdomains for $arg, stopping /all"
#           rm -f "$PID_FILE" 2>/dev/null
#           return
#         fi
#         send_msg "Which nuclei templates to use? Reply with: private, public, or extra\nOptionally add: -s critical,high -tags xss,sqli -r 100 -threads 50"
#         log "Prompting for nuclei templates for $arg"
#         set_wait_state "wait_nuclei_template" "alive=$alive" "domains=$arg"
#       fi
#     fi
#   fi

#   # Handle incoming document (file upload)
#   if [[ -n "$DOC_ID" && -n "$DOC_NAME" ]]; then
#     local DOC_NAME=$(sanitize_filename "$DOC_NAME")
#     if have_wait_state; then
#       local ACTION=$(get_state_val "action")
#       if [[ "$ACTION" == "wait_nuclei_template" ]]; then
#         send_msg "⚠️ I'm waiting for your text response for nuclei templates, not a file."
#         log "Received file $DOC_NAME while waiting for nuclei template response"
#         return
#       fi
#       local EXPECTED=$(get_state_val "expected")

#       if [[ -n "$EXPECTED" && "$DOC_NAME" != "$EXPECTED" ]]; then
#         send_msg "⚠️ Received '$DOC_NAME' but I'm waiting for '$EXPECTED'. Please resend the correct file."
#         log "Received $DOC_NAME, expected $EXPECTED"
#         return
#       fi

#       local LOCAL_PATH=$(download_document "$DOC_ID" "$DOC_NAME") || {
#         send_msg "❌ Failed to download '$DOC_NAME'. Try again."
#         return
#       }

#       local SIZE=$(stat -c%s "$LOCAL_PATH" 2>/dev/null || echo 0)
#       send_msg "✅ Received '$DOC_NAME' (${SIZE} bytes). Starting $ACTION ..."
#       log "Received $DOC_NAME (${SIZE} bytes), starting $ACTION"

#       # Clear state before running job
#       local jobs=$(get_state_val "jobs")
#       local threads=$(get_state_val "threads")
#       local mode=$(get_state_val "mode")
#       local severity=$(get_state_val "severity")
#       local tags=$(get_state_val "tags")
#       local rate_limit=$(get_state_val "rate_limit")
#       clear_wait_state

#       if [[ "$ACTION" == "reconx" ]]; then
#         run_enum "$LOCAL_PATH" "$jobs" &
#         echo $! > "$PID_FILE"
#       elif [[ "$ACTION" == "httpx" ]]; then
#         run_httpx "$LOCAL_PATH" "$threads" &
#         echo $! > "$PID_FILE"
#       elif [[ "$ACTION" == "xss" ]]; then
#         run_xss "$LOCAL_PATH" &
#         echo $! > "$PID_FILE"
#       elif [[ "$ACTION" == "nuclei" ]]; then
#         run_nuclei "$LOCAL_PATH" "$mode" ${severity:+-s "$severity"} ${tags:+-tags "$tags"} ${rate_limit:+-r "$rate_limit"} ${threads:+-threads "$threads"} &
#         echo $! > "$PID_FILE"
#       elif [[ "$ACTION" == "all" ]]; then
#         run_enum "$LOCAL_PATH" "$jobs" &
#         echo $! > "$PID_FILE"
#         wait $!
#         local master_final="$BASE_DIR/master_final.txt"
#         find "$BASE_DIR" -type f -name "final.txt" -exec cat {} + 2>/dev/null | grep -v '^\[!\]' | sort -u > "$master_final"
#         if [[ ! -s "$master_final" ]]; then
#           send_msg "⚠️ No subdomains found, stopping /all."
#           log "No subdomains found in $master_final, stopping /all"
#           rm -f "$PID_FILE" 2>/dev/null
#           return
#         fi
#         run_httpx "$master_final" &
#         echo $! > "$PID_FILE"
#         wait $!
#         local alive="$BASE_DIR/subdomains_alive.txt"
#         if [[ ! -s "$alive" ]]; then
#           send_msg "⚠️ No alive subdomains, skipping nuclei and xss."
#           log "No alive subdomains in $alive, stopping /all"
#           rm -f "$PID_FILE" 2>/dev/null
#           return
#         fi
#         local domains=$(tr -d '\r' < "$LOCAL_PATH" | sed '/^$/d' | tr '\n' ' ')
#         send_msg "Which nuclei templates to use? Reply with: private, public, or extra\nOptionally add: -s critical,high -tags xss,sqli -r 100 -threads 50"
#         log "Prompting for nuclei templates after processing $LOCAL_PATH"
#         set_wait_state "wait_nuclei_template" "alive=$alive" "domains=$domains"
#       else
#         send_msg "⚠️ Unknown pending action '$ACTION'."
#         log "Unknown pending action: $ACTION"
#       fi
#     else
#       local LOCAL_PATH=$(download_document "$DOC_ID" "$DOC_NAME") || true
#       [[ -n "$LOCAL_PATH" ]] && send_msg "📎 Saved file '$DOC_NAME' to server."
#       log "Saved file $DOC_NAME to server"
#     fi
#   fi
# }

handle_update() {
  local UPDATE="$1"
  local UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
  local UPDATE_TIME=$(echo "$UPDATE" | jq '.message.date // .callback_query.message.date // 0')
  local CURRENT_TIME=$(date +%s)
  # Skip updates older than 5 minutes (300 seconds)
  if [[ $((CURRENT_TIME - UPDATE_TIME)) -gt 300 ]]; then
    log "Ignoring old update with ID $UPDATE_ID (timestamp $UPDATE_TIME)"
    return
  fi
  OFFSET=$((UPDATE_ID + 1))
  local FROM_CHAT=$(echo "$UPDATE" | jq -r '.message.chat.id // .callback_query.from.id // empty')
  local CALLBACK_DATA=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
  local TEXT=$(echo "$UPDATE" | jq -r '.message.text // .message.caption // empty')
  local DOC_ID=$(echo "$UPDATE" | jq -r '.message.document.file_id // empty')
  local DOC_NAME=$(echo "$UPDATE" | jq -r '.message.document.file_name // empty')

  # Only react to our configured chat
  if [[ -n "$FROM_CHAT" && "$FROM_CHAT" != "$CHAT_ID" ]]; then
    return
  fi

  # Check for stale state without new input
  if have_wait_state && [[ -z "$TEXT" && -z "$CALLBACK_DATA" && -z "$DOC_ID" ]]; then
    log "Ignoring stale state without new input"
    return
  fi

  # Handle callback queries from inline keyboards
  if [[ -n "$CALLBACK_DATA" ]]; then
    local ACTION=$(get_state_val "action")
    case "$CALLBACK_DATA" in
      reconx_single)
        if [[ "$ACTION" == "wait_reconx_type" ]]; then
          clear_wait_state
          send_msg "📝 Please enter a single domain (e.g., example.com):"
          set_wait_state "reconx_single_input"
        fi
        ;;
      reconx_file)
        if [[ "$ACTION" == "wait_reconx_type" ]]; then
          clear_wait_state
          send_msg "📥 Please send a .txt file with domains (e.g., domains.txt):"
          set_wait_state "reconx_file_input"
        fi
        ;;
      all_single)
        if [[ "$ACTION" == "wait_all_type" ]]; then
          clear_wait_state
          send_msg "📝 Please enter a single domain (e.g., example.com):"
          set_wait_state "all_single_input"
        fi
        ;;
      all_file)
        if [[ "$ACTION" == "wait_all_type" ]]; then
          clear_wait_state
          send_msg "📥 Please send a .txt file with domains (e.g., domains.txt):"
          set_wait_state "all_file_input"
        fi
        ;;
      cancel)
        cancel_task
        ;;
      /*)
        send_msg "⚠️ Another command detected while waiting for Nuclei template. Please respond with private, public, or extra first."
        log "Command detected while waiting for Nuclei template, prompting again"
        return
        ;;
      *)
    esac
    # Answer the callback query to remove the "loading" state
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" \
      -d callback_query_id="$(echo "$UPDATE" | jq -r '.callback_query.id')" >/dev/null
    return
  fi

  # Handle waiting for text response (e.g., for /all nuclei template or reconx inputs)
  if have_wait_state && [[ -n "$TEXT" ]]; then
    local ACTION=$(get_state_val "action")
    if [[ "$ACTION" == "wait_nuclei_template" ]]; then
      # Parse the response
      local args=($TEXT)
      local mode="" severity="" tags="" rate_limit="" threads=""
      local i=0
      while [[ $i -lt ${#args[@]} ]]; do
        local arg="${args[i]}"
        case "$arg" in
          private|public|extra) mode="$arg" ;;
          -s) ((i++)); severity="${args[i]}" ;;
          -tags) ((i++)); tags="${args[i]}" ;;
          -r) ((i++)); rate_limit="${args[i]}" ;;
          -threads) ((i++)); threads="${args[i]}" ;;
          /*) send_msg "⚠️ Command detected while waiting. Canceling."; log "Command detected while waiting, canceling"; clear_wait_state; return ;;
          *) send_msg "⚠️ Invalid option: $arg. Try again."; log "Invalid option: $arg"; return ;;
        esac
        ((i++))
      done

      if [[ -z "$mode" ]]; then
        send_msg "⚠️ Please specify private, public, or extra. Try again."
        log "No nuclei mode specified"
        return
      fi

      local alive=$(get_state_val "alive")
      local domains=$(get_state_val "domains")
      if [[ ! -f "$alive" || ! -s "$alive" ]]; then
        send_msg "❌ Internal error: alive file not found or empty."
        log "Alive file $alive not found or empty"
        clear_wait_state
        return
      fi

      clear_wait_state
      run_nuclei "$alive" "$mode" ${severity:+-s "$severity"} ${tags:+-tags "$tags"} ${rate_limit:+-r "$rate_limit"} ${threads:+-threads "$threads"} &
      echo $! > "$PID_FILE"
      wait $!
      run_xss "$alive" &
      echo $! > "$PID_FILE"
      wait $!
      generate_html "$domains" "$alive"
      return
    elif [[ "$ACTION" == "reconx_single_input" ]]; then
      validate_domain "$TEXT" || return
      local jobs=$(get_state_val "jobs")
      clear_wait_state
      run_enum "$TEXT" "$jobs" &
      echo $! > "$PID_FILE"
      return
    elif [[ "$ACTION" == "reconx_file_input" ]]; then
      if [[ "$TEXT" != *.txt ]]; then
        send_msg "❌ Please specify a .txt file (e.g., domains.txt)."
        log "Invalid file input: $TEXT"
        return
      fi
      local jobs=$(get_state_val "jobs")
      clear_wait_state
      set_wait_state "reconx" "expected=$TEXT" ${jobs:+"jobs=$jobs"}
      send_msg "📥 Send the file '$TEXT' now. I will start enumeration as soon as I receive it."
      log "Waiting for file $TEXT for /reconx"
      return
    elif [[ "$ACTION" == "all_single_input" ]]; then
      validate_domain "$TEXT" || return
      local jobs=$(get_state_val "jobs")
      clear_wait_state
      run_enum "$TEXT" "$jobs" &
      echo $! > "$PID_FILE"
      wait $!
      local master_final="$BASE_DIR/$TEXT/final.txt"
      if [[ ! -s "$master_final" ]]; then
        send_msg "⚠️ No subdomains found, stopping /all."
        log "No subdomains found for $TEXT, stopping /all"
        rm -f "$PID_FILE" 2>/dev/null
        return
      fi
      run_httpx "$master_final" &
      echo $! > "$PID_FILE"
      wait $!
      local alive="$BASE_DIR/$TEXT/subdomains_alive.txt"
      if [[ ! -s "$alive" ]]; then
        send_msg "⚠️ No alive subdomains, skipping nuclei and xss."
        log "No alive subdomains for $TEXT, stopping /all"
        rm -f "$PID_FILE" 2>/dev/null
        return
      fi
      send_msg "Which nuclei templates to use? Reply with: private, public, or extra\nOptionally add: -s critical,high -tags xss,sqli -r 100 -threads 50"
      log "Prompting for nuclei templates for $TEXT"
      set_wait_state "wait_nuclei_template" "alive=$alive" "domains=$TEXT"
      return
    elif [[ "$ACTION" == "all_file_input" ]]; then
      if [[ "$TEXT" != *.txt ]]; then
        send_msg "❌ Please specify a .txt file (e.g., domains.txt)."
        log "Invalid file input: $TEXT"
        return
      fi
      local jobs=$(get_state_val "jobs")
      clear_wait_state
      set_wait_state "all" "expected=$TEXT" ${jobs:+"jobs=$jobs"}
      send_msg "📥 Send the file '$TEXT' now. I will start full recon as soon as I receive it."
      log "Waiting for file $TEXT for /all"
      return
    fi
  fi

  # Handle commands
  if [[ -n "$TEXT" ]]; then
    if [[ "$TEXT" == "/reconx -h" ]]; then
      send_msg "$(help_menu)"

    elif [[ "$TEXT" == "/cancel" ]]; then
      cancel_task

    elif [[ "$TEXT" == "/status" ]]; then
      check_status

    elif [[ "$TEXT" == "/resources" ]]; then
      local RESOURCES=$(get_resources)
      send_msg "📊 System Resources\n$RESOURCES"
      log "Reported resources: $RESOURCES"

    elif [[ "$TEXT" == /reconx* ]]; then
      local args=(${TEXT#/reconx })
      local arg="" jobs=""
      for ((i=0; i<${#args[@]}; i++)); do
        case "${args[i]}" in
          -j) jobs="${args[i+1]}"; ((i++)) ;;
          *) if [[ -z "$arg" ]]; then arg="${args[i]}"; fi ;;
        esac
      done
      if [[ -z "$arg" ]]; then
        send_inline_keyboard "📘 Select /reconx action:" '[
          {"text":"Single Domain","callback_data":"reconx_single"},
          {"text":"Upload File","callback_data":"reconx_file"},
          {"text":"Cancel","callback_data":"cancel"}
        ]'
        set_wait_state "wait_reconx_type" ${jobs:+"jobs=$jobs"}
        log "Prompting for /reconx type selection"
      elif [[ "$arg" == *.txt ]]; then
        set_wait_state "reconx" "expected=$arg" ${jobs:+"jobs=$jobs"}
        send_msg "📥 Send the file '$arg' now. I will start enumeration as soon as I receive it."
        log "Waiting for file $arg for /reconx"
      else
        run_enum "$arg" "$jobs" &
        echo $! > "$PID_FILE"
      fi

    elif [[ "$TEXT" == /httpx* ]]; then
      local args=(${TEXT#/httpx })
      local arg="" threads=""
      for ((i=0; i<${#args[@]}; i++)); do
        case "${args[i]}" in
          -threads) threads="${args[i+1]}"; ((i++)) ;;
          *) if [[ -z "$arg" ]]; then arg="${args[i]}"; fi ;;
        esac
      done
      if [[ -z "$arg" || "$arg" != *.txt ]]; then
        send_msg "❌ Usage: /httpx <file.txt> [-threads num]"
        log "Invalid /httpx usage"
      else
        set_wait_state "httpx" "expected=$arg" ${threads:+"threads=$threads"}
        send_msg "📥 Send the file '$arg' now. I will start httpx as soon as I receive it."
        log "Waiting for file $arg for /httpx"
      fi

    elif [[ "$TEXT" == /nuclei* ]]; then
      local args=(${TEXT#/nuclei })
      local file="" mode="" severity="" tags="" rate_limit="" threads=""
      for ((i=0; i<${#args[@]}; i++)); do
        case "${args[i]}" in
          -t) mode="${args[i+1]}"; ((i++)) ;;
          -s) severity="${args[i+1]}"; ((i++)) ;;
          -tags) tags="${args[i+1]}"; ((i++)) ;;
          -r) rate_limit="${args[i+1]}"; ((i++)) ;;
          -threads) threads="${args[i+1]}"; ((i++)) ;;
          *) if [[ -z "$file" ]]; then file="${args[i]}"; fi ;;
        esac
      done
      if [[ -z "$file" || "$file" != *.txt || -z "$mode" ]]; then
        send_msg "❌ Usage: /nuclei urls.txt -t private|public|extra [-s severity] [-tags tags] [-r rate] [-threads num]"
        log "Invalid /nuclei usage"
      else
        set_wait_state "nuclei" "expected=$file" "mode=$mode" ${severity:+"severity=$severity"} ${tags:+"tags=$tags"} ${rate_limit:+"rate_limit=$rate_limit"} ${threads:+"threads=$threads"}
        send_msg "📥 Send the file '$file' now. I will start nuclei ($mode) when received."
        log "Waiting for file $file for /nuclei"
      fi

    elif [[ "$TEXT" == /xss* ]]; then
      read -r _cmd arg <<<"$TEXT"
      if [[ -z "$arg" ]]; then
        send_msg "❌ Usage:\n/xss <domain>\n/xss <file.txt>"
        log "Invalid /xss usage"
      elif [[ "$arg" == *.txt ]]; then
        set_wait_state "xss" "expected=$arg"
        send_msg "📥 Send the file '$arg' now. I will start XSS hunting as soon as I receive it."
        log "Waiting for file $arg for /xss"
      else
        run_xss "$arg" &
        echo $! > "$PID_FILE"
      fi

    elif [[ "$TEXT" == /all* ]]; then
      local args=(${TEXT#/all })
      local arg="" jobs=""
      for ((i=0; i<${#args[@]}; i++)); do
        case "${args[i]}" in
          -j) jobs="${args[i+1]}"; ((i++)) ;;
          *) if [[ -z "$arg" ]]; then arg="${args[i]}"; fi ;;
        esac
      done
      if [[ -z "$arg" ]]; then
        send_inline_keyboard "📘 Select /all action:" '[
          {"text":"Single Domain","callback_data":"all_single"},
          {"text":"Upload File","callback_data":"all_file"},
          {"text":"Cancel","callback_data":"cancel"}
        ]'
        set_wait_state "wait_all_type" ${jobs:+"jobs=$jobs"}
        log "Prompting for /all type selection"
      elif [[ "$arg" == *.txt ]]; then
        set_wait_state "all" "expected=$arg" ${jobs:+"jobs=$jobs"}
        send_msg "📥 Send the file '$arg' now. I will start full recon as soon as I receive it."
        log "Waiting for file $arg for /all"
      else
        run_enum "$arg" "$jobs" &
        echo $! > "$PID_FILE"
        wait $!
        local master_final="$BASE_DIR/$arg/final.txt"
        if [[ ! -s "$master_final" ]]; then
          send_msg "⚠️ No subdomains found, stopping /all."
          log "No subdomains found for $arg, stopping /all"
          rm -f "$PID_FILE" 2>/dev/null
          return
        fi
        run_httpx "$master_final" &
        echo $! > "$PID_FILE"
        wait $!
        local alive="$BASE_DIR/$arg/subdomains_alive.txt"
        if [[ ! -s "$alive" ]]; then
          send_msg "⚠️ No alive subdomains, skipping nuclei and xss."
          log "No alive subdomains for $arg, stopping /all"
          rm -f "$PID_FILE" 2>/dev/null
          return
        fi
        send_msg "Which nuclei templates to use? Reply with: private, public, or extra\nOptionally add: -s critical,high -tags xss,sqli -r 100 -threads 50"
        log "Prompting for nuclei templates for $arg"
        set_wait_state "wait_nuclei_template" "alive=$alive" "domains=$arg"
      fi
    fi
  fi

  # Handle incoming document (file upload)
  if [[ -n "$DOC_ID" && -n "$DOC_NAME" ]]; then
    local DOC_NAME=$(sanitize_filename "$DOC_NAME")
    if have_wait_state; then
      local ACTION=$(get_state_val "action")
      if [[ "$ACTION" == "wait_nuclei_template" ]]; then
        send_msg "⚠️ I'm waiting for your text response for nuclei templates, not a file."
        log "Received file $DOC_NAME while waiting for nuclei template response"
        return
      fi
      local EXPECTED=$(get_state_val "expected")

      if [[ -n "$EXPECTED" && "$DOC_NAME" != "$EXPECTED" ]]; then
        send_msg "⚠️ Received '$DOC_NAME' but I'm waiting for '$EXPECTED'. Please resend the correct file."
        log "Received $DOC_NAME, expected $EXPECTED"
        return
      fi

      local LOCAL_PATH=$(download_document "$DOC_ID" "$DOC_NAME") || {
        send_msg "❌ Failed to download '$DOC_NAME'. Try again."
        return
      }

      local SIZE=$(stat -c%s "$LOCAL_PATH" 2>/dev/null || echo 0)
      send_msg "✅ Received '$DOC_NAME' (${SIZE} bytes). Starting $ACTION ..."
      log "Received $DOC_NAME (${SIZE} bytes), starting $ACTION"

      # Clear state before running job
      local jobs=$(get_state_val "jobs")
      local threads=$(get_state_val "threads")
      local mode=$(get_state_val "mode")
      local severity=$(get_state_val "severity")
      local tags=$(get_state_val "tags")
      local rate_limit=$(get_state_val "rate_limit")
      clear_wait_state

      if [[ "$ACTION" == "reconx" ]]; then
        run_enum "$LOCAL_PATH" "$jobs" &
        echo $! > "$PID_FILE"
      elif [[ "$ACTION" == "httpx" ]]; then
        run_httpx "$LOCAL_PATH" "$threads" &
        echo $! > "$PID_FILE"
      elif [[ "$ACTION" == "xss" ]]; then
        run_xss "$LOCAL_PATH" &
        echo $! > "$PID_FILE"
      elif [[ "$ACTION" == "nuclei" ]]; then
        run_nuclei "$LOCAL_PATH" "$mode" ${severity:+-s "$severity"} ${tags:+-tags "$tags"} ${rate_limit:+-r "$rate_limit"} ${threads:+-threads "$threads"} &
        echo $! > "$PID_FILE"
      elif [[ "$ACTION" == "all" ]]; then
        run_enum "$LOCAL_PATH" "$jobs" &
        echo $! > "$PID_FILE"
        wait $!
        local master_final="$BASE_DIR/master_final.txt"
        find "$BASE_DIR" -type f -name "final.txt" -exec cat {} + 2>/dev/null | grep -v '^\[!\]' | sort -u > "$master_final"
        if [[ ! -s "$master_final" ]]; then
          send_msg "⚠️ No subdomains found, stopping /all."
          log "No subdomains found in $master_final, stopping /all"
          rm -f "$PID_FILE" 2>/dev/null
          return
        fi
        run_httpx "$master_final" &
        echo $! > "$PID_FILE"
        wait $!
        local alive="$BASE_DIR/subdomains_alive.txt"
        if [[ ! -s "$alive" ]]; then
          send_msg "⚠️ No alive subdomains, skipping nuclei and xss."
          log "No alive subdomains in $alive, stopping /all"
          rm -f "$PID_FILE" 2>/dev/null
          return
        fi
        local domains=$(tr -d '\r' < "$LOCAL_PATH" | sed '/^$/d' | tr '\n' ' ')
        send_msg "Which nuclei templates to use? Reply with: private, public, or extra\nOptionally add: -s critical,high -tags xss,sqli -r 100 -threads 50"
        log "Prompting for nuclei templates after processing $LOCAL_PATH"
        set_wait_state "wait_nuclei_template" "alive=$alive" "domains=$domains"
      else
        send_msg "⚠️ Unknown pending action '$ACTION'."
        log "Unknown pending action: $ACTION"
      fi
    else
      local LOCAL_PATH=$(download_document "$DOC_ID" "$DOC_NAME") || true
      [[ -n "$LOCAL_PATH" ]] && send_msg "📎 Saved file '$DOC_NAME' to server."
      log "Saved file $DOC_NAME to server"
    fi
  fi
}

while true; do
  UPDATES=$(curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$OFFSET")
  COUNT=$(echo "$UPDATES" | jq '.result | length')
  if [[ -z "$COUNT" || "$COUNT" == "0" ]]; then
    sleep 5
    continue
  fi

  for i in $(seq 0 $((COUNT-1))); do
    UPDATE=$(echo "$UPDATES" | jq ".result[$i]")
    handle_update "$UPDATE"
  done
  sleep 5
done
