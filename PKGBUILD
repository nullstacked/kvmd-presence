# Maintainer: nullstacked <nullstacked@users.noreply.github.com>
pkgname=kvmd-presence
pkgver=1.0.0
pkgrel=1
pkgdesc="User presence overlay for PiKVM - shows who is watching/controlling"
arch=('any')
url="https://github.com/nullstacked/kvmd-plugins"
license=('GPL3')
depends=('kvmd')
install=kvmd-presence.install
source=()
md5sums=()

package() {
    # Install presence module
    install -Dm644 "$srcdir/../files/presence.py" "$pkgdir/usr/share/kvmd-presence/presence.py"

    # Install patch apply script
    install -Dm755 "$srcdir/../files/apply-patches.sh" "$pkgdir/usr/share/kvmd-presence/apply-patches.sh"

    # Install CSS
    install -Dm644 "$srcdir/../files/presence.css" "$pkgdir/usr/share/kvmd-presence/presence.css"

    # Install ALPM hook
    install -Dm644 "$srcdir/../kvmd-presence.hook" "$pkgdir/etc/pacman.d/hooks/kvmd-presence.hook"
}
