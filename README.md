# Mesa 26.3.0 for crux (SM8150 / Adreno 640)

Built: 2026-11-19T00:16:26+08:00
Source: /root/mesa-26.3.0 (official tarball from archive.mesa3d.org)

## Build config
```
gallium-drivers = freedreno
vulkan-drivers  = freedreno  (Turnip)
platforms       = wayland,x11
glx             = dri
egl/gbm/glvnd   = enabled
buildtype       = release
```

## Artifacts
```
539768	/root/mesa-26.3.0/build/src/egl/libEGL_mesa.so.0.0.0
16758048	/root/mesa-26.3.0/build/src/freedreno/vulkan/libvulkan_freedreno.so
25513048	/root/mesa-26.3.0/build/src/gallium/targets/dri/libgallium-26.3.0.so
497864	/root/mesa-26.3.0/build/src/glx/libGLX_mesa.so.0.0.0
```

## Dependency workarounds needed
1. wayland-scanner 1.24 cannot parse wayland-protocols 1.49 XML (DTD validation)
   -> built wayland 1.26.0 from source to /usr/local
2. wayland-protocols 1.47 too old (mesa 26.3.0 needs >=1.49)
   -> built wayland-protocols 1.49 from source to /usr/local
3. Missing dev packages: glslang-tools, libwayland-egl-backend-dev,
   libxcb-glx0-dev, libxxf86vm-dev, libxcb-keysyms1-dev
