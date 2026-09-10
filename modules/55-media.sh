#!/usr/bin/env bash
# meta: name=media
# meta: desc=the media and document tools yazi previews with
# meta: profiles=full
# meta: os=any
# meta: needs=
# meta: root=yes
#
# SPEC §5.5. This is yazi's PREVIEW STACK, not a desktop layer: every one of
# these is a command-line converter that yazi shells out to in order to render a
# thumbnail in the terminal, and each is independently useful on a server
# (ffmpeg for a capture, pdftotext for a report, 7z for a vendor archive).
# `yazi` itself is installed by 10-shell.
#
# SPEC-ADDENDUM §1b: nothing here pulls an X server, a compositor or a GUI
# viewer. imagemagick's CLI has no display dependency; `resvg` is a static Rust
# binary. That is why this module survived the desktop removal and 60-desktop
# did not.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# Present on all four targets.
MEDIA_PKGS=(
  ffmpeg
  imagemagick
  poppler-utils # pdftotext / pdftoppm — yazi's PDF preview
  exiftool      # `libimage-exiftool-perl` provides it; see below
)

module_main() {
  if ! have_root; then
    skip "installing media packages needs root, and none is available here"
  fi

  pkg_install "${MEDIA_PKGS[@]}" || log_warn "some media packages could not be installed"

  # Debian and Ubuntu disagree about the name: `exiftool` is a real package on
  # trixie and noble, `libimage-exiftool-perl` everywhere. pkg_install drops a
  # name with no candidate silently, so ask for the Perl package by name too.
  have exiftool || pkg_install_optional libimage-exiftool-perl

  # SPEC §5.5: absent from half the targets — SKIP it, never build it. resvg is
  # what yazi uses to preview an SVG; without it the preview is simply blank.
  pkg_install_optional resvg

  # `7zip` is the modern package (7zz); `p7zip-full` is the old one (7z). Either
  # satisfies yazi's archive preview, and pkg_install_first takes whichever the
  # archive actually has.
  pkg_install_first 7zip p7zip-full || log_warn "no 7-zip implementation is available here"

  log_info "yazi previews: images (imagemagick), video (ffmpeg), pdf (poppler),"
  log_info "  svg (resvg, when packaged) and archives (7z)"
  return 0
}

module_main "$@"
