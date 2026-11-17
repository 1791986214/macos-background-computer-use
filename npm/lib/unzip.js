'use strict';

/**
 * 零依赖 ZIP 解压（只支持 store / deflate 两种压缩方式，够用且够稳）。
 *
 * 为什么不用 adm-zip / yauzl：
 *   1) postinstall 阶段装一个带依赖的包，会把「下载原生引擎」这件事变成
 *      「先装 5 个传递依赖再下载」——失败点变多，用户看到的是 npm 装不上。
 *   2) Windows 上没有内置 unzip；调 PowerShell 的 Expand-Archive 又依赖
 *      执行策略与 PowerShell 版本，属于「在我机器上能跑」的典型来源。
 *   3) 自己写 100 行能在这台 Mac 上用真实发布包测试，比「只在 Windows 上跑过」可信。
 *
 * 安全：拒绝绝对路径、拒绝 .. 逃逸（zip-slip）。解压目录之外一个字节都不写。
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const SIG_EOCD = 0x06054b50;
const SIG_CENTRAL = 0x02014b50;
const SIG_LOCAL = 0x04034b50;

function findEocd(buf) {
    // EOCD 在末尾，最长注释 65535 字节
    const min = Math.max(0, buf.length - 65557);
    for (let i = buf.length - 22; i >= min; i--) {
        if (buf.readUInt32LE(i) === SIG_EOCD) return i;
    }
    return -1;
}

function extract(zipPath, destDir) {
    const buf = fs.readFileSync(zipPath);
    const eocd = findEocd(buf);
    if (eocd < 0) throw new Error('不是有效的 ZIP：找不到中央目录结束标记');

    const count = buf.readUInt16LE(eocd + 10);
    let offset = buf.readUInt32LE(eocd + 16);

    const destRoot = path.resolve(destDir);
    fs.mkdirSync(destRoot, { recursive: true });

    const written = [];

    for (let i = 0; i < count; i++) {
        if (buf.readUInt32LE(offset) !== SIG_CENTRAL) {
            throw new Error(`中央目录记录 #${i} 签名不正确`);
        }

        const method = buf.readUInt16LE(offset + 10);
        const compressedSize = buf.readUInt32LE(offset + 20);
        const uncompressedSize = buf.readUInt32LE(offset + 24);
        const nameLen = buf.readUInt16LE(offset + 28);
        const extraLen = buf.readUInt16LE(offset + 30);
        const commentLen = buf.readUInt16LE(offset + 32);
        const localOffset = buf.readUInt32LE(offset + 42);
        const name = buf.toString('utf8', offset + 46, offset + 46 + nameLen);

        offset += 46 + nameLen + extraLen + commentLen;

        // 目录条目
        if (name.endsWith('/')) continue;

        const target = safeJoin(destRoot, name);

        if (buf.readUInt32LE(localOffset) !== SIG_LOCAL) {
            throw new Error(`本地头签名不正确: ${name}`);
        }
        const localNameLen = buf.readUInt16LE(localOffset + 26);
        const localExtraLen = buf.readUInt16LE(localOffset + 28);
        const dataStart = localOffset + 30 + localNameLen + localExtraLen;
        const raw = buf.subarray(dataStart, dataStart + compressedSize);

        let data;
        if (method === 0) {
            data = Buffer.from(raw);
        } else if (method === 8) {
            data = zlib.inflateRawSync(raw);
        } else {
            throw new Error(`不支持的压缩方式 ${method}: ${name}`);
        }

        if (uncompressedSize && data.length !== uncompressedSize) {
            throw new Error(`解压长度不符 (${data.length} != ${uncompressedSize}): ${name}`);
        }

        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, data);
        written.push(name);
    }

    return written;
}

function safeJoin(root, name) {
    const normalized = name.replace(/\\/g, '/');
    if (normalized.startsWith('/') || /^[A-Za-z]:/.test(normalized)) {
        throw new Error('ZIP 中存在绝对路径条目: ' + name);
    }
    const target = path.resolve(root, normalized);
    const rel = path.relative(root, target);
    if (rel.startsWith('..') || path.isAbsolute(rel)) {
        throw new Error('ZIP 条目越出目标目录: ' + name);
    }
    return target;
}

module.exports = { extract };
