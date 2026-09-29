## v2.0.6

### Changelog

* The one-handed side panel was silently off on Android. The mount predicate had drifted into two spellings, and a cleanup consolidated it onto the desktop umbrella flag, which is false on a phone -- so the panel could never mount on a real device: the ring dial / arc / line scrubbers fell back to the plain circle slider, the panel docked bottom-centre instead of by the phone's own horizontal position, and the slider-type dialog began covering the very control it edits. The gate now covers every platform IRIS ships, and a test seam pins the supported-platform decision in a test rather than in a comment
* The legacy control bar and the More menu read the one-handed mode as "a side panel is on screen" although that bar renders a full-width linear bar, so the overlay hid it sideways (a full-width box shifted by one panel width stays on screen), squared off its corners, and reported a side panel to the sub-audio align editor; the slider-type dialog squeezed itself into a 240px strip that avoided nothing. Both now ask a layout-level authority instead of re-deriving the answer
* Four independent defects in the side panel's drag limits, hide translation and anchor persistence: on a window smaller than the fixed panel floor the drag threw `ArgumentError` (not only in debug); the sub-audio quick column is magnetically attached outside the panel, so a horizontal hide stranded it on screen; the panel box is widened past the drag width by the dial floor, which the hide translation never applied; and the position was persisted without its paired handedness, so a hard restart kept the position and silently reverted the ring mirroring
* A centred panel shrinks both free strips at once, so a panel dragged towards the window edge handed the settings card an unreadable sliver that still covered the control it edits. Below a usable strip the card now takes the full safe screen; the boundary is pinned exactly so the constant cannot drift into a rounding band
* The settings card's drag base was a `useState` seed that only ever got clamped, so a 9-grid re-anchor made the next header drag snap it back -- 76px on an 800px window. It now uses the position actually drawn
* With the legacy control bar active, a vertical position of top/middle parked the bar against the top edge while its hide slid it down, dragging a full-width bar across the whole video on every hide and publishing a top-of-screen rect to the playlist dock
* The side-panel settings dialog reserved a strip for a panel that might not exist, ignored where the panel really is on desktop, and never rebuilt when the desktop 9-grid anchor changed. It now asks the same anchor authority the overlay aligns with, and budgets the sub-audio quick strip off the bar's real layout zone instead of the raw window width
* Every label in the side-panel card named its subject but not its effect: the corner-hide row never said it picks the slide-out direction when the panel auto-hides, the bar-position knob had no 0%/100% semantics, and the scrubber knobs borrowed the other design's vocabulary. Longer copy overflowed the 380px card by 165px in English; the pickers now size to their field, which protects any long translation
* A phone has its own corner-hide direction and its own entry. It was previously in force on a phone with no way to change it, and shared with the desktop, so a desktop choice could reach a phone through settings transfer and leave the panel sliding in a direction the phone could not undo
* A rapid fast-forward / rewind burst painted nothing but the last target: mpv keeps only the newest seek target while one is in flight, so the fixed 120ms cadence let each new request supersede the one still decoding (41 presses, about half landing, `+3+6+9+12` showing only 12). Seeking is now a chain that keeps one engine seek in flight and issues the next only after the previous target was observed landing, holds a landed frame long enough to be visible, and drops the oldest pending target when a held key outpaces the painter. Measured 216 presses -> 206 issued -> 205 landed, 95% of presses painted; lighter content paints 5-6 steps/s and drops nothing
* A held or continuously re-tapped step stopped advancing altogether: the burst had switched mpv to inexact seek, which lands on the keyframe *before* the target, so the picture played a moment at the new spot and then jumped back and re-showed the previous GOP. Every step now lands on the position it asked for
* Stopping after a burst no longer re-seeks a position that had already landed, which cost an extra decoder discontinuity at exactly the moment the user let go
* A whole-state `AppState` subscription is not an inert read -- any mutation re-ran the consuming widget. The controls overlay sat over the entire video with one, dragging the title bar and control bar along on every write, including the per-frame transient-rate write a speed-gesture drag makes, for a field the overlay renders nowhere. Narrowed across the overlay, the circle panel, the gesture overlay, the OSD, the ring-dial style control and the legacy dialog; a test now fails if any widget takes a whole-state AppState subscription again
* The sub-audio feature gate was read bare in two places and its host is `const` in the player Stack, so switching legacy storage off left a still-draggable, still-tappable card on screen. Both now take their own composite subscription, matching every other gate reader
* The bar title's `[cur/total]` prefix and the play-queue total were read as bare getters. In search mode the published state is a synthetic single item, so the total exists only on a notifier -- a search or filter moving the total between 1 and N left the title frozen while the control bar had already moved. Both now subscribe
* The storages page could render a completely blank list even though the local disk had been enumerated and persisted. Three independent causes: the display merge cancelled every matched disk out (a scanned entry and its persisted twin share both the generated id and the volume id, so a disk present in both lists produced zero tiles); the discovery died on hook init, where any inherited-widget lookup asserts; and it could write before the store had loaded, so the write was dropped and then overwritten
* Local-disk discovery and persistence lived only in the list widget, which the page bypasses whenever a storage is restored from the previous session -- so after the first run the discovery never executed again and no local storage was generated. It now runs from the popup root, deduplicated, idempotent, retried once after a failed run, and matching against both the database and the live store so a disk is never re-added as a duplicate
* A refused local read was indistinguishable from an empty directory: the listing swallowed the filesystem exception, and Android scoped storage hides an unreadable directory without throwing at all. A denial is now classified as a permission problem with its own message, drops the cached permission state so the grant surface appears, and reloads once granted -- instead of showing "no items found". The Android probes are bounded by a timeout and degrade to internal storage on any error, so an unresponsive channel can never turn into an empty list
* The release repository moved to a new account, so the address compiled into published builds began answering with a rename redirect before it ever named a tag -- and the update check read that hop as an unreadable release page, turning every check into a visible failure. The check now asks the moved probe in turn, bounded to three hops, so a build that predates the rename resolves through the redirect GitHub already left behind. A sign-in challenge and the repository root still fail loudly
* The one-handed slider type is no longer dropped when settings move between a desktop and a phone: the transfer policy classified it as phone-only, but it also drives the desktop one-handed side panel
* Virtual-media segment wording is now "own segment" throughout
* Removed two dead More-menu entries that were computed and never read, along with the store subscription only they needed

