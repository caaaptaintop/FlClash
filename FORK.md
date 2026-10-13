# FlClash IP 质量版

上游：https://github.com/chen08209/FlClash

Fork：https://github.com/caaaptaintop/FlClash

开发分支：`ip-quality`。保留原 GPL-3.0 许可证。

## 使用

代理页点击节点延时、组测速按钮，或新增的“刷新延时与 IP 质量”按钮，都会重新检测对应节点。
延时先正常更新，IP 质量在后台独立更新。节点卡片显示风险分、住宅属性、原生/广播分类；悬停可查看出口 IP、ASN、机构、时间与来源。

风险显示为 `IP 风险 48/100 · 轻度风险`，下方颜色条从绿到黄、橙、红，标记当前分数并注明“越低越好”。
等级沿用 [IPPure 页面](https://ippure.com/)：0–15 极度纯净、16–25 纯净、26–40 中性、41–50 轻度风险、51–70 中度风险、71–100 极度风险。
颜色条按 0–100 线性定位；缺失分数显示未知，不显示颜色条，也不推断等级。

质量检测使用内核 `probe(proxyName: 实际节点名)`，直接拨号指定节点，不调用选路切换、模式切换、连接重置或关闭连接。最多同时检测两个节点；同一轮中的重复节点合并检测；切换配置或断开内核后丢弃旧请求结果。失败保留上次结果并明确标注。内建 DIRECT、REJECT 等非代理出口跳过质量检测。

数据来自 `https://my.ippure.com/v1/info`，无需 API Key。风险分越低越好。
住宅与原生/广播是该数据源的分类，不能作为绝对保证；非住宅不直接等于机房。缺失字段显示未知，不根据 ASN 名称猜测住宅类型。
第三方接口可能限流或变化；检测失败不会影响原测速，也不会改变当前选路。
检测会额外产生少量网络请求，与日常流量共享节点带宽，不能承诺完全没有带宽影响。

## macOS 安全预览

```bash
bash tool/build_ip_quality_preview.sh
```

产物：`build/macos/Build/Products/Release/FlClash IP.app`。
预览开启上游的 `SAFE_MODE`：不建立 TUN、不修改系统代理/DNS/登录项、不监听本地代理端口。
可以导入配置并测试指定节点；预览不接管日常应用的流量。
macOS 应用标识、数据目录和 URL scheme 与官方版隔离。更新检查指向本 Fork，避免官方包覆盖改造功能。

## 后续同步官方

在提交修改、保持工作区干净后运行：

```bash
bash tool/sync_ip_quality_upstream.sh
# 也可指定上游发布 tag：
bash tool/sync_ip_quality_upstream.sh <tag>
```

`origin` 指向自己的 Fork，`upstream` 指向官方；用 merge 保留自己的提交。
脚本只同步与合并，不推送、不发布。若上游修改相同位置，需解决冲突并重新验证。
官方更新不会自动合并到已安装的自定义应用，需同步源码后重新构建自己的版本。
