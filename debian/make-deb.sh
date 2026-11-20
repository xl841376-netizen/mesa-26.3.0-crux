#!/bin/bash
# 把 meson DESTDIR 安装出的 stage 树打成 .deb
# 用法: make-deb.sh <mesa-src-dir> <output-dir>
set -euo pipefail

SRC="${1:?usage: make-deb.sh <mesa-src-dir> <out-dir>}"
OUT="${2:?usage: make-deb.sh <mesa-src-dir> <out-dir>}"
STAGE="$SRC/stage"

if [ ! -d "$STAGE" ]; then
  echo "ERROR: stage dir not found: $STAGE" >&2
  exit 1
fi

PKG=mesa-freedreno-crux
VER=26.3.0
ARCH=arm64
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/DEBIAN"
cp -a "$STAGE/." "$ROOT/"

# 只保留我们关心的 freedreno 相关产物，避免与系统 mesa 包冲突。
# 系统包仍持有其它 arch/驱动文件；本包只覆盖 freedreno + GLX + EGL + gbm + Turnip。
KEEP_PATTERNS=(
  'usr/lib/aarch64-linux-gnu/libgallium-26.3.0.so'
  'usr/lib/aarch64-linux-gnu/libGLX_mesa.so.0.0.0'
  'usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0.0.0'
  'usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so'
  'usr/lib/aarch64-linux-gnu/libgbm.so.1.0.0'
  'usr/lib/aarch64-linux-gnu/dri/msm_dri.so'
  'usr/lib/aarch64-linux-gnu/dri/kgsl_dri.so'
  'usr/share/vulkan/icd.d/freedreno_icd.aarch64.json'
  'usr/share/vulkan/icd.d/freedreno_icd.json'
)

# 关闭 nullglob 影响，用 find 逐个匹配
TMPKEEP="$ROOT/.keep"
: > "$TMPKEEP"
for p in "${KEEP_PATTERNS[@]}"; do
  if [ -e "$ROOT/$p" ] || [ -L "$ROOT/$p" ]; then
    echo "$p" >> "$TMPKEEP"
  fi
done

# 补齐 libGLX_mesa / libEGL_mesa / libgbm 的 soname 符号链接
add_symlink() {
  local target="$1" link="$2"
  if [ -e "$ROOT/$target" ] && [ ! -e "$ROOT/$link" ]; then
    mkdir -p "$(dirname "$ROOT/$link")"
    ln -s "$(basename "$target")" "$ROOT/$link"
    echo "$link" >> "$TMPKEEP"
  fi
}
add_symlink usr/lib/aarch64-linux-gnu/libGLX_mesa.so.0.0.0 usr/lib/aarch64-linux-gnu/libGLX_mesa.so.0
add_symlink usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0.0.0 usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0
add_symlink usr/lib/aarch64-linux-gnu/libgbm.so.1.0.0      usr/lib/aarch64-linux-gnu/libgbm.so.1

# 删除未列入白名单的文件
find "$ROOT" -mindepth 1 -maxdepth 1 -name DEBIAN -prune -o -type f -print -o -type l -print | \
while read -r f; do
  rel="${f#"$ROOT"/}"
  if ! grep -qxF "$rel" "$TMPKEEP"; then
    rm -f "$f"
  fi
done

# 清掉空目录（务必保留 DEBIAN，它此时还是空的，后面才写 control）
find "$ROOT" -mindepth 1 -type d -empty -not -path "$ROOT/DEBIAN" -delete 2>/dev/null || true
rm -f "$TMPKEEP"

mkdir -p "$ROOT/DEBIAN"

SIZE_KB=$(du -sk "$ROOT" | cut -f1)

cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VER-1
Architecture: $ARCH
Maintainer: xl841376-netizen <xl841376-netizen@users.noreply.github.com>
Installed-Size: $SIZE_KB
Section: libs
Priority: optional
Depends: libc6, libdrm2, libexpat1, zlib1g, libzstd1, libudev1, libelf1, libwayland-client0, libwayland-server0, libwayland-egl1, libx11-6, libx11-xcb1, libxcb1, libxcb-dri2-0, libxcb-dri3-0, libxcb-present0, libxcb-sync1, libxcb-shm0, libxcb-glx0, libxcb-randr0, libxshmfence1, libxext6, libxfixes3, libxdamage1, libglvnd0, libgl1, libegl1, libglx0, libvulkan1
Recommends: libgl1-mesa-dri
Conflicts: mesa-libgallium
Replaces: mesa-libgallium
Provides: mesa-libgallium (= $VER)
Description: Mesa $VER for Qualcomm Adreno (freedreno GL + Turnip) - crux SM8150
 Mesa $VER built from the official tarball with:
   gallium-drivers = freedreno
   vulkan-drivers  = freedreno (Turnip)
   platforms       = wayland,x11
   glx             = dri
 .
 This package ships only the freedreno/Turnip/GLX/EGL/GBM artifacts, so it can
 be installed alongside the distro's mesa packages without replacing the
 other drivers.
EOF

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ -x /usr/bin/glxinfo ] || [ -x /usr/bin/eglinfo ]; then
  echo "mesa-freedreno-crux installed. Verify with: glxinfo -B | head -20"
fi
exit 0
EOF
chmod 755 "$ROOT/DEBIAN/postinst"

mkdir -p "$OUT"
DEB="$OUT/${PKG}_${VER}-1_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$ROOT" "$DEB"
echo "Built: $DEB"
dpkg-deb --info "$DEB"
