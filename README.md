# My-UI
s-ui-local-installer

一键安装指令
```
sudo bash -c 'if ! command -v curl >/dev/null; then apt-get update && apt-get install -y curl || exit 1; fi; bash <(curl -fsSL "https://raw.githubusercontent.com/yihangliu612/My-UI/main/install-s-ui-local-amd64.sh")'
```
