# keenetic-entware-tools

Набор скриптов для Keenetic + Entware (aarch64): подготовка флэшки, первичная настройка роутера, установка nfqws2, доставка его конфигурации и загрузка списков доменов для маршрутизации через VPN.

| Скрипт | Где запускается | Что делает |
|---|---|---|
| `prepare-entware-usb.sh` | Linux-ПК | Форматирует флэшку в ext4, кладёт Entware-инсталлятор в `/install` |
| `setup-entware.sh` | Роутер (Entware) | SSH-ключ, пароль root, пакеты, алиасы, cron, nfqws2-keenetic |
| `deploy-nfqws2.ps1` | Windows (PowerShell) | Копирует `.\nfqws2` на роутер в `/opt/etc/nfqws2` |
| `add-domain-lists.ps1` | Windows (PowerShell) | Загружает списки из `.\domain-lists` в `object-group fqdn` роутера и назначает маршрут через VPN |

> Для воспроизводимости вместо `refs/heads/main` в ссылке можно указать хэш коммита.
> Скрипты выполняются от root: перед запуском по ссылке прочитай их.

## 1. Подготовка флэшки

Linux-машина, нужны `parted`, `e2fsprogs`, `curl` или `wget`. **Все данные на устройстве будут стёрты.**

```bash
sudo bash -c "$(curl -fsSL https://github.com/mishgun64/keenetic-entware-tools/raw/refs/heads/main/prepare-entware-usb.sh)" _ /dev/sdX ENTWARE
```

Скрипт скачивает `aarch64-installer.tar.gz` до форматирования, показывает `lsblk` и требует ввести имя устройства для подтверждения. Результат: ext4-раздел с меткой `ENTWARE` и файлом `/install/aarch64-installer.tar.gz`.

## 2. Первичная настройка роутера

Заходишь на роутер по SSH, ставишь curl и запускаешь:

```sh
opkg update && opkg install curl
sh -c "$(curl -fsSL https://github.com/mishgun64/keenetic-entware-tools/raw/refs/heads/main/setup-entware.sh)"
```

Форма `sh -c "$(...)"` нужна, чтобы stdin остался терминалом: скрипт спрашивает, менять ли пароль root, и вызывает `passwd`. Через `| sh` это не сработает.

Что делает скрипт:

1. Добавляет SSH-ключ в `/opt/etc/dropbear/authorized_keys`.
2. Спрашивает, нужно ли сменить пароль root.
3. Ставит `cron nmap neovim htop`.
4. Добавляет алиасы `v='nvim'` и `ll='ls -lh'` в `~/.profile`.
5. Создаёт `/opt/etc/cron.daily/opkg-upgrade` (ежедневный `opkg upgrade`).
6. Ставит `nfqws2-keenetic` и `nfqws-keenetic-web`.

Перед использованием замени в скрипте `SSH_KEY` на свой публичный ключ.

## 3. Списки доменов для маршрутизации через VPN

`add-domain-lists.ps1` берёт файлы `*.txt` из папки `domain-lists` и создаёт по ним группы объектов `object-group fqdn` на роутере Keenetic, затем назначает DNS-маршрутизацию этих групп через выбранный VPN-интерфейс. Работает через HTTP API роутера (RCI), SSH не нужен. Требуется PowerShell 5.1+ и доступ к веб-интерфейсу роутера с ПК.

Запуск без скачивания файла (из папки, в которой лежит `domain-lists`):

```powershell
& ([scriptblock]::Create((irm https://github.com/mishgun64/keenetic-entware-tools/raw/refs/heads/main/add-domain-lists.ps1)))
```

Скрипт, выполняемый из памяти, не блокируется политикой выполнения PowerShell. Так как у него нет собственного пути, папка `domain-lists` ищется в текущем каталоге. При обычном запуске файла (`.\add-domain-lists.ps1`) она ищется рядом со скриптом.

Что спрашивает скрипт:

1. Роутер из списка (`192.168.47.1` … `192.168.51.1`) или IP вручную.
2. Логин (по умолчанию `admin`) и пароль.
3. VPN-интерфейс, например `Wireguard2`. Если оставить пустым, маршруты не назначаются, создаются только группы.

Формат файлов в `domain-lists`:

- одна запись на строку: домен, IPv4/IPv6-адрес или подсеть в формате CIDR (`149.154.164.0/22`);
- `#` начинает комментарий, пустые строки и дубликаты игнорируются, префикс `*.` отбрасывается;
- имя файла становится описанием группы (`music.txt` → `description music`), суффикс `_ipv4` / `_ipv6` отбрасывается (`telegram_ipv4.txt` → `telegram`).

Поведение:

- Группа называется `domain-listN` (первый свободный номер). Если на роутере уже есть группа с таким описанием, она дополняется, а не создаётся заново, поэтому повторный запуск безопасен.
- Скрипт только добавляет записи. Удалённые из файла домены на роутере остаются.
- Маршрут назначается командой `dns-proxy route object-group domain-listN <интерфейс> auto`.
- При первой же ошибке роутера скрипт останавливается без сохранения конфигурации. В конце выполняется `system configuration save`.

## Структура репозитория

```
.
├── README.md
├── prepare-entware-usb.sh
├── setup-entware.sh
├── deploy-nfqws2.ps1
├── add-domain-lists.ps1
├── domain-lists/      # списки доменов и подсетей (*.txt)
└── nfqws2/            # конфигурация nfqws2
```
