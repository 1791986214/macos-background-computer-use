#!/usr/bin/env node
/**
 * wbcu-mcp — WorkBuddy macOS Computer Use MCP 服务器
 *
 * 把 wbcu 原生辅助进程包装成 MCP 工具，供 WorkBuddy Agent 调用。
 * 零依赖：手写 JSON-RPC 2.0 over stdio（Content-Length 帧不需要，MCP stdio 用换行分隔 JSON）。
 */
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const WBCU = process.env.WBCU_BIN || path.join(os.homedir(), '.local/bin/wbcu');
const SERVER_INFO = { name: 'wbcu-computer-use', version: '0.2.0' };
const PROTOCOL = '2025-06-18';

// ---------- 会话（持续捕获）状态 ----------
const sessions = new Map(); // app -> { proc, startedAt, windowId }

function runWbcu(args, { timeoutMs = 30000 } = {}) {
  const r = spawnSync(WBCU, args, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 });
  const out = (r.stdout || '').trim();
  const err = (r.stderr || '').trim();
  let json = null;
  if (out.startsWith('{') || out.startsWith('[')) {
    try { json = JSON.parse(out); } catch { /* 保留原始文本 */ }
  }
  return { code: r.status, out, err, json };
}

function resolveApp(arg) {
  // 允许传 bundle id / 名称 / pid
  return String(arg ?? '').trim();
}

