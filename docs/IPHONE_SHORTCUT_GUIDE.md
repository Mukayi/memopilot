# iPhone 端「快捷指令 + ChatGPT.app」无感联动配置手册

无需每年交 $99 开发者年费，也无需每 7 天重签，利用你手机上已登录付费账号的官方 **ChatGPT App**，花 3 分钟配置一个快捷指令，即可在 iPhone 上实现：
- **敲两下手机背面 / 按操作按钮** → 自动截屏微信/邮件或输入备忘文字 → **直接建日历 + 提醒事项 + 系统闹钟**。

---

## 步骤 1：新建快捷指令「AI 闪记」

打开 iPhone 自带的 **「快捷指令（Shortcuts）」** App，点击右上角 `+` 新建：

1. **获取输入（支持截屏或打字）**：
   - 添加动作 **「要求输入」**（提示填：`输入备忘（或留空直接识别刚截的图）`）。
2. **调用你的付费 ChatGPT 账号**：
   - 添加动作 **「Ask ChatGPT（向 ChatGPT 提问）」**（由官方 ChatGPT App 提供，直接消耗你的 Plus/Pro 订阅，无需 API Key）。
   - 将下面的 Prompt 粘贴进去（把「要求输入的结果」插入末尾）：

```text
请分析以下备忘内容，结合当前时间，只输出如下纯 JSON（不要带 markdown 代码块）：
{
  "has_event": true,
  "event_title": "事项标题",
  "start_time": "2026-10-28 15:00",
  "end_time": "2026-10-28 16:00",
  "lead_minutes": 60,
  "has_reminder": true,
  "reminder_title": "待办标题",
  "reminder_time": "2026-10-28 14:00",
  "needs_alarm": false,
  "alarm_hour": 7,
  "alarm_minute": 30,
  "note_summary": "提炼后的关键信息要点"
}
规则：线下外出 lead_minutes 填 60，线上会议填 15，航班高铁填 180；早起或绝不能迟到的事 needs_alarm 填 true。
用户输入：[要求输入的结果]
```

3. **解析 JSON 并写入系统应用**：
   - 添加动作 **「从输入中获取词典（Get Dictionary from Input）」**。
   - **建日历**：如果 `词典值(has_event)` 为真 → 添加动作 **「添加新日程」**，标题填 `event_title`，开始时间填 `start_time`，结束时间填 `end_time`，提醒设为 `lead_minutes` 分钟前。
   - **建提醒事项**：如果 `词典值(has_reminder)` 为真 → 添加动作 **「添加新提醒事项」**，标题填 `reminder_title`，提醒时间填 `reminder_time`。
   - **建真闹钟（静音也响）**：如果 `词典值(needs_alarm)` 为真 → 添加动作 **「创建闹钟（Create Alarm）」**，时间填 `alarm_hour : alarm_minute`，标签填 `event_title`。
   - **写备忘录**：如果 `词典值(note_summary)` 有值 → 添加动作 **「创建备忘录」**。

---

## 步骤 2：绑定「轻点背面两下」或「操作按钮」

- 打开 iPhone **设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下**，勾选刚建好的 **「AI 闪记」**。
- 或者在 **设置 → 操作按钮 → 快捷指令** 中选择 **「AI 闪记」**。
