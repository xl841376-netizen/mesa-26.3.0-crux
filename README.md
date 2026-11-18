# Mesa 26.3.0 for crux (SM8150 / Adreno 640)

Qualcomm Adreno 640（freedreno GL + Turnip Vulkan）的 Mesa 26.3.0 构建配置，目标系统是跑 mainline Linux 的 Xiaomi Mi 9 Pro 5G（代号 crux）。

## 为什么要自己编

crux 跑的是 `7.3.0-rc5-crux73` 内核。自编的 Mesa 27.0.0-devel 有三个问题：

1. **`glx = disabled`（编译时漏了）** —— `libGLX_mesa` 根本不存在，`sddm` greeter 报 `Could not initialize GLX`，没有图形登录界面
2. **`platforms = wayland`（没带 x11）** —— GLX 的前提条件不满足
3. 27.0.0 只有 devel 快照，没有正式 release

官方最新正式版是 **26.3.0**。Turnip 跟随 Mesa 版本发布，没有独立版本号。

## 构建配置

```meson
-Dgallium-drivers=freedreno
-Dvulkan-drivers=freedreno    # Turnip
-Dplatforms=wayland,x11       # x11 是 GLX 的前提
-Dglx=dri
-Degl=enabled -Dgbm=enabled -Dglvnd=enabled
-Dbuildtype=release
```

## 云端构建（GitHub Actions，A+B 方案）

`.github/workflows/build.yml` 在 `ubuntu-24.04-arm`（ARM64 native runner）上跑：

1. 装构建依赖
2. 必要时从源码编译 **wayland 1.26.0**（提供新版 `wayland-scanner`）
3. 必要时从源码编译 **wayland-protocols 1.49**
4. 下载官方 `mesa-26.3.0.tar.xz` 编译
5. **A**: `DESTDIR` 装到 stage 树
6. **B**: `debian/make-deb.sh` 打成 `.deb`

触发：仓库 Actions 页面手动 `Run workflow`，或推送到 `main` 且改动 `workflow`/`debian` 目录。

产物（Actions → Artifacts，保留 90 天）：
- `mesa-26.3.0-crux-deb` —— `dpkg -i` 直接装
- `mesa-26.3.0-stage-tree` —— 关键 `.so` 原件，便于手工替换

## 依赖踩坑记录（本地构建实测）

| 问题 | 原因 | 解法 |
|---|---|---|
| `glslangValidator` not found | 未装 GLSL 编译器（Turnip 用） | `apt install glslang-tools` |
| `wayland-egl-backend` not found | 缺开发包 | `apt install libwayland-egl-backend-dev` |
| `xcb-glx` / `xxf86vm` not found | 缺 X11 开发库 | `libxcb-glx0-dev`、`libxxf86vm-dev` 等 |
| **wayland-scanner 1.24 无法解析 1.49 协议** | 1.49 的 `linux-buffer-params` 新增 `set_sampling_device`，旧 scanner DTD 校验失败 | 源码编译 wayland 1.26.0 到 `/usr/local` |
| wayland-protocols 系统只有 1.47 | mesa 26.3.0 要求 `>= 1.49` | 源码编译 1.49 到 `/usr/local` |

> 把 meson.build 的版本要求从 1.49 降到 1.47 **不可行**——代码真调用了 `zwp_linux_buffer_params_v1_set_sampling_device`，编译直接失败。

## 部署注意（重要，本地实测踩过）

**不能只替换几个 `.so`**。本地只换 4 个库后重启 sddm：

```
Xorg 加载 glamoregl → 调用 Mesa EGL/GL → Segmentation fault at address 0x1
```

原因：`libglamoregl.so` 与系统其它 Mesa 组件（`libglapi`、glvnd、`libgbm`）版本不匹配。

**正确做法**：用本仓库产出的 `.deb` 整体安装。包内 `Conflicts/Replaces: mesa-libgallium` 保证替换关系明确。

## 产物清单（26.3.0 arm64 本地实测）

| 文件 | 大小 | 说明 |
|---|---|---|
| `libgallium-26.3.0.so` | 25,513,048 B | GL 驱动核心 |
| `libvulkan_freedreno.so` | 16,758,048 B | Turnip |
| `libGLX_mesa.so.0.0.0` | 497,864 B | GLX（27 缺的正是这个） |
| `libEGL_mesa.so.0.0.0` | 539,768 B | EGL |

## 许可

Mesa 本体 MIT。本仓库只含构建配置与打包脚本，不含 Mesa 源码（由 CI 从 `archive.mesa3d.org` 下载）。