// ---------- 工具定义 ----------
const TOOLS = [
  {
    name: 'cu_session',
    description:
      '【推荐入口】建立一次性会话并在其中完成整套后台操作：start → capture/inspect → click/type/key → verify → end。' +
      '会话会记住目标应用与窗口，后续调用不必重复解析；所有动作默认走 AX 语义或进程级定向投递，' +
      '不移动真实鼠标、不切换前台、不抢键盘焦点。任务结束务必 end 释放资源。',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['start', 'list', 'state', 'capture', 'inspect', 'click', 'type', 'key', 'cursor', 'verify', 'end'],
          description: 'start=建会话；capture=抓窗口画面；inspect=读 AX 树；click/type/key=执行操作；verify=断言结果；end=释放',
        },
        session_id: { type: 'string', description: 'start 返回的会话 id，后续动作必填' },
        app: { type: 'string', description: 'start 时指定：bundleId / 应用名 / pid' },
        element_index: { type: 'number', description: 'inspect 返回的 index，用于按元素操作' },
        text: { type: 'string', description: 'click 时按文本匹配元素；type 时要输入的内容' },
        key: { type: 'string', description: '如 "cmd+a"、"Return"' },
        x: { type: 'number', description: '窗口局部坐标（cursor 用）' },
        y: { type: 'number', description: '窗口局部坐标' },
        expect: { type: 'string', description: 'verify：期望在 AX 文本值中出现的字符串' },
        out_path: { type: 'string', description: 'capture：截图保存路径' },
        max_nodes: { type: 'number', description: 'inspect 最大节点数，默认 200' },
        label: { type: 'string', description: '动作标签，显示在虚拟光标旁' },
        exact: { type: 'boolean', description: 'click 按文本匹配时要求完全相等，避免 "9" 撞 "99"' },
        no_ghost: { type: 'boolean', description: '不显示虚拟光标（不影响操作本身）' },
        no_verify: { type: 'boolean', description: '跳过结果验证（不建议）' },
      },
      required: ['action'],
    },
  },
  {
    name: 'cu_permissions',
    description: '检查 macOS 三态权限：辅助功能(Accessibility)、屏幕录制(Screen Recording)、输入注入(PostEvent)。返回授权归属 App。',
    inputSchema: { type: 'object', properties: { prompt: { type: 'boolean', description: '是否触发系统授权弹窗' } } },
  },
  {
    name: 'cu_list_apps',
    description: '列出当前运行中的 macOS 应用（含 pid、bundleId、窗口数、是否前台）。',
    inputSchema: { type: 'object', properties: { include_background: { type: 'boolean' } } },
  },
  {
    name: 'cu_list_windows',
    description: '列出应用窗口（windowId、标题、位置尺寸）。默认只列前台可见窗口；已自动排除窗口共享指示器那类系统胶囊窗。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, all: { type: 'boolean' } },
      required: ['app'],
    },
  },
  {
    name: 'cu_get_app_state',
    description: '获取指定应用的当前状态：Accessibility UI 元素树文本 + 一张窗口截图。这是每次操作前后都应该调用的观察入口。',
    inputSchema: {
      type: 'object',
      properties: {
        app: { type: 'string', description: '应用名 / bundle id / pid' },
        max_nodes: { type: 'number', description: '元素树最多返回多少个节点，默认 300' },
        max_width: { type: 'number', description: '截图最大宽度，默认 1024' },
        with_image: { type: 'boolean', description: '是否返回截图图像内容，默认 true' },
      },
      required: ['app'],
    },
  },
  {
    name: 'cu_click',
    description: '点击。优先用 element_index（来自最近一次 cu_get_app_state / cu_find）；也可给屏幕坐标 x,y。background=true 时用 AXPress 不抢焦点。',
    inputSchema: {
      type: 'object',
      properties: {
        app: { type: 'string' },
        element_index: { type: 'number' },
        x: { type: 'number' },
        y: { type: 'number' },
        button: { type: 'string', enum: ['left', 'right', 'middle'] },
        count: { type: 'number', description: '1=单击 2=双击' },
        window_id: { type: 'number', description: '目标窗口 ID，坐标点击时建议显式给出' },
        mode: {
          type: 'string',
          enum: ['auto', 'ax', 'targeted', 'global'],
          description: 'auto=AX 优先、无变化自动升级为进程级定向投递；targeted=只走 postToPid+窗口上下文；global=真实鼠标注入（必须显式指定，会移动用户指针）',
        },
        verify: { type: 'boolean', description: '点击后对比 AX 树指纹确认 UI 真的变了，默认 true' },
        ghost: { type: 'boolean', description: '显示 Agent 虚拟光标（不碰真实鼠标）' },
      },
      required: ['app'],
    },
  },
  {
    name: 'cu_find_elements',
    description: '按文本/角色/动作在应用 UI 树里查找元素，返回 element_index 与位置。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, text: { type: 'string' }, role: { type: 'string' }, action: { type: 'string' } },
      required: ['app'],
    },
  },
  {
    name: 'cu_set_value',
    description: '直接设置输入框/文本元素的 AXValue（比模拟键入更可靠，支持中文）。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, element_index: { type: 'number' }, value: { type: 'string' } },
      required: ['app', 'element_index', 'value'],
    },
  },
  {
    name: 'cu_type_text',
    description: '向指定应用键入文本（Unicode 事件，支持中文与 emoji）。目标应用不需要在前台。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, text: { type: 'string' } },
      required: ['app', 'text'],
    },
  },
  {
    name: 'cu_press_key',
    description: '按键/快捷键，如 "Return"、"cmd+shift+g"、"super+c"。按键只发给目标应用，不会触发全局快捷键。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, key: { type: 'string' }, repeat: { type: 'number' } },
      required: ['app', 'key'],
    },
  },
  {
    name: 'cu_scroll',
    description: '在指定位置滚动页面。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, direction: { type: 'string', enum: ['up', 'down', 'left', 'right'] }, pages: { type: 'number' }, x: { type: 'number' }, y: { type: 'number' } },
      required: ['app', 'direction'],
    },
  },
  {
    name: 'cu_perform_action',
    description: '对元素执行 AX 动作（如 AXPress、AXShowMenu、AXConfirm）。只在元素确实暴露了该动作时可用。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, element_index: { type: 'number' }, action: { type: 'string' } },
      required: ['app', 'element_index', 'action'],
    },
  },
  {
    name: 'cu_start_capture',
    description: '开始对指定应用窗口做「窗口级持续捕获」（SCStream）。注意：这会让 macOS 在该窗口左上角显示系统级紫色共享指示器（这是系统的隐私提示，不是 UI 装饰）。',
    inputSchema: {
      type: 'object',
      properties: { app: { type: 'string' }, seconds: { type: 'number', description: '持续秒数，默认 600' }, frames_dir: { type: 'string' } },
      required: ['app'],
    },
  },
  {
    name: 'cu_stop_capture',
    description: '停止持续捕获并释放资源（系统紫色指示器随之消失）。',
    inputSchema: { type: 'object', properties: { app: { type: 'string' } } },
  },
  {
    name: 'cu_ghost',
    description: 'Agent 虚拟光标：在屏幕上显示一个独立于系统鼠标的紫色指针，用于展示 Agent 的操作位置。只是可视化，不投递输入、不移动真实鼠标、不抢焦点。',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['start', 'move', 'click', 'hide', 'stop', 'status'] },
        x: { type: 'number' },
        y: { type: 'number' },
        label: { type: 'string', description: '点击时显示的动作标签，如 "click"、"drag"' },
      },
      required: ['action'],
    },
  },
  {
    name: 'cu_indicator_status',
    description: '探测目标窗口当前是否处于被共享/捕获状态：读取 AX 树里的 WindowSharingSessionButton 与标题栏紫色像素。用于验证捕获是否真的生效、是否已停止。',
    inputSchema: { type: 'object', properties: { app: { type: 'string' } }, required: ['app'] },
  },
];

