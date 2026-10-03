# Stargate for Mac · 完整代理应用设计预览

Status: Design prototype. 尚未实现 macOS 系统代理、钥匙串、真实核心管理、TUN 或签名安装包。

直接用浏览器打开 `index.html` 即可，所有资源均在本目录，不需要联网或安装前端依赖。侧栏可以切换概览、节点、分流规则、远程访问、连接、诊断和设置。

支持独立启停上网代理与远控、节点选择与展示信息编辑、导入前脱敏确认、删除确认、规则匹配、本地入口增删改、连接筛选、深浅色、菜单栏预览和示例诊断导出。新增节点不会自动选择或接管系统代理；删除当前节点需先切换到另一个节点。开通链接的「同时添加普通节点」默认不勾选。

连接记录随模式和本地入口变化更新；规则匹配优先保护本地域名，其余用户域名按最长后缀匹配。未匹配的真实目标仍需解析，表格里的流量与基础策略是示例。

```sh
# macOS，在这个目录执行
open index.html
```

浏览器中的「已启动」「可访问」和流量均为示例数据，操作仅改变页面内存，刷新会重置。原型不会连接设备、兑换开通码、改系统代理、保存密码或读取 `.local/secure/`。在导入对话框点击「填入示例」体验流程。

| 文件 | 内容 |
| --- | --- |
| `index.html` | 无需构建的预览入口 |
| `styles.css` | macOS 风格、深浅色、窄屏适配 |
| `app.js` | 示例数据和交互，无运行后端 |
| `DESIGN.md` | 产品范围、架构、恢复机制、实现阶段与验收 |
| `verify.cjs` | 浏览器交互、隔离边界与布局回归 |
| `package.json` / `package-lock.json` | 仅验证所需的固定版本开发依赖 |

真实凭据与个人发布包留在仓库根目录的 `.local/`，不包含在本预览中。浏览器打开即可使用；不需要原生 Mac 后端。

## 键盘操作

- Cmd/Ctrl+1…7 切换页面，Cmd/Ctrl+I 导入节点；在远程访问页导入开通链接。
- Tab / Shift+Tab 移动焦点，Enter / Space 操作按钮，Esc 取消对话框。
- 远控页签使用左右方向键、Home / End 切换；模式与开关重绘后保留焦点。

## 验证

统一默认检查 `sh manage.sh check` 包含原型脚本语法检查，不会下载浏览器或依赖。完整浏览器回归需要 Node.js 20+，首次在仓库根目录安装：

```sh
npm --prefix tools/macos-preview ci
cd tools/macos-preview
npx playwright install chromium
cd ../..
sh manage.sh check macos-preview
```

已有 Playwright 时可以直接指定模块绝对路径，避免重复安装：

```sh
STARGATE_PLAYWRIGHT="$PWD/.local/browser/node_modules/playwright" sh manage.sh check macos-preview
```

截图默认写入 `.local/macos-app/screenshots/`；可通过 `STARGATE_SCREENSHOTS` 改目录。测试检查七页桌面与窄屏布局、独立启停、导入预览/取消/非法链接、节点编辑与删除、端口冲突、入口删除、模式同步、内网保护、键盘焦点和导出内容，并确认页面未发起 HTTP 请求。

Mac 原生进程、系统代理恢复、Keychain、TUN、签名和公证仍需后续实现及真机验收，浏览器回归不覆盖这些能力。