### 更新日志

* 单手侧边面板在 Android 上一直是关闭的。挂载判定此前已经漂移成两种写法，某次清理又把它统一到了「桌面」这个总开关上——而手机不是桌面宿主，于是真机上永远挂不上：环形 / 弧形 / 直线三种单手进度条退回普通圆盘滑块，面板不再按手机的横向位置停靠而是贴底居中，滑块样式对话框开始盖住它自己要编辑的控件。现在该判定覆盖 IRIS 实际发布的全部平台，并把这个平台判定写进测试而不是注释
* 传统控制栏和更多菜单把「单手模式」直接读成「屏幕上有侧栏」，可那条栏其实渲染的是整幅宽度的线性栏：于是覆盖层把它往侧面收（整宽的框平移一个栏宽仍在屏内）、把圆角切成侧栏样式、并向副音对齐编辑器报告「是侧栏」；滑块样式对话框则把自己挤进 240px 的一条窄缝，避让的对象并不存在。两处现在都改问一个「布局层」的判定，不再各自重新推导
* 侧边面板的拖拽边界、隐藏位移和位置持久化存在四个独立缺陷：窗口小于面板固定下限时拖拽会抛 `ArgumentError`（不只是 debug）；副音快捷列是磁吸在面板外侧的，横向隐藏后会滞留在屏幕上；面板框会因为表盘下限而比拖拽宽度更宽，隐藏位移从未套用这个更宽的尺寸；位置被持久化时没有连同配对的左右手性一起存，硬重启后位置还在、环形镜像却悄悄退回
* 居中面板会同时收窄左右两条可用边，把面板拖向窗口边缘时设置卡片会拿到一条读不了、却仍然盖住它要编辑的控件的碎条。低于可用宽度时卡片现在改用整块安全区域；边界值被精确钉住，常量不会漂进某个舍入区间
* 设置卡片的拖拽基线取自一个只被夹紧过的 `useState` 种子值，所以九宫格重新定位后，下一次拖标题栏会把它弹回原处——800px 窗口上实测 76px。现在用的是真正画出来的位置
* 传统控制栏激活时，纵向位置为上／中会把栏停在屏幕顶边，而隐藏时又向下滑，整幅宽度的栏每次隐藏都横穿整个视频，还会向播放列表坞发布一个屏幕顶部的矩形
* 侧栏设置对话框为一个可能并不存在的面板预留边距，桌面上忽略了面板的真实位置，而且九宫格锚点变化后不会重建。现在它问的是覆盖层对齐所用的同一个锚点判定，副音快捷条也改为按控制栏真实的布局区（而非窗口原始宽度）来分配
* 侧栏卡片里每一行文案都只说了对象、没说效果：角落隐藏行从没说它决定的是自动隐藏时的滑出方向，栏位置旋钮没有 0%／100% 的语义，两个滑块旋钮还借用了另一种设计的词汇。更长的文案在英文下超出 380px 卡片 165px；现在三个选择器都按输入框宽度定尺寸，这对任何更长的翻译同样有效
* 手机有了自己的角落隐藏方向和自己的入口。此前它在手机上一直生效却无处可改，且与桌面共用一项，于是通过设置同步传过去的桌面选择会让手机面板朝一个手机自己无法撤销的方向滑出
* 快速连按快进／快退只画出最后一个目标：mpv 在一次 seek 进行中只保留最新的目标，固定 120ms 的节流让每个新请求都顶掉仍在解码的那个（41 次按键约半数落地，`+3+6+9+12` 只显示 12）。现在 seek 是一条链：同时只有一次引擎 seek 在飞，上一个目标被观测到落地后才发出下一个，落地的画面会停留足够长的时间让人看见，按住不放超过绘制速度时丢弃最旧的待处理目标。实测 216 次按键 → 发出 206 → 落地 205，95% 的按键被画出；内容较轻时可画出 5–6 步/秒且不丢弃
* 按住或连续重按的步进曾完全不再前进：连按会把 mpv 切到非精确 seek，而它落在目标之前的关键帧上，于是画面在新位置闪一下就跳回去、重新播放上一个 GOP。现在每一步都落在它请求的位置上
* 连按后松手不再重新 seek 已经落地的位置——那会在用户恰好停下的瞬间多付一次解码器中断
* 对整个 `AppState` 的订阅不是惰性读取：任何一次变更都会重跑消费它的控件。控制覆盖层就压在整幅视频之上，带着一个这样的订阅，于是每次写入都拖着标题栏和控制栏一起重建——包括倍速手势拖动时每帧写入的临时速率，而这个字段覆盖层根本不渲染。现已把覆盖层、圆盘面板、手势覆盖层、OSD、环形表盘样式控件和传统对话框逐个收窄；并新增测试，任何控件再次对整个 AppState 订阅都会失败
* 副音功能开关有两处是裸读取，而它的宿主在播放器 Stack 里是 `const` 的，祖先重建不会重跑它的 build：关掉传统存储后，屏幕上会留下一张仍可拖动、仍可点击的卡片。两处现在都各自持有组合订阅，与其它所有开关读取方一致
* 标题栏的 `[cur/total]` 前缀和播放队列总数是按裸 getter 读取的。搜索模式下发布出去的状态是合成的单条，总数只存在于一个通知器上——搜索或筛选让总数在 1 和 N 之间变化时，标题栏会冻住不动，而控制栏早已更新。两处现在都改为订阅
* 存储页面可能整片空白，尽管本地磁盘已经被枚举并持久化。背后有三个独立原因：展示层的合并把每一个匹配上的磁盘都抵消掉了（扫描到的条目与它持久化的孪生条目同时共享生成的 id 和卷 id，于是一个同时存在于两份列表里的磁盘产出零块磁贴）；发现流程在 hook 初始化时崩溃，因为那里任何 InheritedWidget 查询都会断言；以及它可能在 store 加载完成前就写入，于是写入被丢弃、随后又被覆盖
* 本地磁盘的发现与持久化只存在于列表组件里，而只要有存储从上次会话恢复，页面就会完全绕开它——于是首次运行之后发现流程再也不执行，永远不会生成任何本地存储。现在它从弹窗根节点运行，去重、幂等、失败后重试一次，并同时比对数据库与实时 store，磁盘不会被重复添加
* 被拒绝的本地读取与空目录无法区分：列目录吞掉了文件系统异常，而 Android 分区存储会把读不了的目录藏起来、根本不抛错。现在权限拒绝会被归类为权限问题并给出专门文案，同时丢弃缓存的权限状态以便授权入口出现，授权后自动重载——而不是显示「没有找到项目」。Android 探测带超时上限且任何错误都退化为内部存储，一个无响应的通道再也不会变成一份空列表
* 发布仓库迁到了新账号，因此已发布版本里编译进去的地址在给出 tag 之前会先返回一个改名重定向——而更新检查把这一跳读成了「发行页无法读取」，于是每次检查都变成一次可见的失败。现在检查会接着询问被重定向到的探测，最多三跳，因此在改名之前发布的版本也能顺着 GitHub 已经留下的重定向正常解析。登录挑战和仓库根目录仍然会明确报错
* 设置在桌面与手机之间同步时不再丢掉单手滑块类型：传输策略把它判为仅手机，但桌面单手侧栏同样由它驱动
* 虚拟媒体的片段文案统一改为「自有片段」
* 移除了更多菜单里两个算了却从未被读取的死条目，以及只有它们才需要的 store 订阅

