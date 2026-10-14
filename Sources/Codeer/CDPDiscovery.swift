import AppKit

/// CDP 目标（/json/list 的一行）
struct CDPTarget {
    let id: String
    let type: String
    let title: String
    let url: String
    let wsURL: String?

    /// 归属判定（实测 codebuddy-cn 1.106.1 的真实结构）：
    /// page = vscode-file workbench 主窗口；聊天面板 = 可见 vscode-webview iframe target 的内层 iframe
    var kind: TargetKind {
        if type == "iframe" && url.hasPrefix("vscode-webview://") { return .webview }
        if url.hasPrefix("vscode-file://") { return .main }
        return .other
    }

    enum TargetKind {
        case webview, main, other
    }
}

/// 一个可用的 CDP 端点（端口 + 该端口下归类的目标）
struct CDPEndpoint {
    let port: Int
    let targets: [CDPTarget]
    var webviewTargets: [CDPTarget] {
        targets.filter { $0.kind == .webview }
    }
    var mainTarget: CDPTarget? {
        targets.first { $0.kind == .main }
    }
}

enum CDPError: Error {
    case httpError(Int)
    case badPayload
    case noTarget
    case wsClosed
    case timeout
}

/// M0 探测表达式：在 webview target 上执行，进内层 iframe 读聊天 DOM 摘要
/// 返回 JSON 字符串：{ chat, textLen, btnCount, btnSample[], reason? }
enum CDPProbe {
    static let chatSummary = """
    (() => {
      const f = document.querySelector('iframe');
      if (!f) return JSON.stringify({ chat: false, reason: 'no inner iframe' });
      let d;
      try { d = f.contentDocument; } catch (e) { return JSON.stringify({ chat: false, reason: 'cross-origin' }); }
      if (!d) return JSON.stringify({ chat: false, reason: 'null contentDocument' });
      const btns = [...d.querySelectorAll('button,[role=button]')]
        .map(b => (b.innerText || '').trim()).filter(t => t && t.length < 40);
      const text = (d.body && d.body.innerText) || '';
      return JSON.stringify({
        chat: text.length > 100,
        textLen: text.length,
        btnCount: btns.length,
        btnSample: [...new Set(btns)].slice(0, 30),
      });
    })()
    """

    /// 注入脚本与检测表达式（对齐 WorkDaddy：守卫幂等 + 文案匹配）
    /// Runtime.addBinding 的回调名（Swift 侧接收 MutationObserver 触发信号）
    static let bindingName = "__codeerReport"

