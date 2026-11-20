#!/bin/bash
# 把 meson DESTDIR 安装出的 stage 树打成 .deb
# 用法: make-deb.sh <mesa-src-dir> <output-dir>
#
# 设计要点：**白名单驱动复制**，不是全量拷贝再删除。
# 理由：meson 的 DESTDIR 树里除了 Mesa 自身产物，还会混进子项目（libarchive、
# wayland-protocols 等）安装的文件。如果先全量 cp 再按黑名单删，一旦过滤逻辑
# 有偏差就会把 bsdtar / libarchive.so / 44 个无关 DRI 驱动一起打进包，覆盖系统文件。
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

# meson prefix 不同会导致 lib 落在 usr/lib 或 usr/local/lib。
# CI 用 --prefix=/usr --libdir=lib/aarch64-linux-gnu；本地默认 /usr/local。
# 自动探测，然后把路径统一规范化成 Debian 标准位置 usr/lib/aarch64-linux-gnu。
STAGE_LIB=""
for cand in "usr/lib/aarch64-linux-gnu" "usr/local/lib/aarch64-linux-gnu" "usr/lib" "usr/local/lib"; do
  if [ -d "$STAGE/$cand" ]; then
    STAGE_LIB="$cand"
    break
  fi
done
if [ -z "$STAGE_LIB" ]; then
  echo "ERROR: cannot locate libdir under $STAGE" >&2
  exit 1
fi
echo "Detected stage libdir: $STAGE_LIB"

# 目标内统一安装到 Debian 标准位置
LIBDIR=usr/lib/aarch64-linux-gnu
STAGE_SHARE=""
for cand in "usr/share" "usr/local/share"; do
  if [ -d "$STAGE/$cand" ]; then
    STAGE_SHARE="$cand"
    break
  fi
done
echo "Detected stage sharedir: ${STAGE_SHARE:-<none>}"

mkdir -p "$ROOT/DEBIAN"

# ---- 白名单：只这些文件进包（相对 stage 的路径） ----
KEEP=(
  # 核心库
  "$STAGE_LIB/libgallium-$VER.so"
  "$STAGE_LIB/libGLX_mesa.so.0.0.0"
  "$STAGE_LIB/libEGL_mesa.so.0.0.0"
  "$STAGE_LIB/libgbm.so.1.0.0"
  "$STAGE_LIB/libvulkan_freedreno.so"
  # freedreno 的 DRI 驱动（GL 用 msm，老内核路径用 kgsl）
  "$STAGE_LIB/dri/msm_dri.so"
  "$STAGE_LIB/dri/kgsl_dri.so"
  # gbm 后端（选 dri 后端时加载）
  "$STAGE_LIB/gbm/dri_gbm.so"
  # Turnip 的 Vulkan ICD 描述
  "${STAGE_SHARE:-usr/share}/vulkan/icd.d/freedreno_icd.aarch64.json"
  "${STAGE_SHARE:-usr/share}/vulkan/icd.d/freedreno_icd.json"
  # glvnd 的 EGL vendor 描述
  "${STAGE_SHARE:-usr/share}/glvnd/egl_vendor.d/50_mesa.json"
  # drirc 调优（freedreno/msm/turnip）
  "${STAGE_SHARE:-usr/share}/drirc.d/00-mesa-defaults.conf"
  "${STAGE_SHARE:-usr/share}/drirc.d/00-msm-defaults.conf"
  "${STAGE_SHARE:-usr/share}/drirc.d/00-turnip-defaults.conf"
)

# 把 stage 内的路径重写成包内的标准路径
normalize() {
  local p="$1"
  p="${p/#$STAGE_LIB/$LIBDIR}"
  p="${p/#usr\/local\/share/usr/share}"
  echo "$p"
}


# ---- 需要额外生成的 soname 符号链接 ----
# 值格式: "<target> <link>"
LINKS=(
  "$LIBDIR/libGLX_mesa.so.0.0.0 $LIBDIR/libGLX_mesa.so.0"
  "$LIBDIR/libEGL_mesa.so.0.0.0 $LIBDIR/libEGL_mesa.so.0"
  "$LIBDIR/libgbm.so.1.0.0 $LIBDIR/libgbm.so.1"
)

copied=0
for rel in "${KEEP[@]}"; do
  src="$STAGE/$rel"
  if [ -e "$src" ] || [ -L "$src" ]; then
    dst="$ROOT/$(normalize "$rel")"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    copied=$((copied+1))
  else
    echo "WARN: missing in stage: $rel"
  fi
done

for pair in "${LINKS[@]}"; do
  tgt="${pair%% *}"
  lnk="${pair##* }"
  if [ -e "$ROOT/$tgt" ] && [ ! -e "$ROOT/$lnk" ]; then
    mkdir -p "$(dirname "$ROOT/$lnk")"
    ln -s "$(basename "$tgt")" "$ROOT/$lnk"
  fi
done

echo "Copied $copied whitelisted files"
if [ "$copied" -lt 5 ]; then
  echo "ERROR: too few files copied, stage tree looks wrong" >&2
  exit 1
fi

# ---- 安全闸：黑名单关键词，出现即中止 ----
BAD=$(find "$ROOT" -type f \( -name 'bsdtar' -o -name 'bsdcat' -o -name 'bsdcpio' \
        -o -name 'libarchive*' -o -name '*.pc' -o -name '*.h' \) 2>/dev/null || true)
if [ -n "$BAD" ]; then
  echo "ERROR: forbidden files leaked into package:" >&2
  echo "$BAD" >&2
  exit 1
fi

# DRI 目录只允许 msm/kgsl/libdril，其余一律拒绝
EXTRA_DRI=$(find "$ROOT/$LIBDIR/dri" -type f -o -type l 2>/dev/null | \
            grep -vE '/(msm_dri|kgsl_dri|libdril_dri)\.so$' || true)
if [ -n "$EXTRA_DRI" ]; then
  echo "ERROR: unexpected DRI drivers in package:" >&2
  echo "$EXTRA_DRI" >&2
  exit 1
fi

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
if [ -x /usr/bin/ldconfig ]; then ldconfig; fi
exit 0
EOF
chmod 755 "$ROOT/DEBIAN/postinst"

mkdir -p "$OUT"
DEB="$OUT/${PKG}_${VER}-1_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$ROOT" "$DEB"
echo "Built: $DEB"
dpkg-deb --info "$DEB"