## v2.0.5

### Changelog

* In-app update check against the public release repository, run manually from the About page: the newest tag is read without spending API quota, the package is chosen for the running build (ABI-specific on Android, ZIP for the portable Windows edition, installer otherwise), verified against the published byte count and `SHA256SUMS.txt` before anything is launched, and an abandoned or cancelled transfer is deleted instead of left behind
* Update failures say what actually happened: a refused, throttled or broken host is no longer reported as "you are up to date", and a network refusal, a timeout, an unreadable release page, a missing package, a wrong size, a bad digest and a full disk each get their own advice
* The update row is hidden where it cannot work: a Microsoft Store package and any platform the updater cannot serve no longer offer a dead end
* Remote storage connections: one connect-retry loop shared by the tile tap and the scan preflight, so a retry is no longer swallowed by the lock the previous attempt still held; a slow connect shows a progress surface that names the host being tried and can be abandoned at any point
* Recursive scan: a wildcard WebDAV root that lists empty is re-resolved once, and a host that still cannot be reached is reported as unreachable rather than as an empty directory, so a scan can no longer purge a storage's snapshot
* Player bar `[cur/total]`: the position is published through a shared signal with per-context ownership, so a scenario list tap, an external feed (history, browser, open file/link, share intent), a sub-audio roll and a resume all show the position of what is actually playing

