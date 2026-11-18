'use strict';

/**
 * 下载 + 校验。零依赖（node:https），手动跟随重定向（GitHub Release 会 302 到 CDN）。
 *
 * 校验策略：sha256 必须匹配 lib/platform.js 里登记的值。
 * 不匹配就**不装**——宁可装不上，也不要把一个来源不明的 PE 放进用户系统。
 */

const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

/**
 * 对外入口：先直连，失败再用 curl 兜底。
 *
 * 为什么要 curl 兜底（真实踩坑）：
 *   Node 的 https 模块**不读** HTTPS_PROXY/HTTP_PROXY 环境变量，而 curl / PowerShell / 浏览器都读。
 *   在公司代理或国内网络下，表现就是「curl 3 秒下完，npm 装 5 秒报超时」——
 *   用户看到的是「你们的包下不下来」。裸写代理隧道（CONNECT + TLS）风险高且难测，
 *   而 Windows 10 1803+ 与 macOS 都自带 curl，用它兜底是最小代价的正确解。
 */
async function download(url, destPath) {
    try {
        return await downloadDirect(url, destPath);
    } catch (e) {
        try {
            return await downloadViaCurl(url, destPath);
        } catch (e2) {
            throw new Error(`${e.message}；curl 兜底也失败：${e2.message}`);
        }
    }
}

function downloadViaCurl(url, destPath) {
    return new Promise((resolve, reject) => {
        fs.mkdirSync(path.dirname(destPath), { recursive: true });
        const tmp = destPath + '.curl';
        const args = ['-fsSL', '--max-time', '180', '--retry', '1', '-o', tmp, url];
        const r = spawnSync('curl', args, { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });

        if (r.error) return reject(new Error('curl 不可用：' + r.error.message));
        if (r.status !== 0) {
            const msg = (r.stderr || Buffer.alloc(0)).toString().trim().slice(0, 200);
            return reject(new Error(`curl exit ${r.status} ${msg}`));
        }
        try {
            const hash = crypto.createHash('sha256').update(fs.readFileSync(tmp)).digest('hex');
            fs.renameSync(tmp, destPath);
            resolve(hash);
        } catch (e) {
            reject(e);
        }
    });
}

function downloadDirect(url, destPath, redirectsLeft = 5) {
    return new Promise((resolve, reject) => {
        const req = https.get(url, { headers: { 'user-agent': 'workbuddy-third-hand-npm' } }, (res) => {
            const code = res.statusCode || 0;

            if (code >= 300 && code < 400 && res.headers.location) {
                res.resume();
                if (redirectsLeft <= 0) return reject(new Error('重定向次数过多'));
                return downloadDirect(res.headers.location, destPath, redirectsLeft - 1).then(resolve, reject);
            }

            if (code !== 200) {
                res.resume();
                return reject(new Error(`下载失败 HTTP ${code}: ${url}`));
            }

            fs.mkdirSync(require('path').dirname(destPath), { recursive: true });
            const tmp = destPath + '.part';
            const out = fs.createWriteStream(tmp);
            const hash = crypto.createHash('sha256');

            res.on('data', (chunk) => hash.update(chunk));
            res.pipe(out);

            out.on('finish', () => out.close(() => {
                try {
                    fs.renameSync(tmp, destPath);
                    resolve(hash.digest('hex'));
                } catch (e) {
                    reject(e);
                }
            }));
            out.on('error', reject);
            res.on('error', reject);
        });

        req.setTimeout(120000, () => req.destroy(new Error('下载超时（120s）')));
        req.on('error', reject);
    });
}

function sha256File(path) {
    return crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex');
}

module.exports = { download, sha256File };
