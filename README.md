# keenetic-entware-tools

Набор скриптов для Keenetic + Entware (aarch64): подготовка флэшки, первичная настройка роутера, установка nfqws2 и доставка его конфигурации.

| Скрипт | Где запускается | Что делает |
|---|---|---|
| `prepare-entware-usb.sh` | Linux-ПК | Форматирует флэшку в ext4, кладёт Entware-инсталлятор в `/install` |
| `setup-keenetic.sh` | Роутер (Entware) | SSH-ключ, пароль root, пакеты, алиасы, cron, nfqws2-keenetic |
| `deploy-nfqws2.ps1` | Windows (PowerShell) | Копирует `.\nfqws2` на роутер в `/opt/etc/nfqws2` |

> Во всех командах замени `USER/REPO` на свои. Для воспроизводимости вместо `main` можно указать хэш коммита.
> Скрипты выполняются от root: перед запуском по ссылке прочитай их.

## 1. Подготовка флэшки

Linux-машина, нужны `parted`, `e2fsprogs`, `curl` или `wget`. **Все данные на устройстве будут стёрты.**

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/prepare-entware-usb.sh)" _ /dev/sdX ENTWARE
```

Скрипт скачивает `aarch64-installer.tar.gz` до форматирования, показывает `lsblk` и требует ввести имя устройства для подтверждения. Результат: ext4-раздел с меткой `ENTWARE` и файлом `/install/aarch64-installer.tar.gz`.

## 2. Первичная настройка роутера

Заходишь на роутер по SSH и запускаешь:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/USER/REPO/main/setup-keenetic.sh)"
```

или через curl:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup-keenetic.sh)"
```

Форма `sh -c "$(...)"` нужна, чтобы stdin остался терминалом: скрипт спрашивает, менять ли пароль root, и вызывает `passwd`. Через `| sh` это не сработает.

Если HTTPS не работает (нет `wget-ssl`):

```sh
opkg update && opkg install ca-certificates wget-ssl
```

Что делает скрипт:

1. Добавляет SSH-ключ в `/opt/etc/dropbear/authorized_keys`.
2. Спрашивает, нужно ли сменить пароль root.
3. Ставит `cron nmap neovim htop`.
4. Добавляет алиасы `v='nvim'` и `ll='ls -lh'` в `~/.profile`.
5. Создаёт `/opt/etc/cron.daily/opkg-upgrade` (ежедневный `opkg upgrade`).
6. Ставит `nfqws2-keenetic` и `nfqws-keenetic-web`.

Перед использованием замени в скрипте `SSH_KEY` на свой публичный ключ.

## Структура репозитория

```
.
├── README.md
├── prepare-entware-usb.sh
├── setup-keenetic.sh
├── deploy-nfqws2.ps1
└── nfqws2/            # конфигурация nfqws2
```