### 更新日志

* 应用内更新检查：关于页手动检查公仓 release，不消耗 API 配额；按当前构建选择安装包（安卓按 ABI、便携版选 ZIP、安装版选安装器），启动前按发布字节数与 `SHA256SUMS.txt` 校验，被放弃或取消的下载会被删除而不是留在本地
* 更新失败会如实说明：被拒绝、被限流或 GitHub 故障不再被报成「已是最新」；网络不通、超时、发布页不可读、没有可用安装包、大小不符、校验不符、磁盘空间不足各有对应的处理建议
* 更新入口在无法工作的地方隐藏：微软商店版以及更新器不支持的平台不再给出死路
* 远程存储连接：列表点击与扫描前置共用同一个「连接—重试」循环，重试不再被上一次尝试持有的锁吞掉；慢连接会显示进度界面，标出正在尝试的主机，并可随时放弃
* 递归扫描：通配符 WebDAV 根目录列空后会重解析一次，仍无法连上的主机报为不可达而不是空目录，扫描不会再因此清空存储快照
* 播放栏 `[cur/total]`：位置改为带逐上下文归属的共享信号，场景列表点击、外部片单（历史、浏览器、打开文件/链接、分享意图）、副音跳转与断点恢复都显示真正在播的那一项

## v2.0.4

### Changelog

* Scenario play queue gains selectable layouts: a compact V2 single row, plus a V3 floating grid pinned to two rows, with per-screen-shape defaults that are remembered per shape
* Page-jump dialog: first / last page shortcuts, a narrower form that parks out of the way on phones, and a smaller go-to-current crosshair in every layout
* Browser page sizes read back from disk are clamped, so a stale or hand-edited value can no longer produce an unusable page
* A sort-menu tap no longer dismisses the page it belongs to (play queue, scenario preview, settings), and the chosen order field is what gets marked instead of the rule that was captured
* Settings no longer get lost after the 2.0.3 regressions: keyboard-form geometry persists through the canonical shell, and AUX domains are rehydrated after snapshot round-trips, with the `form.` domain carried through settings export / import

### 更新日志

