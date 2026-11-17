'use strict';

/**
 * 下载 + 校验。零依赖（node:https），手动跟随重定向（GitHub Release 会 302 到 CDN）。
 *
 * 校验策略：sha256 必须匹配 lib/platform.js 里登记的值。
 * 不匹配就**不装**——宁可装不上，也不要把一个来源不明的 PE 放进用户系统。
 */

const https = require('https');
const fs = require('fs');
const crypto = require('crypto');

function download(url, destPath, redirectsLeft = 5) {
    return new Promise((resolve, reject) => {
        const req = https.get(url, { headers: { 'user-agent': 'workbuddy-third-hand-npm' } }, (res) => {
            const code = res.statusCode || 0;

            if (code >= 300 && code < 400 && res.headers.location) {
                res.resume();
                if (redirectsLeft <= 0) return reject(new Error('重定向次数过多'));
                return download(res.headers.location, destPath, redirectsLeft - 1).then(resolve, reject);
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