// ---------- 工具实现 ----------
function toolResult(text, extra = []) {
  return { content: [{ type: 'text', text }, ...extra] };
}

async function callTool(name, args = {}) {
  const app = resolveApp(args.app);

  switch (name) {
    case 'cu_session': {
      const act = String(args.action || 'list');
      const sid = args.session_id ? String(args.session_id) : '';
      const argv = ['session', act];
      const needId = ['state', 'capture', 'inspect', 'click', 'type', 'key', 'cursor', 'verify', 'end'];
      if (needId.includes(act) && sid) argv.push('--id', sid);

      switch (act) {
        case 'start':
          if (!args.app) return toolResult('start 需要 app 参数');
          argv.push('--app', String(args.app));
          if (args.no_ghost) argv.push('--no-ghost');
          break;
        case 'capture':
          if (args.out_path) argv.push('--out', String(args.out_path));
          break;
        case 'inspect':
          argv.push('--max', String(args.max_nodes || 200));
          break;
        case 'click':
          if (typeof args.element_index === 'number') argv.push('--element', String(args.element_index));
          else if (args.text) { argv.push('--text', String(args.text)); if (args.exact) argv.push('--exact'); }
          else if (typeof args.x === 'number' && typeof args.y === 'number') argv.push('--x', String(args.x), '--y', String(args.y));
          else return toolResult('click 需要 element_index / text / x+y 之一');
          if (args.label) argv.push('--label', String(args.label));
          if (args.no_ghost) argv.push('--no-ghost');
          if (args.no_verify) argv.push('--no-verify');
          break;
        case 'type':
          if (!args.text) return toolResult('type 需要 text');
          argv.push('--text', String(args.text));
          if (typeof args.element_index === 'number') argv.push('--element', String(args.element_index));
          break;
        case 'key':
          if (!args.key) return toolResult('key 需要 key');
          argv.push('--combo', String(args.key));
          break;
        case 'cursor':
          if (typeof args.x !== 'number' || typeof args.y !== 'number') return toolResult('cursor 需要 x/y');
          argv.push('--x', String(args.x), '--y', String(args.y));
          if (args.label) argv.push('--label', String(args.label));
          break;
        case 'verify':
          if (args.expect) argv.push('--expect', String(args.expect));
          break;
      }
      argv.push('--json');
      if (act === 'end' && !sid) argv.push('--all');
      const r = runWbcu(argv, { timeoutMs: 60000 });
      return toolResult(r.out || r.err);
    }

    case 'cu_permissions': {
      const r = runWbcu(['perm', '--json', ...(args.prompt ? ['--prompt'] : [])], { timeoutMs: 60000 });
      return toolResult(r.out || r.err);
    }

    case 'cu_list_apps': {
      const r = runWbcu(['apps', '--json', ...(args.include_background ? ['--all'] : [])]);
      return toolResult(r.out);
    }

    case 'cu_list_windows': {
      const r = runWbcu(['windows', '--json', '--app', app, ...(args.all ? ['--all'] : [])]);
      return toolResult(r.out || r.err);
    }

    case 'cu_get_app_state': {
      const maxNodes = String(args.max_nodes ?? 300);
      const r = runWbcu(['app-state', '--json', '--app', app, '--max', maxNodes,
        '--max-width', String(args.max_width ?? 1024)], { timeoutMs: 60000 });
      if (!r.json) return toolResult(`调用失败: ${r.err || r.out}`);
      const axText = r.json.axText || '';
      const shot = r.json.screenshot;
      const meta = {
        app: r.json.app, pid: r.json.pid, windowId: r.json.windowId,
        nodeCount: r.json.nodeCount, screenshot: shot,
      };
      const extra = [];
      if (args.with_image !== false && shot && existsSync(shot)) {
        const buf = readFileSync(shot);
        // 控制体积：>3MB 的图不回传
        if (buf.length < 3 * 1024 * 1024) {
          extra.push({ type: 'image', data: buf.toString('base64'), mimeType: 'image/png' });
        }
      }
      return toolResult(`${JSON.stringify(meta)}\n\n${axText}`, extra);
    }

    case 'cu_find_elements': {
      const argv = ['ax-find', '--json', '--app', app];
      if (args.text) argv.push('--text', args.text);
      if (args.role) argv.push('--role', args.role);
      if (args.action) argv.push('--action', args.action);
      const r = runWbcu(argv);
      return toolResult(r.out || r.err);
    }

    case 'cu_click': {
      const mode = args.mode || 'auto';
      const extra = ['--mode', mode, '--button', args.button || 'left', '--count', String(args.count || 1), '--json'];
      if (args.verify !== false) extra.push('--verify');
      if (args.ghost || process.env.WBCU_GHOST === '1') extra.push('--ghost');

      if (typeof args.element_index === 'number') {
        const t = runWbcu(['ax-tree', '--json', '--app', app, '--max', '4000']);
        let item = null;
        try {
          const items = JSON.parse(t.out).items || [];
          item = items.find((i) => i.index === args.element_index);
        } catch { /* noop */ }
        if (!item || item.x == null) {
          const r = runWbcu(['ax-act', '--app', app, '--index', String(args.element_index), '--json']);
          return toolResult(r.out || r.err);
        }
        const cx = item.x + item.w / 2, cy = item.y + item.h / 2;
        const r = runWbcu(['click', '--app', app, '--x', String(cx), '--y', String(cy), ...extra]);
        return toolResult(r.out || r.err);
      }
      if (typeof args.x === 'number' && typeof args.y === 'number') {
        const base = ['click', '--x', String(args.x), '--y', String(args.y), ...extra];
        if (app) base.push('--app', app);
        if (typeof args.window_id === 'number') base.push('--window', String(args.window_id));
        const r = runWbcu(base);
        return toolResult(r.out || r.err);
      }
      return toolResult('需要 element_index 或 x/y');
    }

    case 'cu_ghost': {
      const sub = args.action || 'status';
      const argv = ['ghost', sub];
      if (typeof args.x === 'number') argv.push('--x', String(args.x), '--y', String(args.y));
      if (args.label) argv.push('--label', args.label);
      argv.push('--json');
      const r = runWbcu(argv);
      return toolResult(r.out || r.err);
    }

    case 'cu_set_value': {
      const r = runWbcu(['ax-set', '--app', app, '--index', String(args.element_index), '--value', String(args.value ?? ''), '--json']);
      return toolResult(r.out || r.err);
    }

    case 'cu_type_text': {
      const r = runWbcu(['type', '--app', app, '--text', String(args.text ?? ''), '--json']);
      return toolResult(r.out || r.err);
    }

    case 'cu_press_key': {
      const r = runWbcu(['key', '--app', app, '--combo', String(args.key), '--repeat', String(args.repeat ?? 1), '--json']);
      return toolResult(r.out || r.err);
    }

    case 'cu_scroll': {
      const dir = String(args.direction || 'down').toLowerCase();
      const pages = args.pages ?? 1;
      const dx = dir === 'left' ? -5 * pages : dir === 'right' ? 5 * pages : 0;
      const dy = dir === 'up' ? 5 * pages : dir === 'down' ? -5 * pages : 0;
      const argv = ['scroll', '--app', app, '--dx', String(dx), '--dy', String(dy), '--json'];
      if (typeof args.x === 'number') argv.push('--x', String(args.x), '--y', String(args.y));
      const r = runWbcu(argv);
      return toolResult(r.out || r.err);
    }

    case 'cu_perform_action': {
      const r = runWbcu(['ax-act', '--app', app, '--index', String(args.element_index), '--action', String(args.action), '--json']);
      return toolResult(r.out || r.err);
    }

    case 'cu_start_capture': {
      if (!app) return toolResult('需要 app');
      if (sessions.has(app)) return toolResult(`应用 ${app} 已在捕获中`);
      const seconds = String(args.seconds ?? 600);
      const argv = ['stream', '--app', app, '--seconds', seconds];
      if (args.frames_dir) argv.push('--dir', String(args.frames_dir));
      const proc = spawn(WBCU, argv, { stdio: ['ignore', 'pipe', 'pipe'], detached: false });
      let stderr = '';
      proc.stderr.on('data', (d) => { stderr += d.toString(); });
      sessions.set(app, { proc, startedAt: Date.now() });
      proc.on('exit', () => sessions.delete(app));
      await new Promise((r) => setTimeout(r, 1500));
      const scan = runWbcu(['indicator-scan', '--app', app, '--json']);
      return toolResult(`已启动窗口级持续捕获（${seconds}s）。系统共享指示器状态：\n${scan.out}\n${stderr}`);
    }

    case 'cu_stop_capture': {
      const keys = app ? [app] : [...sessions.keys()];
      if (keys.length === 0) return toolResult('当前没有进行中的捕获会话');
      for (const k of keys) {
        const s = sessions.get(k);
        if (s) { try { s.proc.kill('SIGTERM'); } catch { /* noop */ } sessions.delete(k); }
      }
      await new Promise((r) => setTimeout(r, 1200));
      const scan = app ? runWbcu(['indicator-scan', '--app', app, '--json']) : { out: '已全部停止' };
      return toolResult(`已停止捕获：${keys.join(', ')}\n指示器复查：\n${scan.out}`);
    }

    case 'cu_indicator_status': {
      const r = runWbcu(['indicator-scan', '--json', '--app', app]);
      return toolResult(r.out || r.err);
    }

    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

// ---------- JSON-RPC over stdio ----------
function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function handle(msg) {
  const { id, method, params } = msg;
  const reply = (result) => send({ jsonrpc: '2.0', id, result });
  const fail = (code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: PROTOCOL,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
      });
    case 'notifications/initialized':
      return;
    case 'tools/list':
      return reply({ tools: TOOLS });
    case 'tools/call':
      return callTool(params?.name, params?.arguments || {})
        .then((r) => reply(r))
        .catch((e) => reply({ content: [{ type: 'text', text: `错误: ${e.message}` }], isError: true }));
    case 'ping':
      return reply({});
    case 'shutdown':
      return reply({});
    default:
      return fail(-32601, `Method not found: ${method}`);
  }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx;
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch (e) {
      send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: `parse error: ${e.message}` } });
    }
  }
});

process.on('exit', () => {
  for (const [, s] of sessions) { try { s.proc.kill('SIGTERM'); } catch { /* noop */ } }
});