    /// 注入：MutationObserver 挂到内层 iframe 文档（同源），变化即回报；
    /// 内层文档可能随 webview 重载更换，每秒重查并重挂
    static let injectMonitor = #"""
    (() => {
      const G = '__codeerMonitorV1';
      if (window[G]) return 'exists';
      window[G] = true;
      let obs = null, doc = null;
      const signal = () => { try { window.__codeerReport('changed'); } catch (e) {} };
      function attach() {
        const f = document.querySelector('iframe');
        const d = f && f.contentDocument;
        if (d && d !== doc) {
          if (obs) obs.disconnect();
          doc = d;
          obs = new MutationObserver(signal);
          obs.observe(d, { subtree: true, childList: true, attributes: true, characterData: true });
          signal();
        }
      }
      attach();
      setInterval(attach, 1000);
      return 'injected';
    })()
    """#

    /// 快照：内层 iframe 里是否存在精确文案「运行」+「拒绝」的可点击元素。
    /// 真实审批框实测（2026-10-13）是 div.menu-item 下拉菜单项（运行/跳过/拒绝三项），
    /// 选择器必须含 .menu-item；菜单与命令文本可能不同容器，摘要沿祖先爬到最小「菜单+命令」容器
    static let pendingSnapshot = #"""
    (() => {
      const f = document.querySelector('iframe');
      const d = f && f.contentDocument;
      if (!d) return JSON.stringify({ pending: false, reason: 'no-doc' });
      const sel = 'button,[role=button],.menu-item,[class*="menu-item"]';
      const all = [...d.querySelectorAll(sel)];
      const find = t => all.find(b => (b.textContent || '').trim() === t);
      const run = find('运行'), deny = find('拒绝');
      if (!run || !deny) return JSON.stringify({ pending: false });
      const menuText = ((run.parentElement && run.parentElement.innerText) || '运行 跳过 拒绝')
        .replace(/\s+/g, ' ').trim();
      // 从运行项向上爬：直到文本同时含菜单标签与更多内容（命令），或到 body 为止
      let anc = run, text = '';
      while (anc && anc !== d.body) {
        text = (anc.innerText || '').replace(/\s+/g, ' ').trim();
        if (text.includes('拒绝') && text.length >= 30) break;
        anc = anc.parentElement;
      }
      if (anc === d.body || !text) text = menuText.slice(0, 300);
      // 去掉尾部的菜单按钮文案（innerText 顺序：命令 → 说明 → 运行/跳过/拒绝）
      text = text.replace(/(?:\s*(?:运行|跳过|拒绝))+\s*$/, '').trim();
      return JSON.stringify({ pending: true, text: text.slice(0, 300) });
    })()
    """#

    /// 代点定位：找目标元素返回内层 iframe 视口坐标中心（配合主页面 Input 派发）。
    /// 注意：选择器用无引号属性选择器（[class*=optionItem]），插值进 JS 字符串才不会引号冲突
    static let actionSelector = "button,[role=button],.menu-item,[class*=menu-item]"

    static func findRect(selector: String, text: String, matchOwnText: Bool) -> String {
        let match = matchOwnText
            ? "const el = [...d.querySelectorAll(SEL)].find(b => (b.textContent || '').trim() === want);"
            // 兼容两种卡：单问题卡按钮 = optionItem；多问题卡按钮 = option_rUDHS（都是 optionText 的父元素）
            : "const t = [...d.querySelectorAll('[class*=optionText]')].find(s => (s.textContent || '').trim() === want);\n          const el = t ? (t.closest('[class*=optionItem]') || t.parentElement) : null;"
        return #"""
        (() => {
          const f = document.querySelector('iframe');
          const d = f && f.contentDocument;
          if (!d) return JSON.stringify({ err: 'no-doc' });
          const want = "\#(text)";
          const SEL = "\#(selector)";
          \#(match)
          if (!el) return JSON.stringify({ err: 'not-found' });
          el.scrollIntoView({ block: 'center' });
          const r = el.getBoundingClientRect();
          return JSON.stringify({ x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) });
        })()
        """#
    }

    /// 坐标换算（实测：Input.dispatchMouseEvent 必须在主页面会话派发才生效）：
    /// 主页面坐标 = 主页面 webview iframe 偏移 + webview 根内内层 iframe 偏移 + 元素坐标
    /// 在 webview 根（聊天 client）上执行：内层 iframe 偏移
    static let chatIframeRect = """
    (() => {
      const f = document.querySelector('iframe');
      if (!f) return JSON.stringify({ err: 'no-iframe' });
      const r = f.getBoundingClientRect();
      return JSON.stringify({ x: Math.round(r.left), y: Math.round(r.top) });
    })()
    """

    /// 在主页面（workbench）上执行：可见 webview iframe 的偏移
    static let mainWebviewRect = """
    (() => {
      const f = [...document.querySelectorAll('iframe')].find(f => f.offsetWidth > 100);
      if (!f) return JSON.stringify({ err: 'no-webview' });
      const r = f.getBoundingClientRect();
      return JSON.stringify({ x: Math.round(r.left), y: Math.round(r.top) });
    })()
    """

    /// 聚焦问题卡的自定义输入框（input[class*=customInput]，placeholder「输入自定义回答…」）
    static let focusCustomInput = """
    (() => {
      const f = document.querySelector('iframe');
      const d = f && f.contentDocument;
      const el = d && d.querySelector('input[class*="customInput"]');
      if (!el) return 'not-found';
      el.scrollIntoView({ block: 'center' });
      el.focus({ preventScroll: true });
      el.click();
      return 'ok';
    })()
    """

    /// 代点兜底：事件序列无效时的 element.click()
    /// 后台对话等待检测：session-tab 上的 agent-state-question 指示器（非 active tab）
    /// 2026-10-14 实锤：切走对话后确认框 DOM 被卸载，唯一信号是 tab 上的状态指示器
    static let backgroundQuestionSnapshot = #"""
    (() => {
      const f = document.querySelector('iframe');
      const d = f && f.contentDocument;
      if (!d) return JSON.stringify({ pending: false });
      const tabs = [...d.querySelectorAll('[class*="agent-state-indicator"][class*="agent-state-question"]')]
        .map(ind => ind.closest('[class*="session-tab"]'))
        .filter(tab => tab && !tab.className.includes('active'));
      const list = tabs.map(tab => {
        const name = (tab.querySelector('[class*="session-tab-name"]')?.textContent || '').trim();
        tab.scrollIntoView({ block: 'nearest' });
        const r = tab.getBoundingClientRect();
        return { name: name.slice(0, 80), x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
      }).filter(t => t.name);
      return JSON.stringify({ pending: list.length > 0, tabs: list });
    })()
    """#

    /// 按对话名定位 session-tab（坐标为内层 iframe 视口）
    static func sessionTabRect(name: String) -> String {
        #"""
        (() => {
          const f = document.querySelector('iframe');
          const d = f && f.contentDocument;
          if (!d) return JSON.stringify({ err: 'no-doc' });
          const want = "\#(name)";
          const tab = [...d.querySelectorAll('[class*="session-tab"]')].find(t => {
            const n = t.querySelector('[class*="session-tab-name"]');
            return n && (n.textContent || '').trim() === want;
          });
          if (!tab) return JSON.stringify({ err: 'not-found' });
          tab.scrollIntoView({ block: 'nearest' });
          const r = tab.getBoundingClientRect();
          return JSON.stringify({ x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) });
        })()
        """#
    }

    /// 「完成 ↩︎」按钮（continueBtn）定位，多问题卡选中选项后需点它提交（坐标为内层 iframe 视口）
    static func continueBtnRect() -> String {
        #"""
        (() => {
          const f = document.querySelector('iframe');
          const d = f && f.contentDocument;
          if (!d) return JSON.stringify({ err: 'no-doc' });
          const btn = d.querySelector('[class*="continueBtn"]');
          if (!btn) return JSON.stringify({ err: 'no-btn' });
          btn.scrollIntoView({ block: 'center' });
          const r = btn.getBoundingClientRect();
          return JSON.stringify({ x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) });
        })()
        """#
    }

    /// 多问题卡：在第 blockIndex 个 questionBlock 内按选项文本定位（坐标为内层 iframe 视口）
    static func optionRectInBlock(blockIndex: Int, text: String) -> String {
        #"""
        (() => {
          const f = document.querySelector('iframe');
          const d = f && f.contentDocument;
          if (!d) return JSON.stringify({ err: 'no-doc' });
          const want = "\#(text)";
          const blocks = [...d.querySelectorAll('[class*="questionBlock"]')];
          const b = blocks[\#(blockIndex)];
          if (!b) return JSON.stringify({ err: 'no-block' });
          const t = [...b.querySelectorAll('[class*="optionText"]')].find(s => (s.textContent || '').trim() === want);
          const el = t ? (t.closest('[class*=optionItem]') || t.parentElement) : null;
          if (!el) return JSON.stringify({ err: 'not-found' });
          el.scrollIntoView({ block: 'center' });
          const r = el.getBoundingClientRect();
          return JSON.stringify({ x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) });
        })()
        """#
    }

    /// 模拟完整真实点击的 JS 片段（pointerdown→mousedown→pointerup→mouseup→click，带元素中心坐标）
    /// 实锤（2026-10-14）：多问题卡选项（option_rUDHS）用 element.click() 无效——组件绑的是
    /// pointer 事件而非 click，必须派发完整事件序列
    private static let fireRealClick = """
      const fire = (el) => {
        if (!el) return false;
        const r = el.getBoundingClientRect();
        const o = { bubbles: true, cancelable: true, view: window,
                    clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
        try { el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({}, o, { pointerId: 1, isPrimary: true }))); } catch (e) {}
        el.dispatchEvent(new MouseEvent('mousedown', o));
        try { el.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, o, { pointerId: 1, isPrimary: true }))); } catch (e) {}
        el.dispatchEvent(new MouseEvent('mouseup', o));
        el.dispatchEvent(new MouseEvent('click', o));
        return true;
      };
    """

    /// 多问题卡：在指定 questionBlock 内按文本模拟真实点击兜底
    static func fallbackClickInBlock(blockIndex: Int, text: String) -> String {
        #"""
        (() => {
          const f = document.querySelector('iframe');
          const d = f && f.contentDocument;
          if (!d) return 'no-doc';
          const want = "\#(text)";
          const blocks = [...d.querySelectorAll('[class*="questionBlock"]')];
          const b = blocks[\#(blockIndex)];
          if (!b) return 'no-block';
          const t = [...b.querySelectorAll('[class*="optionText"]')]
            .find(s => (s.textContent || '').trim().includes(want.slice(0, 12)));
          if (!t) return 'not-found';
          \#(fireRealClick)
          const a = fire(t);
          const c = fire(t.parentElement);
          if (!a && !c) return 'fire-failed';
          return 'ok-block-real:' + (a ? 'text' : '') + (c ? '+parent' : '');
        })()
        """#
    }

    static func fallbackClick(_ text: String) -> String {
        #"""
        (() => {
          const f = document.querySelector('iframe');
          const d = f && f.contentDocument;
          if (!d) return 'no-doc';
          const want = "\#(text)";
          // 先按 optionText 定位（兼容单问题卡 optionItem / 多问题卡 option_rUDHS），模拟真实点击
          const t = [...d.querySelectorAll('[class*="optionText"]')]
            .find(s => (s.textContent || '').trim().includes(want.slice(0, 12)));
          if (t) {
            \#(fireRealClick)
            const a = fire(t);
            const c = fire(t.parentElement);
            if (a || c) return 'ok-option-real:' + (a ? 'text' : '') + (c ? '+parent' : '');
          }
          const sel = 'button,[role=button],.menu-item,[class*="menu-item"]';
          const btn = [...d.querySelectorAll(sel)]
            .find(b => (b.textContent || '').trim().includes(want.slice(0, 12)));
          if (!btn) return 'not-found';
          btn.click();
          return 'ok-click:' + btn.tagName;
        })()
        """#
    }

    /// 选项快照：question-floating 的 optionItem 列表（2026-10-13 实锤结构：
    /// div[class*=optionItem] 内含 optionLetter + optionText；回答后元素消失）
    static let optionsSnapshot = #"""
    (() => {
      const f = document.querySelector('iframe');
      const d = f && f.contentDocument;
      if (!d) return JSON.stringify({ pending: false });
      // 兼容两种卡片结构（2026-10-14 实锤）：
      // - 单问题卡：选项按钮 = optionItem_rOhKt（无 questionBlock）→ 归一化为 1 题，blockIndex = -1
      // - 多问题卡：每题一个 questionBlock_lw8Kd（footer 带跳过/继续）→ 每题一项，blockIndex = 题序
      // 稳定共同点：两种卡的选项按钮都是 optionText 的直接父元素
      const questions = [];
      const blocks = [...d.querySelectorAll('[class*="questionBlock"]')];
      if (blocks.length > 0) {
        // 多问题卡：分题提取
        blocks.forEach((b, i) => {
          const q = b.querySelector('[class*="questionText"]');
          const num = b.querySelector('[class*="questionNumber"]');
          const opts = [...b.querySelectorAll('[class*="optionText"]')]
            .map(t => (t.textContent || '').trim().slice(0, 120)).filter(s => s.length > 0);
          const n = num ? num.textContent.trim() : `${i + 1}.`;
          questions.push({
            question: `${n} ${(q ? q.textContent : '').trim()}`.trim().slice(0, 150),
            options: opts,
            blockIndex: i,
          });
        });
      } else {
        // 单问题卡：原逻辑（克隆问题卡删选项取题干）
        const items = [...d.querySelectorAll('[class*="optionText"]')]
          .map(t => t.parentElement)
          .filter(el => el && !String(el.className).includes('customInputRow'));
        if (items.length >= 2) {
          const options = items.map(el => {
            const t = el.querySelector('[class*="optionText"]');
            return ((t ? t.textContent : el.textContent) || '').trim().slice(0, 120);
          }).filter(t => t.length > 0);
          let question = '';
          const root = (() => {
            let best = null;
            for (const el of d.querySelectorAll('div,section')) {
              if (el.querySelectorAll('[class*="optionText"]').length >= options.length) {
                if (!best || el.textContent.length < best.textContent.length) best = el;
              }
            }
            let card = best;
            while (card && card !== d.body) {
              const cls = String(card.className || '');
              if (cls.includes('question-floating-module_') && !cls.includes('option')) break;
              card = card.parentElement;
            }
            return card && card !== d.body ? card : best;
          })();
          if (root) {
            const clone = root.cloneNode(true);
            clone.querySelectorAll('[class*="optionItem"],[class*="optionLetter"],[class*="optionsWrapper"],[class*="option_"]').forEach(e => e.remove());
            question = (clone.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120);
          }
          questions.push({ question, options, blockIndex: -1 });
        }
      }
      if (!questions.some(q => q.options.length >= 2)) {
        return JSON.stringify({ pending: false });
      }
      return JSON.stringify({ pending: true, questions });
    })()
    """#

    struct ChatSummary {
        let chat: Bool
        let textLen: Int
        let btnCount: Int
        let btnSample: [String]
        let reason: String?

        static func parse(_ value: Any?) -> ChatSummary? {
            guard let s = value as? String, let data = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ChatSummary(
                chat: o["chat"] as? Bool ?? false,
                textLen: o["textLen"] as? Int ?? 0,
                btnCount: o["btnCount"] as? Int ?? 0,
                btnSample: o["btnSample"] as? [String] ?? [],
                reason: o["reason"] as? String
            )
        }
    }
}

/// CDP 端口发现 + 调试模式重启编排
/// 端口候选策略对齐 WorkDaddy：WorkDaddy 的 cdp-port.json → 9224（codebuddy-cn 固定偏好）→ 9222-9232/9333
enum CDPDiscovery {
    static let workDaddyProfileDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WorkDaddy/profiles/codebuddy-cn")
    static var cdpPortFile: URL { workDaddyProfileDir.appendingPathComponent("cdp-port.json") }
    static let codeBuddyBinary = "/Applications/CodeBuddy CN.app/Contents/MacOS/Electron"
    static let defaultDebugPort = 9224

    static func candidatePorts() -> [Int] {
        var ports: [Int] = []
        if let data = try? Data(contentsOf: cdpPortFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = (obj["port"] as? NSNumber)?.intValue, p > 0 {
            ports.append(p)
        }
        ports.append(contentsOf: [defaultDebugPort] + Array(9222...9232) + [9333])
        var seen = Set<Int>()
        return ports.filter { seen.insert($0).inserted }
    }

    /// GET /json/list
    static func listTargets(port: Int) async throws -> [CDPTarget] {
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw CDPError.httpError((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CDPError.badPayload
        }
        return arr.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return CDPTarget(
                id: id,
                type: d["type"] as? String ?? "",
                title: d["title"] as? String ?? "",
                url: d["url"] as? String ?? "",
                wsURL: d["webSocketDebuggerUrl"] as? String
            )
        }
    }

    /// 扫描候选端口，返回第一个含 Agents/Workbench 目标的端点
    static func discover() async -> CDPEndpoint? {
        for port in candidatePorts() {
            guard let targets = try? await listTargets(port: port), !targets.isEmpty else { continue }
            guard targets.contains(where: { $0.kind != .other }) else { continue }
            let endpoint = CDPEndpoint(port: port, targets: targets)
            NSLog("[CDPDiscovery] 发现 CDP 端口 \(port)：webview=\(endpoint.webviewTargets.count) main=\(endpoint.mainTarget != nil)")
            return endpoint
        }
        NSLog("[CDPDiscovery] 未发现可用的 CDP 端口")
        return nil
    }

    /// 逐个连接 webview target（对齐 WorkDaddy：按内容强信号归属，不按顺序猜），
    /// 返回第一个内层 iframe 含聊天内容的连接；调用方负责持有并最终 close
    static func connectChat(endpoint: CDPEndpoint) async throws -> (target: CDPTarget, client: CDPClient) {
        for target in endpoint.webviewTargets {
            guard let ws = target.wsURL, let url = URL(string: ws) else { continue }
            let client = CDPClient()
            do {
                try await client.connect(wsURL: url)
                if let s = CDPProbe.ChatSummary.parse(try await client.evaluate(expression: CDPProbe.chatSummary)), s.chat {
                    NSLog("[CDPDiscovery] 聊天 target 命中：\(target.id.prefix(8)) textLen=\(s.textLen) btns=\(s.btnCount)")
                    return (target, client)
                }
                client.close()
            } catch {
                client.close()
            }
        }
        throw CDPError.noTarget
    }

    /// 以调试模式重启 CodeBuddy。
    /// 实现说明：必须以 detached 脚本执行（执行者可能就是 CodeBuddy 的子进程，会随 IDE 退出而消亡），
    /// 因此落一个临时 shell 脚本用 nohup 拉起，与父进程脱钩。
    static func relaunchWithDebugPort(port: Int = defaultDebugPort) async throws -> CDPEndpoint {
        NSLog("[CDPDiscovery] 以调试模式重启 CodeBuddy（port=\(port)）")
        let script = """
        #!/bin/zsh
        sleep 0.5
        osascript -e 'tell application "CodeBuddy CN" to quit' 2>/dev/null
        sleep 2
        pkill -f "CodeBuddy CN.app/Contents/MacOS/Electron" 2>/dev/null
        sleep 1
        nohup "\(codeBuddyBinary)" --remote-debugging-port=\(port) --inspect=127.0.0.1:9244 >/dev/null 2>&1 &
        for i in {1..60}; do
          curl -s -m 1 "http://127.0.0.1:\(port)/json/version" >/dev/null 2>&1 && exit 0
          sleep 0.5
        done
        exit 1
        """
        let scriptPath = "/tmp/codeer-relaunch.sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [scriptPath]
        try p.run()   // detached: 父进程退出不影响它

        // 轮询等待 CDP 就绪（最多 45s）
        let pollDeadline = Date().addingTimeInterval(45)
        while Date() < pollDeadline {
            if let endpoint = await discover() { return endpoint }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CDPError.timeout
    }
}
