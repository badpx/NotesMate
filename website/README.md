# NotesMate 产品官网

线上地址：<https://badpx.github.io/NotesMate/>。托管于 GitHub Pages，由 `.github/workflows/pages.yml` 发布。

## 内容与维护

- `index.template.html`、`style.css`、`site.js` 是官网源文件，无第三方运行时、字体服务或统计脚本。
- `Website.*` 文案集中于 App 已有的 15 个 `NotesMate/Localization/*.lproj/Localizable.strings` 目录；构建会检查语言与模板键完整性，不允许漏译后回退英文。
- 英文位于根路径，其他语言有独立目录、页面语言、标题、描述、canonical 和 hreflang；语言选择器切换静态页面。内容与下载在禁用 JavaScript 时仍可用。
- 中英文浅色／深色预览直接复用 `docs/design/` 最新设计稿：中文浅色 v3，其余 v2。页面裁切显示编辑窗口，标注为设计预览。更换设计图时，更新构建脚本中的素材映射；窗口几何变化时同步调整 CSS 裁切参数。
- 图标复用 Icon Composer 的 `note.svg` 图层和渐变色；小尺寸 favicon 复用现有 PNG。
- 工作流在相关源码合入 main、Release 变更或手动触发时重建。线上构建从 GitHub API 读取最新正式 Release 的 DMG；失败会中止部署，不会用过期版本替换网站。Release 事件始终检出 main，避免旧版本标签覆盖官网源码。
- `release.json` 是本地离线预览快照（v1.3）；线上构建用最新 API 数据覆盖输入。不要把 API token 写入该文件。

## 本地预览

```bash
python3 scripts/build-website.py --base ''
python3 -m http.server 8000 --directory build/website
```

打开 `http://localhost:8000/` 或 `http://localhost:8000/zh-Hans/`。默认构建参数为实际项目站点路径 `/NotesMate`；输出位于已忽略的 `build/website`。

维护检查：运行构建确认 15 种语言完整；运行 `bash scripts/test-editor.sh --filter EditorLanguageTests`（当前 Swift 6.4 的默认构建引擎在本机无法初始化时，可加 `--build-system native`）；检查桌面和手机布局、语言跳转、浅深色预览、FAQ 展开、键盘焦点，以及下载链接指向当前 Release 的 DMG。