* 场景播放队列新增可选布局：紧凑的 V2 单行，以及固定为两行的 V3 悬浮网格；每种屏幕形态有各自的默认值并按形态记忆
* 跳页对话框：新增首页 / 末页快捷按钮，手机上表单更窄并可停靠收起，各布局下的「定位当前」十字都缩小了
* 浏览器读取磁盘上的分页大小时做钳制，陈旧或被手改的值不会再产生不可用的页码
* 点击排序菜单不再把所在页面一起关掉（播放队列、场景预览、设置），并且标记的是所选排序字段而不是捕获到的规则
* 修复 2.0.3 带来的设置丢失回归：键盘表单几何通过统一外壳持久化，AUX 域在快照往返后重新水合，设置导入导出也会带上 `form.` 域

## v2.0.3

### Changelog

* Desktop control bar rebuilt around adaptive layout kinds (button row, overflow slots) with a floating control-group switch, only one control group shown at a time, and the left/right button grouping restored
* Scan reliability: a finished scan always converges so it can no longer block playback; storage-root rows become playable after a scan; subfolder-base storages get a root scan-done stamp; absolute-form root phantoms are healed; `getRootNode` reads only the storage-root container
* Scenario playback: the queue refreshes after scans, the scan gate is hardened, and only a single scan-completion dialog is surfaced
* Scenario queue ordering: the modified-date order is now flat, precise and stable, backed by millisecond timestamps (schema v46, new migration)
* Player exit goes through one durable `AppExit` path
* Defaults and polish: the fresh-install side scrubber uses the ring dial, the preset pills share one size and the wheel is dropped on desktop, and the About / known-issues texts are clearer

### 更新日志

* 桌面控制栏按自适应布局类型重构（按钮行 / 溢出槽位），新增悬浮控制组切换；同一时间只显示一个控制组，并恢复左右按键分组
* 扫描可靠性：扫描结束必定收敛，不再阻塞播放；扫描后存储根行可直接播放；子文件夹作为根时补上根扫描完成标记；修复绝对路径形式的根幻影；`getRootNode` 只读取存储根容器
* 场景播放：扫描后刷新队列、加固扫描闸门，并且只弹一次扫描完成对话框
* 场景队列排序：修改时间排序改为扁平、精确、稳定，底层改用毫秒时间戳（schema v46，新增迁移）
* 播放器退出统一走一条可靠的 `AppExit` 路径
* 默认值与打磨：全新安装的侧边拖动默认使用圆环表盘；预设药丸统一尺寸、桌面端去掉滚轮；关于页 / 已知问题文案更准确

## v2.0.2

### Changelog

* Playback-speed picker overhaul: `rateMode` now switches the picker content between slider, scrub, ruler and card, all three pickers live in one draggable card, plus a compact big-digit dual-wheel dial with a decimal point, uniform preset chips, and a speed entry in the More menu when the bar has no rate button
* Storage passwords: rows whose password cannot be decrypted are no longer degraded or rewritten; a locked-password dialog explains the state, and the storage popup closes only after playback actually starts
* Database migrations: failures are rethrown instead of stamping the schema version, so a broken migration can never be silently marked as applied
* Tag play: member paths resolve against relative `media_nodes` rows, and the pin-preset name survives widget rebuilds
* Playback tools: the frame-tools panel remembers its position as a fraction of the viewport

### 更新日志

* 播放速度选择器重做：`rateMode` 现在切换的是同一按钮的选择器内容——滑杆 / 拖动 / 刻度尺 / 卡片，三种选择器整合进一张可拖拽卡片，并新增带小数点的双轮大数字表盘、预设芯片对齐统一；控制栏没有倍速按钮时在「更多」里补上入口
* 存储密码：无法解密的行不再被降级或改写，新增「密码已锁定」说明弹窗；存储弹窗只在真正开始播放后才关闭
* 数据库迁移：失败改为抛出异常而不是写入版本号，避免损坏的迁移被静默标记为已完成
* 标签播放：成员路径改为按相对 `media_nodes` 行解析；固定预设名称在组件重建后不再丢失
* 播放工具：逐帧工具面板以视口比例记住位置

## v2.0.1

### Changelog

* Secondary-audio source manager staged into the play queue: built-in rule guards, source-pool invalidation on confirm, clearer idle-state guidance
* One-handed button bar rebalanced and given a draggable position knob
* Phone-portrait bottom-bar alignment settings; the floating switch button is now split by orientation
* Metadata-driven dual-wheel playback speed picker
* Media library: folder quick-adds for the audio source list and the virtual-media merge editor
* Scenario playback re-resolves after definitions are edited from Manage / Browse
* Screenshot and frame-step fixes: reject unwritable folders, probe the picked directory, prefer the longest storage base, localise failure messages, clamp the panel on resize
* Keep the minimal progress bar on the foreground while sub-audio control is active, and clamp the sub-audio seek buffer to the slider bounds

