// SPDX-License-Identifier: MIT

import {randomUUID} from 'node:crypto';
import {mkdir, rename, unlink, writeFile} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join} from 'node:path';
import process from 'node:process';

function quotaWindow(value) {
    const percent = value?.used_percentage ?? value?.percent;
    if (!Number.isFinite(percent)) return null;
    const reset =
        typeof value.resets_at === 'number' ? value.resets_at * 1000 : Date.parse(value.resets_at);
    return {
        utilization: percent,
        resets_at:
            Number.isFinite(reset) && Math.abs(reset) <= 8.64e15
                ? new Date(reset).toISOString()
                : null,
    };
}

async function main() {
    let input = '';
    for await (const chunk of process.stdin) input += chunk;
    const limits = JSON.parse(input).rate_limits;
    const fiveHour = quotaWindow(
        limits?.five_hour ?? limits?.limits?.find((v) => v.kind === 'session'),
    );
    const weekly = quotaWindow(
        limits?.seven_day ?? limits?.limits?.find((v) => v.kind === 'weekly_all'),
    );
    const fable = quotaWindow(
        limits?.limits?.find(
            (v) => v.kind === 'weekly_scoped' && v.scope?.model?.display_name === 'Fable',
        ),
    );
    if (!fiveHour && !weekly && !fable) return;

    const configDirectory =
        process.platform === 'darwin'
            ? (process.env.CLAUDE_SECURESTORAGE_CONFIG_DIR ?? process.env.CLAUDE_CONFIG_DIR)
            : process.env.CLAUDE_CONFIG_DIR;
    const directory = configDirectory || join(homedir(), '.claude');
    const path = join(directory, 'cuotax-usage.json');
    const temporary = `${path}.${randomUUID()}.tmp`;
    await mkdir(directory, {recursive: true, mode: 0o700});
    try {
        await writeFile(
            temporary,
            JSON.stringify({
                updatedAt: Date.now(),
                five_hour: fiveHour,
                seven_day: weekly,
                limits: fable
                    ? [
                          {
                              kind: 'weekly_scoped',
                              percent: fable.utilization,
                              resets_at: fable.resets_at,
                              scope: {model: {display_name: 'Fable'}},
                          },
                      ]
                    : [],
            }),
            {mode: 0o600, flag: 'wx'},
        );
        await rename(temporary, path);
    } finally {
        await unlink(temporary).catch(() => {});
    }
    process.stdout.write(
        `Claude ${[fiveHour && `5h ${fiveHour.utilization}%`, weekly && `weekly ${weekly.utilization}%`, fable && `Fable weekly ${fable.utilization}%`].filter(Boolean).join(' · ')}\n`,
    );
}

main().catch(() => {
    process.stderr.write('CuotaX: could not save Claude status-line usage\n');
    process.exitCode = 1;
});
