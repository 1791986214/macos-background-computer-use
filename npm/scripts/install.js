#!/usr/bin/env node
'use strict';

/**
 * postinstall：按平台下载原生引擎、校验、解压，并顺手装上 WorkBuddy 技能。
 *
 * 设计取舍：
 *   - 消息用**英文**：Windows 默认控制台代码页是 936/437，中文容易乱码，
 *     而安装阶段恰恰是最需要用户看懂提示的时候。
 *   - 校验不过就不装（exit 1）：宁可装不上，也不要把来源不明的 PE 放进系统。
 *   - 允许离线：WBCU_LOCAL_ZIP=<path> 直接用本地包（内网 / 代理环境下最实用）。
 *   - 允许纯手动：WBCU_SKIP_DOWNLOAD=1 只装 npm 壳，二进制自己放。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

const { ASSETS, RELEASE_BASE, asset, platformKey, vendorDir, binaryPath } = require('../lib/platform');
const { download, sha256File } = require('../lib/download');
const { extract } = require('../lib/unzip');

const pkg = require('../package.json');

function log(msg) { console.log(`[workbuddy-third-hand] ${msg}`); }

function fail(msg, hint) {
    console.error('');
    console.error(`[workbuddy-third-hand] ERROR: ${msg}`);
    if (hint) console.error(`[workbuddy-third-hand] ${hint}`);
    console.error('');
    process.exit(1);
}

async function main() {
    const key = platformKey();
    const vendored = binaryPath();

    if (process.env.WBCU_SKIP_DOWNLOAD === '1') {
        log(`skip download (WBCU_SKIP_DOWNLOAD=1). Put the engine at: ${vendored}`);
        return;
    }

    if (fs.existsSync(vendored)) {
        log(`engine already present: ${vendored}`);
        installSkill();
        return;
    }

    const a = asset();
    if (!a) {
        const supported = Object.keys(ASSETS).join(', ');
        fail(`no prebuilt engine for "${key}".`,
            `supported: ${supported}. See docs/windows-installation.md for manual install.`);
    }

    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wbcu-npm-'));
    const zipPath = path.join(tmpDir, a.file);

    const localZip = process.env.WBCU_LOCAL_ZIP;
    let hash;

    if (localZip) {
        if (!fs.existsSync(localZip)) fail(`WBCU_LOCAL_ZIP not found: ${localZip}`);
        fs.copyFileSync(localZip, zipPath);
        hash = sha256File(zipPath);
        log(`using local archive: ${localZip}`);
    } else {
        // WBCU_DOWNLOAD_BASE 可指向镜像（国内网络的常规做法），只替换前缀
        const base = process.env.WBCU_DOWNLOAD_BASE || RELEASE_BASE;
        const url = `${base}/${a.file}`;
        log(`downloading ${url}`);
        try {
            hash = await download(url, zipPath);
        } catch (e) {
            fail(`download failed: ${e.message}`,
                `offline / proxied? three ways:\n`
                + `  1) mirror:  set WBCU_DOWNLOAD_BASE=<mirror that serves the same release>\n`
                + `  2) local:   download this file and set WBCU_LOCAL_ZIP=<path to zip>\n`
                + `              ${url}\n`
                + `  3) manual:  curl -fsSL -o wbcu.zip "${url}" then WBCU_LOCAL_ZIP=wbcu.zip`);
        }
    }

    if (a.sha256 && hash !== a.sha256) {
        fail(`sha256 mismatch for ${a.file}`,
            `expected ${a.sha256}\n  actual   ${hash}\n  Refusing to install. Re-check network/proxy, or pass WBCU_LOCAL_ZIP.`);
    }
    log(`sha256 ok: ${hash}`);

    const dest = vendorDir();
    fs.rmSync(dest, { recursive: true, force: true });
    fs.mkdirSync(dest, { recursive: true });

    const files = extract(zipPath, dest);
    log(`extracted ${files.length} files to ${dest}`);

    if (!fs.existsSync(vendored)) {
        fail(`engine binary missing after extraction: ${vendored}`);
    }

    if (process.platform !== 'win32') {
        try { fs.chmodSync(vendored, 0o755); } catch { }
    }

    // PE 头校验：MZ。可以挡住「下到 HTML 错误页但 HTTP 200」这类情况。
    const head = Buffer.alloc(2);
    const fd = fs.openSync(vendored, 'r');
    fs.readSync(fd, head, 0, 2, 0);
    fs.closeSync(fd);
    if (head.toString('ascii') !== 'MZ' && process.platform === 'win32') {
        fail(`extracted engine is not a valid PE executable: ${vendored}`);
    }

    fs.writeFileSync(path.join(dest, 'VERSION'), `${pkg.version}\n`, 'utf8');

    // macOS：覆盖层（幽灵光标）必须放到引擎固定查找的位置，否则 core 功能正常但没有视觉反馈
    if (a.overlayFrom) {
        const from = path.join(dest, a.overlayFrom);
        const to = path.join(os.homedir(), ...a.overlayTo);
        if (fs.existsSync(from)) {
            try {
                fs.rmSync(to, { recursive: true, force: true });
                fs.mkdirSync(path.dirname(to), { recursive: true });
                fs.cpSync(from, to, { recursive: true });
                log(`overlay installed: ${to}`);
            } catch (e) {
                log(`overlay install skipped (${e.message}); ghost cursor will be unavailable`);
            }
        }
    }
    log(`engine ready: ${vendored}`);

    installSkill(dest);

    log('done. try: wbcu doctor');
}

/**
 * 把随包发布的 SKILL.md 装进 WorkBuddy 技能目录。
 * 目录靠**探测**，不假设 macOS 的 ~/.workbuddy 在 Windows 上一样存在。
 */
function installSkill(extractDirOverride) {
    if (process.env.WBCU_SKIP_SKILL === '1') {
        log('skip skill install (WBCU_SKIP_SKILL=1)');
        return;
    }

    const src = path.join(extractDirOverride || vendorDir(), 'skill', 'SKILL.md');
    if (!fs.existsSync(src)) {
        log('skill/SKILL.md not found in payload, skill not installed');
        return;
    }

    const home = os.homedir();
    const candidates = [
        path.join(home, '.workbuddy', 'skills', 'workbuddy-third-hand'),
        path.join(process.env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'workbuddy', 'skills', 'workbuddy-third-hand'),
        path.join(process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'), 'workbuddy', 'skills', 'workbuddy-third-hand'),
        path.join(home, 'Documents', 'WorkBuddy', 'skills', 'workbuddy-third-hand'),
    ];

    let target = candidates.find((c) => fs.existsSync(c));
    if (!target) {
        target = candidates.find((c) => fs.existsSync(path.dirname(c)));
    }
    if (!target) target = candidates[0];

    try {
        fs.mkdirSync(target, { recursive: true });
        fs.copyFileSync(src, path.join(target, 'SKILL.md'));
        log(`skill installed: ${path.join(target, 'SKILL.md')}`);
    } catch (e) {
        log(`skill install skipped (${e.message}); copy it manually from ${src}`);
    }
}

main().catch((e) => fail(e && e.message ? e.message : String(e)));
