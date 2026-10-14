# Splitroute

Раздельный туннель по приложениям для macOS: каждое приложение идёт в свой выход —
через уже подключённое VPN-приложение (ZoogVPN, AIRLINK…), через свой конфиг
(VLESS/Reality, Shadowsocks, Trojan, Hysteria2, WireGuard `.conf`, OpenVPN `.ovpn`, подписки),
напрямую или в блок. Например, WhatsApp — через VPN, WeChat — напрямую, одновременно.

## Как это работает

- Ядро — [sing-box](https://sing-box.sagernet.org) 1.14 в режиме TUN, запускается launchd-демоном от root.
- Правила `process_path_regex` по пути бандла приложения (вместе с его helper-процессами).
- Выход «VPN-приложение» — это `direct` с `bind_interface` на utun этого VPN; «Напрямую» — на Wi‑Fi/Ethernet.
- FakeIP: домены резолвятся внутри выбранного выхода, поэтому подмена DNS у провайдера не мешает VPN-приложениям.
- Kill switch: если VPN-приложение отключилось, его приложения блокируются, а не уходят напрямую.
- Tailscale и локальные сети не трогаются.

Apple Developer не нужен: приложение подписывается ad-hoc, системный компонент ставится один раз
с паролем администратора. Root-helper принимает только профиль (`~/Library/Application Support/Splitroute/profile.json`)
и сам собирает из него конфиг sing-box.

## Сборка и запуск

```sh
sh scripts/bundle.sh        # build/Splitroute.app (скачивает и проверяет sing-box)
open build/Splitroute.app   # «Установить» → пароль администратора
swift test                  # модель, генератор конфига (+ sing-box check), разбор ссылок
sh scripts/e2e.sh ZoogVPN   # проверка на живой системе (после установки)
```

Удаление системного компонента: `sudo /Library/PrivilegedHelperTools/com.splitroute/splitroute-helper uninstall`.

## Ограничения

- Safari и приложения на WKWebView ходят в сеть через общий системный процесс WebKit — их нельзя развести по разным выходам; они попадают в «Системные службы».
- Подключение и смену сервера в VPN-приложении делает само VPN-приложение.
