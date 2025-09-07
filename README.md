# ReconX Bot 🤖

A Telegram automation bot for **Subdomain Enumeration**, **Httpx alive check**, and **Nuclei vulnerability scanning** – all from your Telegram chat.

It runs on your VPS and sends results directly to Telegram, including ZIP archives, alive subdomains, and vulnerability reports.

---

## ✨ Features

* **Subdomain Enumeration** using:

  * [subfinder](https://github.com/projectdiscovery/subfinder)
  * [assetfinder](https://github.com/tomnomnom/assetfinder)
  * [amass](https://github.com/OWASP/Amass)
  * [alterx](https://github.com/projectdiscovery/alterx) + [dnsx](https://github.com/projectdiscovery/dnsx)
  * [crt.sh](https://crt.sh/)
  * [github-subdomains](https://github.com/gwen001/github-subdomains)
* **Httpx Alive Scan** → Find live domains with [httpx](https://github.com/projectdiscovery/httpx).
* **Nuclei Vulnerability Scan**:

  * Public templates → Default [nuclei-templates](https://github.com/projectdiscovery/nuclei-templates)
  * Private templates → Your own custom templates
* Automated ZIP reports, batching, and status updates.
* Works entirely from Telegram chat.

---

## 📦 Dependencies

Make sure these tools are installed. You can run `install.sh` (provided in repo) or install manually.

* [Go](https://go.dev/doc/install) (>=1.21)
* [subfinder](https://github.com/projectdiscovery/subfinder)
* [assetfinder](https://github.com/tomnomnom/assetfinder)
* [amass](https://github.com/OWASP/Amass)
* [alterx](https://github.com/projectdiscovery/alterx)
* [dnsx](https://github.com/projectdiscovery/dnsx)
* [httpx](https://github.com/projectdiscovery/httpx)
* [github-subdomains](https://github.com/gwen001/github-subdomains)
* [seclists](https://github.com/danielmiessler/SecLists) (for `alterx` wordlist)
* [nuclei](https://github.com/projectdiscovery/nuclei)
* Core utils: `curl`, `jq`, `zip`, `screen`

👉 Just run:

```bash
sudo bash install.sh
```

---

## ⚙️ Configuration

### 1. Telegram Bot Setup

* Create a bot with [@BotFather](https://t.me/botfather).
* Get your **BOT\_TOKEN**.
* Get your **CHAT\_ID**:

  ```bash
  curl -s "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates"
  ```

  Then send a message to your bot and check the JSON → `chat.id`.
* **If you’re using the bot in a group**, make sure the bot is added as an **admin**.

Edit `reconx.sh`:

```bash
BOT_TOKEN="YOUR TELEGRAM BOT TOKEN"
CHAT_ID="YOUR CHAT OR GROUP ID"
```

---

### 2. Nuclei Templates

* **Public templates** → Download from [nuclei-templates](https://github.com/projectdiscovery/nuclei-templates):

  ```bash
  git clone https://github.com/projectdiscovery/nuclei-templates.git
  ```

  Set in `reconx.sh`:

  ```bash
  NUCLEI_DEFAULT_TEMPLATES="/path/to/nuclei-templates"
  ```

* **Private templates** → Use your personal templates path:

  ```bash
  PRIVATE_TEMPLATES="/path/to/your/private/templates"
  ```

---

### 3. GitHub-Subdomains `.tokens`

The tool requires GitHub API tokens to work effectively.

* Create a **GitHub Personal Access Token**.
* Save it in a file:

  ```bash
  mkdir -p ~/go/bin/.tokens
  echo "YOUR_GITHUB_TOKEN" > ~/go/bin/.tokens
  ```
* The script uses it automatically:

  ```bash
  github-subdomains -d target.com -t ~/go/bin/.tokens
  ```

---

### 4. VPS Setup with Screen

Run the bot persistently in background:

```bash
sudo apt update && sudo apt install screen -y
screen -S reconx
bash reconx.sh
```

Detach from screen with:

```
CTRL+A+D
```

Reattach later:

```bash
screen -r reconx
```

---

## 🚀 Usage from Telegram

Available commands:

```
📘 ReconX Bot Help

/reconx <domain>        Run enumeration for a single domain
/reconx <file.txt>      Bot waits for file upload, then runs enum for all domains in it
/httpx <file.txt>       Waits for file upload, runs httpx-toolkit
/nuclei urls.txt -t private   Run nuclei with private templates
/nuclei urls.txt -t public    Run nuclei with public templates
/reconx -h              Show help menu
```

---

## 📊 Example Workflow

1. Run subdomain enum for single domain:

   ```
   /reconx example.com
   ```

   → Bot runs all tools and sends a ZIP + report.

2. Run httpx:

   ```
   /httpx final.txt
   ```

   → Bot will **wait** for you to upload `final.txt`.
   → After upload, it scans and replies with alive domains + report.

3. Run nuclei:

   ```
   /nuclei urls.txt -t public
   ```

   → Bot will **wait** for you to upload `urls.txt`.
   → After upload, it splits results, sends progress updates, and finally sends vuln reports.

---

## 🛠️ Contributing

Contributions are welcome! 🚀

* Fork this repo
* Make your changes
* Submit a PR

---

## 👨‍💻 Contributors

* **[AIwolfie](https://github.com/AIwolfie)** – Author & Maintainer
* **[BAPPAYNE](https://github.com/BAPPAYNE)** – Contributor