### 更新日志

* 副音源管理器分阶段接入播放队列：内置规则保护、确认后失效源池、空闲状态提示更明确
* 单手按钮栏重新配平，并新增可拖拽的位置旋钮
* 手机竖屏底栏对齐设置；悬浮开关按钮按横竖屏拆分显示
* 元数据驱动的双轮播放速度选择器
* 媒体库：音频源列表与虚拟媒体合并编辑器支持文件夹快捷添加
* 场景播放：从管理/浏览页修改定义后重新解析播放
* 截图与逐帧修复：拒绝不可写目录、探测所选文件夹、优先取最长存储根、失败提示本地化、缩放时面板限位
* 副音控制期间前台保留极简进度条，副音 seek 缓冲限制在滑块范围内

## v2.0.0

### Changelog

* Second-development release on top of upstream IRIS
* Metadata-driven settings engine (database-persisted, importable/exportable)
* Scenario playback: named, reusable play plans (override / append / batch)
* Virtual media rules and merged playback
* Tag virtual collections with a numeric command syntax
* Secondary-audio synchronized playback (second track + A-P-B time mapping)
* MediaDb library (recursive/resumable scan, path tree, standalone search)
* PotPlayer desktop key scheme, custom keybinds, A-B loop
* Desktop context menu, side playlist, keyboard OSD
* WebDAV wildcard-host auto-discovery
* Screenshot / frame-step / open-with, settings import-export with password audit
* Windows portable edition with a one-click ZIP updater
* Versioned release artifact file names

### 更新日志

* 基于上游 IRIS 的二次开发版本
* 元数据驱动的设置引擎（数据库持久化，可导入导出）
* 场景播放：命名可复用的播放计划（覆盖 / 追加 / 批量生成）
* 虚拟媒体规则与合并播放
* Tag 虚拟合集与数字命令语法
* 副音同步播放（第二轨 + A-P-B 时间映射）
* MediaDb 媒体库（递归/断点续扫、路径树、独立搜索）
* PotPlayer 桌面键位方案、可自定义键位、A-B 区段循环
* 桌面右键菜单、侧边播放列表、键盘 OSD
* WebDAV 通配符主机自动发现
* 截图 / 逐帧 / 打开方式、设置导入导出与密码审计
* Windows 便携版与一键 ZIP 更新脚本
* 发布产物文件名带版本号

## v1.5.2

### Changelog

* Migrate to MPL-2.0 license
* Add more media type support
* Fix key open subtitle and audio track issue
* Fix popup layer cannot be closed with `Esc` key issue

### 更新日志

* 迁移到 MPL-2.0 许可证
* 添加更多媒体类型支持
* 修复按键打开字幕和音频轨道的问题
* 修复弹出层无法使用 `Esc` 键关闭的问题

## v1.5.1

### Changelog

* Adjusted the playback control bar style in compact layout
* Clicking “Check update” in the Microsoft Store version redirects to the Store page
* Fixed forward and backward issues

### 更新日志

* 调整了紧凑布局下的播放控制栏样式
* 微软商店版本中点击检查更新将跳转至商店页面
* 修复了快退快进的问题

## v1.5.0

### Changelog

* Updated app icon
* Added a stop and an exit button
* Added a playback-speed selector that activates with a touch-and-hold gesture
* Fixed URI handling
* Improved stability and performance

### 更新日志

* 更换应用图标
* 添加停止按钮和退出按钮
* 添加触控长按激活的播放速度选择器
* 修复 uri 处理
* 优化了稳定性和性能

## v1.4.2

### Changelog

* Fix audio cover issue
* Improve uri handling

### 更新日志

* 修复音频封面问题
* 改进 uri 处理

## v1.4.1

### Changelog

* Dynamic FTP streaming url

### 更新日志

* FTP 串流使用动态 url

## v1.4.0

### Changelog

* Supports FTP storage
* Supports adding local folders to the storage list
* Storage list support remote disk and network shortcuts on Windows
* Add Windows installer

### 更新日志

* 支持 FTP 存储
* 支持添加本地文件夹到存储列表
* Windows 版本存储列表支持远程磁盘和网络快捷方式
* 添加 Windows 版本安装器

## v1.3.4

### Changelog

