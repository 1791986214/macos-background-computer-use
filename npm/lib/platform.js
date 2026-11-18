'use strict';

const path = require('path');

/**
 * 平台 → 发布包映射。
 *
 * 只列**真实存在资产**的平台。没有的就不编（例如 win-arm64 / darwin-x64），
 * 让上层明确报「不支持」而不是下载一个 404 然后给一个看不懂的错。
 *
 * sha256 是发布资产的校验值：下载后必须一致，避免半包、代理改写、
 * CDN 脏缓存被当成正常二进制装进系统。资产更新时必须同步这里。
 */
const RELEASE_TAG = 'v0.6.2-rc1';
const RELEASE_BASE = `https://github.com/1791986214/macos-background-computer-use/releases/download/${RELEASE_TAG}`;

const ASSETS = {
    'win32-x64': {
        file: 'wbcu-windows-win-x64-0.6.2.zip',
        sha256: '3ec08e0e5f7f866db873274f421eaa530db2921a0adb07618bb5e1c3aaadffe3',
        engine: 'wbcu.exe',
        extractRoot: '',
    },
    'darwin-arm64': {
        file: 'wbcu-macos-arm64-0.6.2.zip',
        sha256: '17a89de3847bb91c80bdd8bae8eb71abfda04965d176686c353c6b02e22a9b6a',
        engine: 'wbcu',
        extractRoot: '',
        // macOS 的幽灵光标覆盖层必须落在 ~/.local/share/wbcu/ThirdHandOverlay.app，
        // 引擎按这个固定路径找它（见 src/InputDispatcher/Targeted.swift）
        overlayFrom: 'overlay',
        overlayTo: ['.local', 'share', 'wbcu', 'ThirdHandOverlay.app'],
    },
};

function platformKey() {
    // 允许显式覆盖，仅用于本地验证（例如在 macOS 上检查 Windows 包的解压逻辑）
    if (process.env.WBCU_PLATFORM) return process.env.WBCU_PLATFORM;
    return `${process.platform}-${process.arch}`;
}

function asset() {
    return ASSETS[platformKey()] || null;
}

function vendorDir() {
    return path.join(__dirname, '..', 'vendor', platformKey());
}

function binaryPath() {
    const a = asset();
    const dir = vendorDir();
    if (!a) return path.join(dir, process.platform === 'win32' ? 'wbcu.exe' : 'wbcu');
    return path.join(dir, a.extractRoot ? path.join(a.extractRoot, a.engine) : a.engine);
}

module.exports = {
    RELEASE_TAG,
    RELEASE_BASE,
    ASSETS,
    asset,
    platformKey,
    vendorDir,
    binaryPath,
};
