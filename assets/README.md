# assets/vendor — 第三方库（离线内置）

这个目录里的文件都是从官方渠道下载的**原版**构建产物，没有改动一个字节。之所以放进仓库而不是用 CDN：仪表盘服务的是本机控制台，外链依赖会让它在没网、被代理拦、或者 CDN 挂掉的时候变成半个页面；内置之后 `web-ui.html` 引用的东西全都在本机，行为可复现。

| 文件 | 来源 | 版本 | 许可证 |
| --- | --- | --- | --- |
| `motion.min.js` | `npm/motion@10.18.0/dist/motion.umd.min.js`（Motion One，jsDelivr） | 10.18.0 | MIT |
| `lucide.min.js` | `npm/lucide@0.469.0/dist/umd/lucide.min.js`（jsDelivr） | 0.469.0 | ISC |
| `inter-var.woff2` | `@fontsource/inter` 可变字体，latin 子集（jsDelivr） | 随上游 | OFL-1.1 |
| `jetbrains-mono-var.woff2` | `@fontsource/jetbrains-mono` 可变字体，latin 子集（jsDelivr） | 随上游 | OFL-1.1 |

中文字形不在这里：`Noto Sans SC` 之类的完整中文字体动辄数 MB，为一个本机页面拖一个几 MB 的字体不划算。CSS 的 `--font-sans` 在 Inter 之后接着系统的 `PingFang SC / Microsoft YaHei / Noto Sans SC`，中日韩字形用系统的，拉丁文和数字用 Inter——混排时视觉上仍然是一套。

## 更新到新版本

`web-ui.ps1` 用一张白名单表把 `/assets/` 下的路径映射成 MIME 类型，只允许下面这四个文件名（见 `Handle-Request` 里的 `$script:StaticFiles`）。换版本时保持文件名不变即可；如果改了名，记得同步那张表：

```powershell
curl -L -o assets/vendor/motion.min.js  https://cdn.jsdelivr.net/npm/motion@10.18.0/dist/motion.umd.min.js
curl -L -o assets/vendor/lucide.min.js  https://cdn.jsdelivr.net/npm/lucide@0.469.0/dist/umd/lucide.min.js
```

换完重跑 `tests/smoke-webui.ps1`：它会断言页面真的引用了这些文件、图标库真的被用到、动效库真的被调用。

## 这些文件是怎么被送出去的

`web-ui.ps1` 只认这张表里的四个名字：`GET /assets/vendor/<文件名>` 才通，其他方法 405；不在表里的路径、带 `..` 的路径、`config.json`、不存在的路径、目录，一律 404；每个响应都不缓存（`no-store`）。断言这些用的是**裸 socket**（`Invoke-Raw`）而不是 `HttpWebRequest`——`Uri` 类会在客户端把 `..` 折掉，那样测到的是客户端，不是服务端。页面少了哪个文件也不要紧：图标和动效都有兜底，页面会安静退化，不会半张脸。