* The Android version allows you to set the screen orientation.
* Add playback speed button.
* Add hotkeys: Step forward `+`, Step backward `-`.

### 更新日志

* 安卓版本可以设置屏幕方向。
* 添加播放速度按钮。
* 添加快捷键：帧进 `+`，帧退 `-`。

## v1.3.3

### Changelog

* Fix issue of not being able to continue playback after startup

### 更新日志

* 修复启动后无法继续播放的问题

## v1.3.2

### Changelog

* Support for custom https ports when adding WebDAV storage

### 更新日志

* 添加 WebDAV 存储时支持自定义 https 端口

## v1.3.1

### Changelog

* The data save location for the Windows version has been changed to `C:\Users\<user>\AppData\Roaming\nini22P\iris`
* Updated upstream dependencies and fixed the issue with switching subtitles in the FVP player backend

### 更新日志

* Windows 版本数据保存位置已修改为 `C:\Users\<user>\AppData\Roaming\nini22P\iris`
* 更新上游依赖，修复 FVP 播放器后端切换字幕的问题

## v1.3.0

### Changelog

* Add [FVP](https://github.com/wang-bin/fvp) player backend (Experimental, with unknown bugs)
* Adding volume adjust
* Add file sort
* Add hotkeys: Volume up ( `Arrow Up` ), Volume down ( `Arrow Down` ), Volume mute ( `Ctrl + M` ), Toggle always on top ( `F10` ), Close currently media file ( `Ctrl + C` ), Exit application ( `Alt + X` )
* Improved some visual effects

### 更新日志

* 添加 [FVP](https://github.com/wang-bin/fvp) 播放器后端（实验性，有未知bug）
* 添加音量调整
* 添加文件排序
* 添加快捷键：提升音量（ `Arrow Up` ）、降低音量（ `Arrow Down` ）、静音（`Ctrl + M`）、切换窗口置顶（ `F10` ）、关闭当前媒体文件（ `Ctrl + C` ）、退出应用（ `Alt + X` ）
* 改进了部分视觉效果

## v1.2.1

### Changelog

* Split APKs by architecture to reduce installation size.

### 更新日志

* 拆分不同架构的 APK 以减小安装包大小

## v1.2.0

### Changelog

* Support jumping to video playback from external clicks (Windows version can play by command line or dragging files to the window)
* Support adjusting brightness and volume gestures (Brightness gestures are not available on Windows version)
* Support playing online links
* Add an option to always start playback from the beginning
* On Android 11 and above, file reading is changed to using the "Manage All Files" permission
* Improved WebDAV connection test function
* Improved some visual effects

### 更新日志

* 支持从外部点击视频跳转播放（Windows 版本可以通过命令行或者拖拽文件到窗口播放）
* 支持调整亮度和音量手势（Windows 版本调整亮度手势不可用）
* 支持播放在线链接
* 添加总是从头开始播放的选项
* Android 11 以上读取文件时改为使用 `管理所有文件` 权限
* 改进 WebDAV 测试连接功能
* 改进了部分视觉效果

## v1.1.1

### Changelog

* Restore old update method for windows version (Double-click the `iris-updater.bat` in the same directory as the executable file to upgrade if you have problems updating.)

### 更新日志

* windows 版本恢复为旧的更新方式（更新出问题的可双击打开可执行文件同级目录下的 `iris-updater.bat` 升级）

## v1.1.0

### Breaking Changes

* All configurations will be cleared. Please reconfigure

### Changlog

* Display all local storage
* Support playback history
* Support random playback
* Support loop playback
* Support video zoom

### 重大变更

* 所有配置将被清空，请重新配置

### 更新日志

* 显示所有本地存储
* 支持播放历史
* 支持随机播放
* 支持循环播放
* 支持视频缩放

## v1.0.3

### Changelog

* Improve Windows version installation updates
* Fixes an issue where subtitles may not be found

### 更新日志

* 改进 Windows 版本安装更新
* 修复可能无法找到字幕的问题

## v1.0.2

### Changelog

* Support for switching built-in audio tracks
* Reduce package size for Windows version

### 更新日志

* 支持切换内置音轨
* 减小 Windows 版本包体大小

## v1.0.1

### Changelog

* Windows version support auto update

### 更新日志

* Windows 版本支持自动更新

## v1.0.0

### Changelog

* Supports WebDAV and local storage video playback

### 更新日志

* 支持 WebDAV 和本地存储视频播放
