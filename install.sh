#!/bin/sh
# SPDX-License-Identifier: MIT
# OpenWrt LuCI theme selector, by TMN88.
# shellcheck disable=SC1091,SC2154
set -eu

die() { printf '\nОшибка: %s\n' "$*" >&2; exit 1; }
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 20 --max-time 180 -o "$2" "$1"
    else
        wget -O "$2" "$1"
    fi
}
installed() {
    if [ "$PM" = apk ]; then
        apk info -e "$1" >/dev/null 2>&1
    else
        opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'
    fi
}
install_file() {
    if [ "$PM" = apk ]; then
        apk add --allow-untrusted "$1"
    else
        opkg install "$1"
    fi
}
release_package() {
    # Match only the main universal package, never translations/config/debug packages.
    rp_name=$1
    if [ "$PM" = apk ]; then
        rp_pattern="/${rp_name}-[0-9][^/]*\\.apk$"
    else
        rp_pattern="/${rp_name}_[0-9][^/]*_all\\.ipk$"
    fi
    rp_url=$(jsonfilter -i "$WORK/release.json" -e '@.assets[*].browser_download_url' |
        grep -E "$rp_pattern" || true)
    [ -n "$rp_url" ] || die "В последнем релизе нет пакета $rp_name для $PM."
    [ "$(printf '%s\n' "$rp_url" | wc -l)" -eq 1 ] || die "В релизе несколько пакетов $rp_name; автоматический выбор отменён."
    case "$rp_url" in
        "https://github.com/$REPO/releases/download/"*) ;;
        *) die 'Неожиданный адрес пакета.' ;;
    esac
    rp_path="$WORK/${rp_url##*/}"
    fetch "$rp_url" "$rp_path" || die 'Не удалось скачать пакет. Проверьте интернет, DNS и дату роутера.'
    [ -s "$rp_path" ] || die 'Скачан пустой файл.'
    # GitHub supplies SHA256 digests for newer release assets. Check when present.
    rp_digest=$(jsonfilter -i "$WORK/release.json" -e "@.assets[@.browser_download_url=\"$rp_url\"].digest" 2>/dev/null || true)
    case "$rp_digest" in
        sha256:*)
            printf '%s  %s\n' "${rp_digest#sha256:}" "$rp_path" | sha256sum -c - || die 'SHA256 пакета не совпадает.' ;;
        '') printf 'У релиза нет SHA256 в API GitHub; пакет получен по HTTPS.\n' ;;
        *) die 'Неизвестный формат контрольной суммы.' ;;
    esac
    install_file "$rp_path" || die "Не удалось установить $rp_name. См. сообщение менеджера пакетов выше."
}

[ "$(id -u)" -eq 0 ] || die 'Запустите скрипт от root.'
[ -f /etc/openwrt_release ] || die 'Этот скрипт предназначен для OpenWrt.'
. /etc/openwrt_release
case "${DISTRIB_RELEASE:-}" in
    24.10*|25.12*) ;;
    *) die "Поддерживаются OpenWrt 24.10 и 25.12. Обнаружено: ${DISTRIB_RELEASE:-неизвестно}." ;;
esac
command -v uci >/dev/null 2>&1 || die 'Не найден UCI.'
[ -f /etc/config/luci ] || die 'LuCI не установлен.'
if command -v apk >/dev/null 2>&1; then PM=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg
else die 'Не найден apk или opkg.'; fi

printf '\nУстановка тем LuCI | %s | %s\n' "${DISTRIB_DESCRIPTION:-OpenWrt}" "$PM"
printf '1) Footstrap\n2) Argon\n3) Aurora\n0) Выход\nВыберите тему [0-3]: '
IFS= read -r choice || exit 0
case "$choice" in
    1) THEME=footstrap; REPO=VizzleTF/luci-theme-footstrap ;;
    2) THEME=argon; REPO=jerrykuku/luci-theme-argon ;;
    3) THEME=aurora; REPO=eamonxg/luci-theme-aurora ;;
    0) exit 0 ;;
    *) die 'Введите 0, 1, 2 или 3.' ;;
esac
if [ "$THEME" = footstrap ]; then
    case "$DISTRIB_RELEASE" in
        24.10.0|24.10.1|24.10.2) die 'Актуальному Footstrap требуется OpenWrt 24.10.3 или новее.' ;;
    esac
fi
PACKAGE="luci-theme-$THEME"
OLD_THEME=$(uci -q get luci.main.mediaurlbase || true)
WORK=$(mktemp -d /tmp/openwrt-themes.XXXXXX) || die 'Не удалось создать временный каталог.'
SUCCESS=0
cleanup() {
    if [ "$SUCCESS" -ne 1 ]; then
        if [ -n "$OLD_THEME" ]; then
            uci set "luci.main.mediaurlbase=$OLD_THEME" && uci commit luci || true
        else
            uci -q delete luci.main.mediaurlbase || true
            uci commit luci || true
        fi
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
BACKUP="/etc/luci-theme-backup-$(date +%Y%m%d-%H%M%S)-$$.conf"
cp -p /etc/config/luci "$BACKUP" || die 'Не удалось сохранить настройки LuCI.'

if installed "$PACKAGE"; then
    printf '\n%s уже установлен — переключаю оформление.\n' "$PACKAGE"
else
    printf '\nОбновление индексов пакетов...\n'
    "$PM" update || die 'Не удалось обновить индексы. Проверьте доступность репозиториев.'
    if ! command -v jsonfilter >/dev/null 2>&1; then
        if [ "$PM" = apk ]; then apk add jsonfilter; else opkg install jsonfilter; fi
    fi
    command -v jsonfilter >/dev/null 2>&1 || die 'Не удалось установить jsonfilter.'
    command -v sha256sum >/dev/null 2>&1 || die 'Не найден sha256sum.'
    printf 'Источник: https://github.com/%s/releases/latest\n' "$REPO"
    fetch "https://api.github.com/repos/$REPO/releases/latest" "$WORK/release.json" || die 'Не удалось прочитать релиз GitHub (возможен лимит API).'
    # Argon 3 integrates the old config app. Use the official migration package first.
    if [ "$THEME" = argon ] && installed luci-app-argon-config; then
        release_package luci-app-argon-config
    fi
    release_package "$PACKAGE"
fi
installed "$PACKAGE" || die 'Менеджер пакетов не подтвердил установку темы.'
[ -d "/www/luci-static/$THEME" ] || die 'Файлы оформления не найдены; прежняя тема будет восстановлена.'
uci set "luci.main.mediaurlbase=/luci-static/$THEME"
uci commit luci
SUCCESS=1
printf '\nГотово! Тема: %s\nРезервная копия LuCI: %s\nОбновите страницу LuCI через Ctrl+F5. Перезагрузка роутера не нужна.\n' "$THEME" "$BACKUP"
printf 'Вернуть прежнюю тему: '
if [ -n "$OLD_THEME" ]; then
    printf "uci set 'luci.main.mediaurlbase=%s' && uci commit luci\n" "$OLD_THEME"
else
    printf 'выберите оформление в Система → Система → Язык и стиль.\n'
fi
